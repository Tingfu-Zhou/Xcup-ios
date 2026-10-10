//
//  VideoProcessViewController.swift
//  Xcup
//
//  Created by tingfu on 2025/4/20.
//

import UIKit
import AVFoundation
import CoreML
import CoreBluetooth
import TensorFlowLite

// MARK: - 线程安全的分析结果存储
class ThreadSafeAnalysisResults {
    private let queue = DispatchQueue(label: "com.xcup.analysisResults", attributes: .concurrent)

    // 视频 / 音频的判定结果：动作 + 置信度 + 产出时刻（音频还有线索）打包成一个不可变对象，整体发布、整体读出
    // （融合仲裁按产出时刻去重，这几项必须来自同一次推理）。nil = 还没有结果
    private var _videoResult: FusionArbiter.Result?
    private var _audioResult: FusionArbiter.Result?

    // ===== 🆕 新增：音频节奏器结果 =====
    /*
    private var _audioRhythmHz: Float = .nan        // 音频节奏频率(Hz)
    private var _audioRhythmConf: Float = 0.0       // 音频节奏置信度
    private var _audioRhythmTsMs: Int64 = 0         // 音频节奏时间戳(毫秒)
    private var _audioRhythmValid: Bool = false     // 音频节奏是否有效
    */
    // ===== 🆕 新增：音频响度档位结果（替代音频节奏器） =====
    private var _audioLoudLevel: Int = 0
    private var _audioLoudConf: Float = 0.0
    private var _audioLoudTsMs: Int64 = 0
    private var _audioLoudValid: Bool = false

    // ===== 🆕 新增：音频响度档位访问器 =====
    var audioLoudnessLevel: (level: Int, conf: Float, tsMs: Int64, valid: Bool) {
        get { queue.sync { (_audioLoudLevel, _audioLoudConf, _audioLoudTsMs, _audioLoudValid) } }
        set {
            queue.async(flags: .barrier) {
                self._audioLoudLevel = newValue.level
                self._audioLoudConf = newValue.conf
                self._audioLoudTsMs = newValue.tsMs
                self._audioLoudValid = newValue.valid
            }
        }
    }

        
    // ===== 🆕 新增：视频节奏器结果 =====
    private var _videoFreqHz: Float = .nan          // 视频节奏频率(Hz)
    private var _videoFreqConf: Float = 0.0         // 视频节奏置信度
    private var _videoFreqTsMs: Int64 = 0           // 视频节奏时间戳(毫秒)
    
    var videoResult: FusionArbiter.Result? {
        get { queue.sync { _videoResult } }
        set { queue.async(flags: .barrier) { self._videoResult = newValue } }
    }

    var audioResult: FusionArbiter.Result? {
        get { queue.sync { _audioResult } }
        set { queue.async(flags: .barrier) { self._audioResult = newValue } }
    }
    
    /*
    // ===== 🆕 新增：音频节奏器访问器 =====
    var audioRhythm: (hz: Float, conf: Float, tsMs: Int64, valid: Bool) {
        get {
            queue.sync {
                (_audioRhythmHz, _audioRhythmConf, _audioRhythmTsMs, _audioRhythmValid)
            }
        }
        set {
            queue.async(flags: .barrier) {
                self._audioRhythmHz = newValue.hz
                self._audioRhythmConf = newValue.conf
                self._audioRhythmTsMs = newValue.tsMs
                self._audioRhythmValid = newValue.valid
            }
        }
    }
    */
    
    // ===== 🆕 新增：视频节奏器访问器 =====
    var videoFreq: (hz: Float, conf: Float, tsMs: Int64) {
        get {
            queue.sync {
                (_videoFreqHz, _videoFreqConf, _videoFreqTsMs)
            }
        }
        set {
            queue.async(flags: .barrier) {
                self._videoFreqHz = newValue.hz
                self._videoFreqConf = newValue.conf
                self._videoFreqTsMs = newValue.tsMs
            }
        }
    }
    
    // ===== 🆕 新增：重置方法 =====
    func resetRhythm() {
        queue.async(flags: .barrier) {
            // 重置音频节奏
            /*
            self._audioRhythmHz = .nan
            self._audioRhythmConf = 0.0
            self._audioRhythmTsMs = 0
            self._audioRhythmValid = false
            */
            // 重置音频响度档位
            self._audioLoudLevel = 0
            self._audioLoudConf = 0.0
            self._audioLoudTsMs = 0
            self._audioLoudValid = false
                
            // 重置视频节奏
            self._videoFreqHz = .nan
            self._videoFreqConf = 0.0
            self._videoFreqTsMs = 0
        }
    }
}

class VideoProcessViewController: UIViewController {

    // MARK: - UI 元素
    let videoView = UIView()// 使用 AVPlayerLayer 嵌入
    let tvOverlay = UILabel()//最终的动作类型
    let tvVideoAction = UILabel()//视频分析的动作类型
    let tvAudioAction = UILabel()//音频分析的动作类型
    let btnFullscreen = UIButton(type: .system)
    let btnPlayPause = UIButton(type: .system) // 播放/暂停按钮
    // 添加时间显示Label
    let currentTimeLabel = UILabel()
    let totalTimeLabel = UILabel()
    
    // MARK: - 传入视频路径
    var videoURL: URL!

    // MARK: - 推理和蓝牙
    // 旧的 ML Kit + ST-GCN++ 已弃用，统一替换为 MobileNetV3Small 三分类
    // var inferenceHelper: InferenceHelper!
    var videoClassifier: VideoClassifierHelper!
    var audioHelper: AudioInferenceHelper!

    // MARK: - 🆕 音频节奏器
    // private var audioRhythmEstimator: AudioRhythmEstimator!
    // 音频响度档位估计器（替代音频节奏器）
    private var audioLoudnessEstimator: AudioLoudnessLevelEstimator!


    // MARK: - 🆕 视频节奏器（已移除：现在统一用音频节律）
    // private var videoRhythmEstimator: VideoMotionWaveEstimator!
    
    // MARK: - 抽帧
    var videoFrameExtractor: VideoFrameExtractor!

    // MARK: - 视频播放和同步
    var player: AVPlayer!
    var playerItem: AVPlayerItem!
    var playerLayer: AVPlayerLayer!
    var playerObserver: Any?

    // MARK: - 线程相关
    private let videoAnalysisQueue = DispatchQueue(label: "com.xcup.videoAnalysis", qos: .userInitiated)
    private let audioAnalysisQueue = DispatchQueue(label: "com.xcup.audioAnalysis", qos: .userInitiated)
    private let analysisResults = ThreadSafeAnalysisResults()
    
    // MARK: - 分析定时器
    private var videoAnalysisTimer: DispatchSourceTimer?
    private var audioAnalysisTimer: DispatchSourceTimer?
    private var fusionTimer: Timer?
    
    // ===================== [12.14] 自调度循环（替代 repeating timer） =====================
    private let VIDEO_INTERVAL_MS: Int64 = 250           // 视频抽帧轮询 250ms
    private let VIDEO_INFER_STEP_MS: Int64 = 500         // 视频推理步长 500ms（相邻窗口重叠 10/12 帧）
    private let AUDIO_INTERVAL_MS: Int64 = 1000          // 音频 1s
    private let FUSION_INTERVAL_MS: Int64 = 500          // 融合 500ms（2 Hz）

    private var videoLoopWorkItem: DispatchWorkItem?
    private var audioLoopWorkItem: DispatchWorkItem?
    private var fusionLoopWorkItem: DispatchWorkItem?

    // MARK: - 视频分类滑动窗口（12 帧 × 160×160 × RGB，3s 窗口，500ms 推理步长）
    private let FRAME_BUFFER_SIZE: Int = VideoClassifierHelper.TIME  // 12
    private var frameBuffer: [UIImage] = []
    private var lastVideoInferenceMs: Int64 = 0

    // MARK: - 视频分组概率阈值（与 Android 对齐：在 oral/sex 归并后的分组概率上判定）
    private let VIDEO_DO_PROB_THRESHOLD: Float = 0.65    // P(oral)+P(sex) ≥ 0.65 → "do"
    private let VIDEO_PLOT_PROB_THRESHOLD: Float = 0.60  // P(plot) ≥ 0.60 → "Noise"

    // MARK: - 音频分组概率阈值（与 Android 对齐）
    private let AUDIO_DO_PROB_THRESHOLD: Float = 0.55    // P(sex)+P(oral) ≥ 0.55 → "do"
    private let AUDIO_NOISE_PROB_THRESHOLD: Float = 0.60 // P(noise) ≥ 0.60 → "Noise"

    /* ---- 旧版姿态窗口（ST-GCN++）已弃用 ----
    var poseWindow: [PoseFrame] = []
    let WINDOW_SIZE = 32

    // MARK: - 二分类相关参数
    var poseWindow8: [PoseFrame] = []  // 8帧二分类窗口
    let BINARY_WINDOW = 8             // 二分类窗口大小
    let BINARY_TH: Float = 0.3        // 二分类阈值
    let MULTI_STEP = 8                // 多分类步长
    var framesSinceLastMulti = 0      // 多分类帧计数器
    */
    
    // MARK: - 融合仲裁
    // 启动 / 维持 / 停止分开判断（规则见 FusionArbiter）。2026-10-07 起替代原来的平滑投票 smoothedFusion、
    // 一致性快通道和启动仲裁 applyDoStartGate（都已删除）。只在融合线程（主线程）访问；seek / 恢复分析时 reset。
    private let fusionArbiter = FusionArbiter()
    private var latestBluetoothAction = ""       // 最新的蓝牙发送动作

    // MARK: - 蓝牙状态管理相关
    private var pendingBluetoothState = ""           // 待确认的蓝牙状态
    private var currentBluetoothState = ""           // 当前执行的蓝牙状态
    private var pendingStateStartTime: TimeInterval = 0   // 待确认状态开始时间
    private var currentStateStartTime: TimeInterval = 0   // 当前状态开始时间
    private var lastBluetoothSendTime: TimeInterval = 0   // 上次蓝牙发送时间
    private let BLUETOOTH_MIN_DURATION: TimeInterval = 2000  // 最小持续时间（2秒）
    private let BLUETOOTH_SEND_INTERVAL: TimeInterval = 1600  // 发送间隔（1600ms）
    private let BLUETOOTH_STABLE_CONFIRM_MS: TimeInterval = 1600 // 稳定确认时间
    
    // ===================== 频率档位确认与节流 =====================
    // 档位（0..10）确认状态
    private var currentLevel: Int = 1
    private var currentLevelSinceMs: TimeInterval = 0   // 当前生效档位开始时间（ms）
    private var pendingLevel: Int? = nil
    private var pendingLevelSinceMs: TimeInterval = 0   // 待确认档位开始时间（ms})

    // 最近一次“已发送”的档位（用于判断是否需要用同一动作更新档位）
    private var lastSentLevel: Int = 0
    
    // ★ 新增：暂停时挂起的蓝牙动作与档位
    private var suspendedBluetoothState: String = ""
    private var suspendedLevel: Int = 0

    // 档位确认/节流参数（结合你的 800ms 主循环）
    private let LEVEL_STABLE_MS: TimeInterval  = 0    // 新档位短稳确认
    private let LEVEL_MIN_DUR_MS: TimeInterval = 0   // 生效档位的最小驻留
    private let LEVEL_SEND_GAP_MS: TimeInterval = 1600  // 档位更新发送间隔（与动作一致）
    
    // MARK: - 音频缓冲
    var audioStartTime: Int64 = 0
    
    // MARK: - 播放跳动
    var pendingSeekWorkItem: DispatchWorkItem?
    var lastSeekTime: Int64 = 0
    var didUserSeek = false
    
    // MARK: - 视频播放进度条
    let progressSlider = UISlider()
    var isSeekingByUser = false

    // MARK: - 音频处理
    var audioDecoder: AudioDecoder!
    var pcmBuffer: PcmCircularBuffer!

    var lastFinalAction = ""

    // MARK: - 暂停与继续播放
    private let analysisStateLock = NSLock()
    private var _isAnalysisPaused = false
    var isAnalysisPaused: Bool {
        get {
            analysisStateLock.lock()
            defer { analysisStateLock.unlock() }
            return _isAnalysisPaused
        }
        set {
            analysisStateLock.lock()
            defer { analysisStateLock.unlock() }
            _isAnalysisPaused = newValue
        }
    }
    
    var isVideoCompleted = false
    var playStateTimer: Timer?
    var lastIsPlaying = true
    
    // MARK: - 全屏与退出全屏
    var isFullscreen = false
    
    // MARK: - 检测视频播放结束
    var videoDuration: Double = 0.0
    
    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupLayout()
        setupUI()
        setupInference()
        guard let url = videoURL else {
            print("❌ 未设置 videoURL")
            return
        }
        setupPlayer(with: url)
        setupAudio(with: url)
        startAnalysisThreads()
        startPlaybackObserver()
    }

    // MARK: - 核心 UI 布局代码.
    //设置背景为黑色；播放画面自动居中缩放；UILabel 放左上角；UIButton 放右上角。
    func setupLayout() {
        view.backgroundColor = .black

        // 添加 videoView
        videoView.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)

        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // 添加进度条
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressSlider)

        NSLayoutConstraint.activate([
            progressSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            progressSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            progressSlider.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        
        // 🆕 添加当前时间Label
        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        currentTimeLabel.textColor = .white
        currentTimeLabel.font = UIFont.systemFont(ofSize: 12)
        currentTimeLabel.text = "0:00"
        view.addSubview(currentTimeLabel)

        NSLayoutConstraint.activate([
            currentTimeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            currentTimeLabel.bottomAnchor.constraint(equalTo: progressSlider.topAnchor, constant: -4)
        ])

        // 🆕 添加总时长Label
        totalTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        totalTimeLabel.textColor = .white
        totalTimeLabel.font = UIFont.systemFont(ofSize: 12)
        totalTimeLabel.text = "0:00"
        view.addSubview(totalTimeLabel)

        NSLayoutConstraint.activate([
            totalTimeLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            totalTimeLabel.bottomAnchor.constraint(equalTo: progressSlider.topAnchor, constant: -4)
        ])

        // 视频分析结果 Label
        let labels = [tvVideoAction, tvAudioAction, tvOverlay]
        let labelTitles = ["V: ", "A: ", "Final: "]

        for (i, label) in labels.enumerated() {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .white
            label.font = UIFont.systemFont(ofSize: 13)
            label.text = labelTitles[i]
            view.addSubview(label)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: CGFloat(12 + i * 22))
            ])
        }
        
        // 全屏按钮
        btnFullscreen.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        btnFullscreen.setImage(icon, for: .normal)
        btnFullscreen.tintColor = .white
        view.addSubview(btnFullscreen)

        NSLayoutConstraint.activate([
            btnFullscreen.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            btnFullscreen.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            btnFullscreen.widthAnchor.constraint(equalToConstant: 32),
            btnFullscreen.heightAnchor.constraint(equalToConstant: 32)
        ])

        // 播放/暂停按钮（现在放在 btnFullscreen 之后）
        btnPlayPause.translatesAutoresizingMaskIntoConstraints = false
        let pauseIcon = UIImage(systemName: "pause.fill")
        btnPlayPause.setImage(pauseIcon, for: .normal)
        btnPlayPause.tintColor = .white
        view.addSubview(btnPlayPause)

        NSLayoutConstraint.activate([
            btnPlayPause.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            btnPlayPause.topAnchor.constraint(equalTo: btnFullscreen.bottomAnchor, constant: 12),
            btnPlayPause.widthAnchor.constraint(equalToConstant: 32),
            btnPlayPause.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    // MARK: - 播放器初始化（保持主要逻辑不变）
    func setupPlayer(with url: URL) {
        print("📼 设置播放器，传入路径: \(url)")

        playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = videoView.bounds
        
        // 让多余区域也为黑色（letter‑box 时不再出现白条）
        playerLayer.backgroundColor = UIColor.black.cgColor
        // 等比缩放，完整显示全部画面
        playerLayer.videoGravity = .resizeAspect

        videoView.layer.insertSublayer(playerLayer, at: 0)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(videoDidEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )

        // 初始化视频帧提取器
        guard let extractor = VideoFrameExtractor(url: url) else {
            print("❌ VideoFrameExtractor 初始化失败")
            return
        }
        videoFrameExtractor = extractor

        player.play()

        // 设置 audioStartTime 为当前播放时间（毫秒）
        audioStartTime = Int64(CMTimeGetSeconds(player.currentTime()) * 1000)
        print("🎬 播放开始，audioStartTime = \(audioStartTime)")
        
        // 添加拖动监听逻辑
        player.addPeriodicTimeObserver(forInterval: CMTimeMake(value: 1, timescale: 2), queue: .main) { [weak self] time in
            guard let self = self else { return }
            
            //在 timeObserver 中更新进度条
            if !self.isSeekingByUser {
                let seconds = time.seconds
                self.progressSlider.value = Float(seconds)
            }
            
            // 🆕 更新当前时间显示
            let currentSeconds = time.seconds
            self.currentTimeLabel.text = self.formatTime(currentSeconds)
            
            // 判断是否是人为 seek（与 lastSeekTime 差距过大）
            if self.didUserSeek {
                self.didUserSeek = false
                self.handleUserSeek(currentMs: Int64(time.seconds * 1000))
            }
        }
        
        // 初始化 slider 配置，即视频播放进度条
        videoDuration = CMTimeGetSeconds(playerItem.asset.duration)
        progressSlider.minimumValue = 0
        progressSlider.maximumValue = Float(videoDuration)
        progressSlider.value = 0
        
        // 🆕 设置总时长显示
        totalTimeLabel.text = formatTime(videoDuration)

        // 监听用户开始拖动
        progressSlider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        // 拖动中
        progressSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        // 拖动结束
        progressSlider.addTarget(self, action: #selector(sliderTouchUp), for: [.touchUpInside, .touchUpOutside])
        
        // 添加点击手势识别器
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(sliderTapped(_:)))
        progressSlider.addGestureRecognizer(tapGesture)
    }

    // MARK: - 推理初始化
    func setupInference() {
        // 旧的 ML Kit + ST-GCN++ 已弃用：
        // inferenceHelper = InferenceHelper()
        // inferenceHelper.setupPoseDetector()

        // 视频改为 MobileNetV3Small 三分类
        videoClassifier = VideoClassifierHelper()

        // 🆕 初始化音频节奏器
        // audioRhythmEstimator = AudioRhythmEstimator(sampleRateHz: 16000)
        audioLoudnessEstimator = AudioLoudnessLevelEstimator(sampleRate: 16000)

        // 🆕 初始化视频节奏器（已移除）
        // videoRhythmEstimator = VideoMotionWaveEstimator()
    }

    // MARK: - 音频初始化
    func setupAudio(with url: URL) {
        pcmBuffer = PcmCircularBuffer(sampleRate: 16000, capacityInSeconds: 20)
        audioHelper = AudioInferenceHelper()

        guard let player = player else {
            print("❌ 播放器未初始化，无法创建 AudioDecoder")
            return
        }

        let asset = AVURLAsset(url: url) // 使用 AVURLAsset 单独构建解码器（避免出现尚未准备好的 player.asset）

        audioDecoder = AudioDecoder(
            asset: asset,
            buffer: pcmBuffer,
            // 弱引用 player：解码线程不应让播放器在页面退出后继续存活
            positionProvider: { [weak player] in Int((player?.currentTime().seconds ?? 0) * 1000) }
        )

        audioDecoder.startDecoding()
    }

    // MARK: - UI 初始化
    func setupUI() {
        btnFullscreen.addTarget(self, action: #selector(toggleFullscreen), for: .touchUpInside)
        btnPlayPause.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
    }

    // MARK: - 启动分析线程
    func startAnalysisThreads() {
        startVideoLoop()
        startAudioLoop()     //（保留 2s 预热延迟）
        startFusionLoop()
    }
    
    // ===================== [12.14] 视频自调度循环（100ms） =====================
    private func startVideoLoop() {
        videoLoopWorkItem?.cancel()
        scheduleNextVideoTick(afterMs: 0) // 立即启动
    }

    private func scheduleNextVideoTick(afterMs delayMs: Int64) {
        let item = DispatchWorkItem { [weak self] in
            self?.runVideoTick()
        }
        videoLoopWorkItem = item
        videoAnalysisQueue.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: item)
    }

    private func runVideoTick() {
        // run() 进入点计时（对齐你 Android 的 t0）
        let t0 = DispatchTime.now() // NEW

        // 业务逻辑（保持原函数不变）
        if !isAnalysisPaused {
            performVideoAnalysis()
        }

        // elapsed / nextDelay
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds
        let elapsedMs = Int64(elapsedNs / 1_000_000)
        let nextDelay = max(Int64(0), VIDEO_INTERVAL_MS - elapsedMs) // NEW: nextDelay=max(0, interval-elapsed)

        scheduleNextVideoTick(afterMs: nextDelay) // NEW
    }

    
    // ===================== [12.14] 音频自调度循环（1s） =====================
    private func startAudioLoop() {
        audioLoopWorkItem?.cancel()
        scheduleNextAudioTick(afterMs: 0) 
    }

    private func scheduleNextAudioTick(afterMs delayMs: Int64) {
        let item = DispatchWorkItem { [weak self] in
            self?.runAudioTick()
        }
        audioLoopWorkItem = item
        audioAnalysisQueue.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: item)
    }

    private func runAudioTick() {
        let t0 = DispatchTime.now() // NEW

        if !isAnalysisPaused {
            performAudioAnalysis()
        }

        let elapsedNs = DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds
        let elapsedMs = Int64(elapsedNs / 1_000_000)
        let nextDelay = max(Int64(0), AUDIO_INTERVAL_MS - elapsedMs) // NEW

        scheduleNextAudioTick(afterMs: nextDelay) // NEW
    }
    
    // ===================== [12.14] 融合自调度循环（800ms，主线程） =====================
    private func startFusionLoop() {
        fusionLoopWorkItem?.cancel()
        scheduleNextFusionTick(afterMs: 0)
    }

    private func scheduleNextFusionTick(afterMs delayMs: Int64) {
        let item = DispatchWorkItem { [weak self] in
            self?.runFusionTick()
        }
        fusionLoopWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: item)
    }

    private func runFusionTick() {
        let t0 = DispatchTime.now() // NEW

        if !isAnalysisPaused {
            performFusion()
        }

        let elapsedNs = DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds
        let elapsedMs = Int64(elapsedNs / 1_000_000)
        let nextDelay = max(Int64(0), FUSION_INTERVAL_MS - elapsedMs) // NEW

        scheduleNextFusionTick(afterMs: nextDelay) // NEW
    }



    // MARK: - 视频分析线程（后台线程）
    //
    // 每 250ms 一轮：抽 1 帧 → 缩放到 160×160 → 推入环形缓冲（最多 12 帧 = 3 秒窗口）
    //   若 缓冲 < 12 帧：return（预热）
    //   若 now - lastVideoInferenceMs < 500ms：return
    //   否则：classifier.predict(12帧) → 分组概率决策
    func performVideoAnalysis() {
        guard !isAnalysisPaused else { return }

        let currentTime = player.currentTime().seconds

        if currentTime >= videoDuration {
            DispatchQueue.main.async { [weak self] in
                if !(self?.isVideoCompleted ?? true) {
                    self?.isVideoCompleted = true
                    self?.pauseAnalysis()
                    print("🎞️ 视频播完，暂停分析等待用户操作")
                }
            }
            return
        }

        // 1. 抽帧
        guard let extractor = videoFrameExtractor,
              let rawFrame = extractor.frame(at: Int64(currentTime * 1_000_000)) else {
            print("未能提取帧")
            return
        }

        // 2. 缩放为 160×160（RGB 在分类器内部统一处理）
        guard let frame160 = VideoClassifierHelper.resizeTo160(rawFrame) else {
            print("❌ [视频线程] 帧缩放失败")
            return
        }

        // 3. 推入环形缓冲（最多 12 帧）
        frameBuffer.append(frame160)
        if frameBuffer.count > FRAME_BUFFER_SIZE {
            frameBuffer.removeFirst(frameBuffer.count - FRAME_BUFFER_SIZE)
        }

        // 4. 预热不足
        if frameBuffer.count < FRAME_BUFFER_SIZE {
            return
        }

        // 5. 推理步长门控（500ms）
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if nowMs - lastVideoInferenceMs < VIDEO_INFER_STEP_MS {
            return
        }
        lastVideoInferenceMs = nowMs

        // 6. 推理
        let inferStart = Date()
        guard let result = videoClassifier.predict(frames: frameBuffer) else {
            print("❌ [视频线程] MobileNetV3 推理失败")
            return
        }
        let inferMs = Date().timeIntervalSince(inferStart) * 1000
        let probs = result.probs

        // 7. 分组概率决策（类目顺序 [plot, oral, sex]）
        //    pDo = P(oral)+P(sex)，pPlot = P(plot)
        //    判定顺序固定：先 do、后 Noise、否则 unclear；置信度取分组后的概率
        let action: String
        let confidence: Float

        if result.index < 0 || probs.count < 3 {
            action = ""
            confidence = 0
        } else {
            let pDo = probs[1] + probs[2]
            let pPlot = probs[0]
            if pDo >= VIDEO_DO_PROB_THRESHOLD {
                action = "do"
                confidence = pDo
            } else if pPlot >= VIDEO_PLOT_PROB_THRESHOLD {
                action = "Noise"
                confidence = pPlot
            } else {
                action = ""
                confidence = 0
                print(String(format: "📸 视频 unclear: pDo=%.3f < %.2f 且 pPlot=%.3f < %.2f",
                             pDo, VIDEO_DO_PROB_THRESHOLD, pPlot, VIDEO_PLOT_PROB_THRESHOLD))
            }
        }

        print(String(format: "📸 [视频线程] 推理 %.1fms | %@ p=%.3f | normal=%.3f oral=%.3f sex=%.3f",
                     inferMs,
                     action.isEmpty ? "(unclear)" : action,
                     confidence,
                     probs.count > 0 ? probs[0] : 0,
                     probs.count > 1 ? probs[1] : 0,
                     probs.count > 2 ? probs[2] : 0))

        // 8. 动作 + 置信度 + 产出时刻打包成一个对象整体发布（unclear 也发布：融合仲裁按产出时刻去重、计数）。
        //    推理和发布都在 videoAnalysisQueue 上，seek 清帧窗也在这条串行队列上，两者不会交错
        self.analysisResults.videoResult = FusionArbiter.Result(action: action, conf: confidence,
                                                                tsMs: FusionArbiter.nowMs())
    }


    // MARK: - 音频分析线程（后台线程）
    func performAudioAnalysis() {
        guard !isAnalysisPaused else { return }
        
        let currentTime = player.currentTime().seconds
        let currentTimeMs = Int64(currentTime * 1000)
        
        // 音频死区 2s：模型窗口只需要 [T-2s, T] 共 2 秒数据，
        // readWindowRelaxed 在有效样本不足 90% 时返回 null 自我保护，等满 2 秒即可开始尝试
        if currentTimeMs - audioStartTime < 2000 {
            print("⏳ [音频线程] 等待 PCM 缓冲填充中")
            return
        }

        let segment = pcmBuffer.readWindowRelaxed(currentTimeMs: currentTimeMs, sampleCount: 32000)
        if let segment = segment {
            let yamnetStart = Date()

            let (index, confidence, probs, audioSet) = audioHelper.predict(audioBuffer: segment)

            let yamnetTime = Date().timeIntervalSince(yamnetStart) * 1000
            //print(String(format: "🎵 [音频线程] YAMNet 音频分析耗时: %.2f ms", yamnetTime))

            // 分组概率决策（类目顺序 [sex, oral, noise]）
            //   pDo = P(sex)+P(oral)，pNoise = P(noise)
            //   判定顺序固定：先 do、后 Noise、否则 unclear；置信度取分组后的概率
            let action: String
            let outConf: Float

            if index < 0 || probs.count < 3 {
                action = ""
                outConf = 0
                print("⚠️ [音频线程] 音频分析返回了无效结果: idx=\(index), probs=\(probs.count)")
            } else {
                let pDo = probs[0] + probs[1]
                let pNoise = probs[2]
                if pDo >= AUDIO_DO_PROB_THRESHOLD {
                    action = "do"
                    outConf = pDo
                } else if pNoise >= AUDIO_NOISE_PROB_THRESHOLD {
                    action = "Noise"
                    outConf = pNoise
                } else {
                    action = ""
                    outConf = 0
                    print(String(format: "🎵 [音频线程] unclear: pDo=%.3f < %.2f 且 pNoise=%.3f < %.2f",
                                 pDo, AUDIO_DO_PROB_THRESHOLD, pNoise, AUDIO_NOISE_PROB_THRESHOLD))
                }
            }

            // [音频线索] YAMNet 自带的 AudioSet 分数判"这一刻音频靠不靠得住"（对白 / 听不出 / 人声 …），
            // 只给融合仲裁的启动判断用，不改上面的分类判定（规则见 AudioCue、FusionArbiter）
            let cue = AudioCue.of(audioSet)

            // 动作 + 置信度 + 产出时刻 + 线索打包成一个对象整体发布（unclear 也发布：融合仲裁按产出时刻去重、计数）。
            // 推理和发布都在 audioAnalysisQueue 上，seek 清 PCM 也在这条串行队列上，两者不会交错
            self.analysisResults.audioResult = FusionArbiter.Result(action: action, conf: outConf,
                                                                    tsMs: FusionArbiter.nowMs(), cue: cue)

            print(String(format: "✅ 🎵 [音频线程] 音频类型 = %@, 原始idx=%d, 原始p=%.3f, 线索=%@",
                         action.isEmpty ? "(unclear)" : action, index, confidence,
                         cue == AudioCue.unknown ? "(未知)" : AudioCue.name(cue)))
        }
        
        /*
        // ===== 🆕 音频节奏分析 =====
        // 读取最后1秒的数据用于节奏分析
        if let last1s = pcmBuffer.readWindowRelaxed(currentTimeMs: currentTimeMs, sampleCount: 16000) {
            if last1s.count > 0 {
                audioRhythmEstimator.push(last1s)  // 将~1秒追加到4秒内部缓冲区
            }
        }
        // 仅在预热时(累积>=4秒)且每~1秒节拍一次时估计
        if audioRhythmEstimator.isWarm() {
            let currentMs = Int64(Date().timeIntervalSince1970 * 1000)
            let rhythmResult = audioRhythmEstimator.estimate(currentMs)
                
            // 存储到线程安全的结果容器
            self.analysisResults.audioRhythm = (
                hz: rhythmResult.frequencyHz,
                conf: rhythmResult.confidence,
                tsMs: rhythmResult.timestampMs,
                valid: rhythmResult.valid
            )
                
            // 打印调试信息
            print(String(format: "[频率测试] 音频节奏 - 有效:%@, 频率:%.2f Hz, 置信度:%.2f",
                         rhythmResult.valid ? "是" : "否",
                         rhythmResult.frequencyHz,
                         rhythmResult.confidence))
        }
        */
        
        // **************[MOD] 音频 Loudness → 档位分析（替代频率估计）**************
        if let last1s = pcmBuffer.readWindowRelaxed(currentTimeMs: currentTimeMs, sampleCount: 8000),
           !last1s.isEmpty {

            audioLoudnessEstimator.push(pcm: last1s)
            let lr = audioLoudnessEstimator.estimate(nowMs: Int64(Date().timeIntervalSince1970 * 1000))

            // 存储到线程安全结果容器
            analysisResults.audioLoudnessLevel = (
                level: lr.level,
                conf: lr.confidence,
                tsMs: lr.timestampMs,
                valid: lr.valid
            )

            print(String(format: "[响度档位] valid:%@, level:%d, conf:%.2f, db:%.1f",
                         lr.valid ? "是" : "否",
                         lr.level,
                         lr.confidence,
                         lr.db))
        }
        //********************************************************************

    }

    // MARK: - 融合和UI更新（主线程）
    func performFusion() {
        guard !isAnalysisPaused else { return }

        // 每一路只读一个结果对象：动作、置信度、产出时刻保证来自同一次推理
        let videoResult = analysisResults.videoResult
        let audioResult = analysisResults.audioResult
        // let audioRhythm = analysisResults.audioRhythm
        let loud = analysisResults.audioLoudnessLevel
        // 视频节律已移除，不再读取 videoFreq
        // let videoFreq = analysisResults.videoFreq

        // 🆕 计算结果的新鲜度（毫秒）。先读结果再取 now，保证结果的产出时刻 <= now
        let now = FusionArbiter.nowMs()
        let videoTs = videoResult?.tsMs ?? 0
        let audioTs = audioResult?.tsMs ?? 0
        // let audiofreqAge = audioRhythm.tsMs > 0 ? currentTime - Double(audioRhythm.tsMs) : Double.greatestFiniteMagnitude
        let loudAge: Int64 = loud.tsMs > 0 ? now - loud.tsMs : Int64.max

        // 🆕 过滤超过2秒的过期数据
        let MAX_AGE: Int64 = 2000 // 2秒

        var filteredVideoAction = videoResult?.action ?? ""
        var filteredVideoConfidence: Float = videoResult?.conf ?? 0
        var filteredAudioAction = audioResult?.action ?? ""
        var filteredAudioConfidence: Float = audioResult?.conf ?? 0
        // 音频线索与音频结果来自同一个结果对象。结果过期时动作串会被清空，线索照样传给仲裁：
        // 账本只在记新结果时记线索，过期的结果本来就不记
        let audioCue = audioResult?.cue ?? AudioCue.unknown

        // var audioFreq = audioRhythm.hz
        // var audioFreqConf = audioRhythm.conf
        var audioLevelLike: Float = Float(loud.level)  // 用 level(float) 复用现有 computeFinalFreq 管线
        var audioLevelConf: Float = loud.conf

        /*
        // 如果音频频节奏结果过期或无效，清空它
        if !audioRhythm.valid || audiofreqAge > MAX_AGE {
            audioFreq = .nan
            audioFreqConf = 0.0
        }
        */
        if !loud.valid || loudAge > MAX_AGE {
            audioLevelLike = .nan
            audioLevelConf = 0.0
        }

        // 如果视频结果过期（或还没有结果），清空它
        if videoTs <= 0 || now - videoTs > MAX_AGE {
            filteredVideoAction = ""
            filteredVideoConfidence = 0
        }

        // 如果音频结果过期（或还没有结果），清空它
        if audioTs <= 0 || now - audioTs > MAX_AGE {
            filteredAudioAction = ""
            filteredAudioConfidence = 0
        }

        // 视频/音频统一词表已经是 {"do", "Noise", ""}，不再需要 oral→do 映射
        // if filteredVideoAction == "oral" { filteredVideoAction = "do" }
        // if filteredAudioAction == "oral" { filteredAudioAction = "do" }

        // 视频节律已移除，computeFinalFreq 只依赖音频响度档位
        var finalfreq = computeFinalFreq(
            audioHz: audioLevelLike, audioConf: audioLevelConf,
            videoHz: .nan, videoConf: 0
        )
            
        // 更新UI
        if !filteredVideoAction.isEmpty {
            tvVideoAction.text = String(format: "V: %@ (p=%.2f)", filteredVideoAction, filteredVideoConfidence)
        }
            
        if !filteredAudioAction.isEmpty {
            // 末尾显示音频线索的中文名（未知时不显示），例如 "A: do (p=0.83) · 人声"
            tvAudioAction.text = String(format: "A: %@ (p=%.2f)", filteredAudioAction, filteredAudioConfidence)
                + (audioCue == AudioCue.unknown ? "" : " · " + AudioCue.label(audioCue))
        }
            
        // 🆕 融合仲裁：启动 / 维持 / 停止分开判断，证据按"新推理结果"计数（按产出时刻去重）。
        // 过期结果的产出时刻照样传进去，账本自己去重 / 丢弃；motorOn 必须在 updateBluetoothState 之前取。
        // 音频线索（v2）只用于启动：对白否决、音频听不出时视频单独启动
        let finalAction = fusionArbiter.decide(
            now: now,
            vAction: filteredVideoAction, vConf: filteredVideoConfidence, vTs: videoTs > 0 ? videoTs : -1,
            aAction: filteredAudioAction, aConf: filteredAudioConfidence, aTs: audioTs > 0 ? audioTs : -1,
            aCue: audioCue,
            motorOn: isSexAction(currentBluetoothState)
        )
        print("[融合仲裁] \(fusionArbiter.lastReason) -> \(finalAction.isEmpty ? "(不驱动)" : finalAction)")

        // 🆕 使用稳定的蓝牙发送策略（"" = 本 tick 不驱动蓝牙状态机）
        if !finalAction.isEmpty {
            updateBluetoothState(finalAction, finalfreq)
        }
            
        // 🆕 更新UI, 显示蓝牙实际发送的动作
        if !latestBluetoothAction.isEmpty {
            tvOverlay.text = "Final: \(latestBluetoothAction) | freq: \(finalfreq)"
        } else {
            tvOverlay.text = "Final: 等待识别..."
        }
    }
    
    // 🆕 MARK: - 马达档位映射
    // === 频率 -> 10 档映射表（index 1..10：对应档位1~10；0为停止）===
    // 说明：1 次抽插 = 马达 3 转；freq = RPM / 180；当前硬件可达范围约 1.0–1.8 Hz
    private let LEVEL_RANGES: [ClosedRange<Float>?] = [
        nil,            // 0 占位（停止）

        0.95...1.12,    // 档1  ≈ 190 RPM  (1.06 Hz)
        1.12...1.27,    // 档2  ≈ 220 RPM  (1.22 Hz)
        1.27...1.40,    // 档3  ≈ 240 RPM  (1.33 Hz)
        1.40...1.53,    // 档4  ≈ 270 RPM  (1.50 Hz)
        1.53...1.58,    // 档5  ≈ 280 RPM  (1.56 Hz)
        1.58...1.63,    // 档6  ≈ 290 RPM  (1.61 Hz)
        1.63...1.66,    // 档7  ≈ 295 RPM  (1.64 Hz)
        1.66...1.70,    // 档8  ≈ 300 RPM  (1.67 Hz)
        1.70...1.75,    // 档9  ≈ 310 RPM  (1.72 Hz)
        1.75...1.85     // 档10 ≈ 320 RPM  (1.78 Hz，上沿留余量)
    ]


    // === 🆕 把 Hz 映射为 0..9 档（0为停止），10档也当作第9档 ===
    // 等工厂确定值后，只需替换 LEVEL_RANGES 即可
    private func mapFreqToLevel(_ hz: Float) -> Int {
        if hz.isNaN || hz <= 0 {
            return 0
        }
        for lvl in 1...9 {
            if let range = LEVEL_RANGES[lvl],
               range.contains(hz) {
                return lvl
            }
        }
        return 9 // 超出则钳到最高档
    }
    
    // [ADD] audioHz 实际承载的是 loudness level（Float），这里钳制到 0..8
    private func clampLevelFromLoudness(_ levelLike: Float) -> Int {
        if levelLike.isNaN { return 0 }
        var lv = Int(levelLike.rounded())
        if lv < 0 { lv = 0 }
        if lv > 8 { lv = 8 }
        return lv
    }

    
    
    // 🆕 MARK: - 计算最终节律档位
    // 计算最终节律档位：当前先以“音频节律”为主，但带置信度阈值 + 方向性门控（涨档更严格、降档更宽松）
    private func computeFinalFreq(
        audioHz: Float, audioConf: Float,
        videoHz: Float, videoConf: Float
    ) -> Int {

        // 先做“临时策略”：candidate 仍以音频为主（后续要融合音视频节律，就只改这里）
        // var finalFreq = mapFreqToLevel(audioHz)
        var finalFreq = clampLevelFromLoudness(audioHz)  // [MOD] audioHz 实际承载的是 loudness level

        let videoLvl = mapFreqToLevel(videoHz)

        // 日志：对齐 Android，方便你对比
        NSLog("[视频节律] 得到视频节律: %.3f 置信度: %.3f 档位: %d", videoHz, videoConf, videoLvl)
        NSLog("[音频节律] 得到音频节律: %.3f 置信度: %.3f 档位: %d", audioHz, audioConf, finalFreq)

        // === 方向性置信度门控（涨档更严格，降档更宽松） ===
        let CONF_IGNORE: Float = 0.10   // 极低置信度：整体忽略本次节律
        let CONF_UP: Float     = 0.10   // 涨档所需置信度（更严格）
        let CONF_DOWN: Float   = 0.10   // 降档所需置信度（相对宽松）

        let curLevel = self.currentLevel              // 当前已生效档位（0..10）:contentReference[oaicite:2]{index=2}
        let candidateLevel = finalFreq                // 本次根据 audioHz 映射出的档位

        // 1) 极低置信度 or 无效频率：直接忽略，沿用 currentLevel（不给 updateBluetoothState 变档机会）
        if audioHz.isNaN || audioConf < CONF_IGNORE {
            NSLog("[音频节律] conf=%.2f < CONF_IGNORE=%.2f，本次节律整体忽略，沿用 currentLevel=%d",
                  audioConf, CONF_IGNORE, curLevel)
            finalFreq = curLevel
            return finalFreq
        }

        // 2) 按“变档方向”应用不同门槛
        if candidateLevel > curLevel && audioConf < CONF_UP {
            NSLog("[音频节律] 尝试涨档 %d→%d 但 conf=%.2f < CONF_UP=%.2f，本次不生效，沿用 currentLevel=%d",
                  curLevel, candidateLevel, audioConf, CONF_UP, curLevel)
            finalFreq = curLevel
        } else if candidateLevel < curLevel && audioConf < CONF_DOWN {
            NSLog("[音频节律] 尝试降档 %d→%d 但 conf=%.2f < CONF_DOWN=%.2f，本次不生效，沿用 currentLevel=%d",
                  curLevel, candidateLevel, audioConf, CONF_DOWN, curLevel)
            finalFreq = curLevel
        }
        // candidateLevel == curLevel：无需处理

        return finalFreq
    }


    // MARK: - 更新蓝牙状态 - 二级平滑策略
    private func updateBluetoothState(_ newAction: String, _ finalFreq: Int) {
        let currentTime = Date().timeIntervalSince1970 * 1000  // ms
        
        // 1) 本地暂停保护
        if BluetoothManager.shared.isPausedByLocal {
            print("[蓝牙] ⚠️ 设备已暂停App控制，忽略动作: \(newAction)")
            return
        }
        
        // ===================== [档位确认：立即生效版] =====================
        // 只根据本轮 newAction 判断是否支持变速。
        // 不再依赖 currentBluetoothState，避免 Noise -> do/oral 时档位状态不同步。
        let supportsLevel = isSexAction(newAction)
        
        if supportsLevel {
            var latestLevel = finalFreq
            
            // 安全钳制到 0..8，与 Android 新逻辑一致
            if latestLevel < 0 { latestLevel = 0 }
            if latestLevel > 8 { latestLevel = 8 }
            
            // 迟滞：只有跨过 currentLevel ± 1 才认为值得处理
            let worthHandling =
                latestLevel >= upThreshold(currentLevel) ||
                latestLevel <= downThreshold(currentLevel)
            
            if worthHandling {
                // 关键修复：
                // LEVEL_STABLE_MS = 0 时，第一次看到新档位就立即生效，
                // 不再要求连续两轮融合循环给出同一档位。
                if LEVEL_STABLE_MS <= 0 &&
                    (currentTime - currentLevelSinceMs >= LEVEL_MIN_DUR_MS) {
                    
                    if latestLevel != currentLevel {
                        print(String(format: "[档位确认] 立即生效: %d -> %d",
                                     currentLevel,
                                     latestLevel))
                    }
                    
                    currentLevel = latestLevel
                    currentLevelSinceMs = currentTime
                    pendingLevel = nil
                    pendingLevelSinceMs = 0
                    
                } else {
                    // 如果以后 LEVEL_STABLE_MS 改成 >0，则走短稳确认逻辑
                    if pendingLevel == nil || pendingLevel! != latestLevel {
                        pendingLevel = latestLevel
                        pendingLevelSinceMs = currentTime
                        
                        print(String(format: "[档位确认] 新 pendingLevel=%d，开始等待稳定",
                                     latestLevel))
                        
                    } else {
                        let dwell = currentTime - pendingLevelSinceMs
                        let stableOk = dwell >= LEVEL_STABLE_MS
                        let minDurOk = currentTime - currentLevelSinceMs >= LEVEL_MIN_DUR_MS
                        
                        if stableOk && minDurOk {
                            if pendingLevel! != currentLevel {
                                print(String(format: "[档位确认] pending 生效: %d -> %d, dwell=%.0fms",
                                             currentLevel,
                                             pendingLevel!,
                                             dwell))
                            }
                            
                            currentLevel = pendingLevel!
                            currentLevelSinceMs = currentTime
                            pendingLevel = nil
                            pendingLevelSinceMs = 0
                        }
                    }
                }
            } else {
                // 未跨过迟滞门槛，不处理档位变化
                pendingLevel = nil
                pendingLevelSinceMs = 0
            }
        } else {
            // Noise 或其他不支持变速的动作，不处理档位
            pendingLevel = nil
            pendingLevelSinceMs = 0
        }
        // ===================== [档位确认结束] =====================
        
        
        // ===================== [动作待确认] =====================
        if newAction != pendingBluetoothState {
            pendingBluetoothState = newAction
            pendingStateStartTime = currentTime
            print(String(format: "[蓝牙] 检测到新动作: %@, 等待确认...", newAction))
        }
        
        // 动作稳定确认时间：
        // 默认 0ms；如果从 do/oral 切到 Noise，则延长到 1000ms，避免动作中突然停。
        var actionStableMs: TimeInterval = 0
        if isSexAction(currentBluetoothState) && newAction == "Noise" {
            actionStableMs = 1000
        }
        
        let actionStableOk =
            pendingBluetoothState == newAction &&
            (currentTime - pendingStateStartTime) >= actionStableMs
        
        if !actionStableOk {
            print(String(format: "[蓝牙] 动作尚未稳定: pending=%@, new=%@, 已稳定=%.0fms, 需要=%.0fms",
                         pendingBluetoothState,
                         newAction,
                         currentTime - pendingStateStartTime,
                         actionStableMs))
            return
        }
        
        
        // ===================== 情况 A：动作发生变化 =====================
        if pendingBluetoothState != currentBluetoothState {
            
            let minDurationOk =
                currentBluetoothState.isEmpty ||
                (currentTime - currentStateStartTime) >= BLUETOOTH_MIN_DURATION
            
            if !minDurationOk {
                let remainingTime = BLUETOOTH_MIN_DURATION - (currentTime - currentStateStartTime)
                print(String(format: "[蓝牙] 当前动作%@需继续保持%.0fms，暂不切换到%@",
                             currentBluetoothState,
                             remainingTime,
                             pendingBluetoothState))
                return
            }
            
            let gapOk = (currentTime - lastBluetoothSendTime) >= BLUETOOTH_SEND_INTERVAL
            
            if !gapOk {
                print(String(format: "[蓝牙] 动作切换等待发送间隔: gap=%.0fms, need=%.0fms",
                             currentTime - lastBluetoothSendTime,
                             BLUETOOTH_SEND_INTERVAL))
                return
            }
            
            let levelToSend: Int
            if isSexAction(pendingBluetoothState) {
                // 切换到 do/oral 时，携带当前已确认档位
                levelToSend = currentLevel
            } else {
                // 切换到 Noise 时，档位置 0
                levelToSend = 0
            }
            
            print(String(format: "[蓝牙] [同步分析] ✅ 发送指令: action=%@, level=%d, 已稳定=%.0fms",
                         pendingBluetoothState,
                         levelToSend,
                         currentTime - pendingStateStartTime))
            
            latestBluetoothAction = pendingBluetoothState
            
            if BluetoothManager.shared.isConnected {
                BluetoothManager.shared.sendAction(pendingBluetoothState, levelToSend)
                print("[蓝牙] [同步分析] ✅ 已通过BLE发送指令(动作切换/含档位)")
                print("[音频节律] ✅ 发送节律：\(levelToSend)")
            } else {
                print("[蓝牙] BLE未连接，仅更新UI显示")
            }
            
            currentBluetoothState = pendingBluetoothState
            currentStateStartTime = currentTime
            lastBluetoothSendTime = currentTime
            
            // 关键同步：
            // 保证 currentLevel / lastSentLevel / 实际发送档位一致。
            if isSexAction(currentBluetoothState) {
                currentLevel = levelToSend
                currentLevelSinceMs = currentTime
                lastSentLevel = levelToSend
            } else {
                lastSentLevel = 0
            }
            
            return
        }
        
        
        // ===================== 情况 B：动作未变，但档位变化 =====================
        // 例如当前仍然是 do，但档位从 8 降到 4。
        // 由于协议没有单独速度帧，所以重发同一动作并携带新档位。
        let levelChanged = supportsLevel && (currentLevel != lastSentLevel)
        let gapOk = (currentTime - lastBluetoothSendTime) >= BLUETOOTH_SEND_INTERVAL
        
        print(String(format: "[档位发送判断] action=%@, supportsLevel=%@, currentLevel=%d, lastSentLevel=%d, levelChanged=%@, gapOk=%@, gap=%.0fms",
                     currentBluetoothState,
                     supportsLevel ? "true" : "false",
                     currentLevel,
                     lastSentLevel,
                     levelChanged ? "true" : "false",
                     gapOk ? "true" : "false",
                     currentTime - lastBluetoothSendTime))
        
        if levelChanged && gapOk {
            let levelToSend = currentLevel
            
            print(String(format: "[蓝牙] 同动作更新档位：%@ -> level=%d",
                         currentBluetoothState,
                         levelToSend))
            
            if BluetoothManager.shared.isConnected {
                BluetoothManager.shared.sendAction(currentBluetoothState, levelToSend)
                print("[蓝牙] [同步分析] ✅ 已通过BLE发送指令(同动作/更新档位)")
                print("[音频节律] ✅ 发送节律：\(levelToSend)")
            } else {
                print("[蓝牙] BLE未连接，无法更新档位（同动作）")
            }
            
            lastSentLevel = levelToSend
            lastBluetoothSendTime = currentTime
        }
    }

    // ===================== 蓝牙更新状态的工具类函数 =====================

    // 迟滞阈值
    @inline(__always) private func upThreshold(_ cur: Int) -> Int {
        return min(8, cur + 1)
    }

    @inline(__always) private func downThreshold(_ cur: Int) -> Int {
        return max(0, cur - 1)
    }

    // 当前动作是否属于支持变速的动作
    private func isSexAction(_ action: String) -> Bool {
        let lower = action.lowercased()
        return lower.hasPrefix("do") || lower.hasPrefix("oral")
    }

    // 新版 updateBluetoothState 已不再依赖这个函数。
    // 如果其他地方没用，可以保留，也可以删除。
    private func currentStateSupportsSpeed() -> Bool {
        let lower = currentBluetoothState.lowercased()
        return lower.hasPrefix("do") || lower.hasPrefix("oral")
    }


    // MARK: - 处理用户拖动
    func handleUserSeek(currentMs: Int64) {
        print("🟡 检测到用户拖动播放，准备延迟处理")
        
        pendingSeekWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            print("✅ 执行用户拖动后的 seek 处理逻辑，时间点: \(currentMs)ms")

            // 1) 在分析队列里清帧窗 / PCM。两条分析队列都是串行队列，推理 + 发布结果也在上面执行
            //    （相当于 Android 的 videoLock / audioLock）：seek 之前开始的推理一定在清空之前发布完
            let buffersCleared = DispatchGroup()

            buffersCleared.enter()
            self.videoAnalysisQueue.async {
                // 🆕 清空视频分类滑动窗口
                self.frameBuffer.removeAll()
                self.lastVideoInferenceMs = 0

                // 旧的姿态/ST-GCN++ 状态已弃用：
                // self.poseWindow.removeAll()
                // self.poseWindow8.removeAll()
                // self.framesSinceLastMulti = 0

                // 视频节律已移除：
                // self.videoRhythmEstimator.reset()
                buffersCleared.leave()
            }

            buffersCleared.enter()
            self.audioAnalysisQueue.async {
                self.audioDecoder.stop()          // 先让旧解码线程退出，再清缓冲，避免旧位置的音频写进清空后的缓冲
                self.pcmBuffer.reset()
                self.audioDecoder.seekTo(Int(currentMs))
                self.audioStartTime = currentMs
                // 🆕 重置音频节奏器
                // self.audioRhythmEstimator.reset()
                self.audioLoudnessEstimator.reset()
                buffersCleared.leave()
            }

            self.lastFinalAction = ""

            // 2)~4) 两路缓冲都清完后回到主线程（融合线程），顺序与 Android handleSeekComplete 一致
            buffersCleared.notify(queue: .main) { [weak self] in
                guard let self = self else { return }

                // 2) 清空融合仲裁的证据：seek 之前产出的结果一律不算。放在清完缓冲之后，
                //    seek 前开始的推理此时已经发布、产出时刻早于 reset，会被当成旧结果丢掉
                self.fusionArbiter.reset(FusionArbiter.nowMs())

                // 🆕 重置分析结果中的节奏数据（视频和音频）
                self.analysisResults.resetRhythm()

                // 3) 重置蓝牙状态（原来在视频队列里改，和主线程的 updateBluetoothState 有竞争，挪到主线程）
                self.pendingBluetoothState = ""
                self.currentBluetoothState = ""
                self.pendingStateStartTime = 0
                self.currentStateStartTime = 0

                // 重置档位确认状态
                self.currentLevel = 1
                self.currentLevelSinceMs = 0
                self.pendingLevel = nil
                self.pendingLevelSinceMs = 0
                self.lastSentLevel = 0

                // ★ 新增：清空挂起状态
                self.suspendedBluetoothState = ""
                self.suspendedLevel = 0

                // 4) 播放过完片尾后，如果用户 seek 了，撤销“已播完”标记。放在清空蓝牙状态 / 挂起动作之后：
                //    否则 resumeAnalysis 会先把播完前挂起的旧动作发出去，紧接着状态又被清空，app 和设备就对不上了
                if self.isVideoCompleted {
                    self.isVideoCompleted = false
                    // 只有播放器处于播放状态时才恢复分析
                    if self.player.rate != 0 {
                        self.resumeAnalysis()
                    }
                }
            }
        }
        
        pendingSeekWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    // MARK: - 播放状态监听
    // ⏱️ 播放状态检测逻辑：每 200ms 检测一次播放器是否暂停
    func startPlaybackObserver() {
        playStateTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            let isCurrentlyPlaying = self.player.rate != 0
            
            if isCurrentlyPlaying != self.lastIsPlaying {
                self.lastIsPlaying = isCurrentlyPlaying
                
                if isCurrentlyPlaying {
                    self.resumeAnalysis()
                } else {
                    self.pauseAnalysis()
                }
            }
        }
    }

    // MARK: - 暂停与恢复
    func pauseAnalysis() {
        isAnalysisPaused = true

        // ★ 新增：挂起当前蓝牙动作并发送停止信号
        if !currentBluetoothState.isEmpty && currentBluetoothState != "Noise" {
            if fusionArbiter.lastDoHadEvidence {
                suspendedBluetoothState = currentBluetoothState
                suspendedLevel = currentLevel
                print("[暂停] 挂起动作: \(suspendedBluetoothState), 档位: \(suspendedLevel)")
            } else {
                // 🆕 [融合仲裁] 马达此刻只是仲裁器在"等结果"（刚 seek / 恢复后的冷启动，或看不清听不清），
                // 没有证据撑着：不带过暂停，状态同步成 Noise（下面照常发 Noise），恢复后从头判断
                let now = Date().timeIntervalSince1970 * 1000
                currentBluetoothState = "Noise"
                currentStateStartTime = now
                pendingBluetoothState = "Noise"
                pendingStateStartTime = now
                latestBluetoothAction = "Noise"
                print("[暂停] 马达没有证据撑着（\(fusionArbiter.lastReason)），不挂起，恢复后重新判断")
            }
        }
        if BluetoothManager.shared.isConnected && !BluetoothManager.shared.isPausedByLocal {
            BluetoothManager.shared.sendAction("Noise", 0)
            print("[暂停] 已发送停止信号(Noise)")
        }

        print("⏸️ 分析暂停")
    }

    func resumeAnalysis() {
        isAnalysisPaused = false
        // 🆕 [融合仲裁] 暂停前的证据已经过时，清空重来。恢复后马达若仍在转，仲裁会先等两路攒够新结果
        // （wait_sparse，最多 6 秒），不会因为某一路刚出的一个"不转"就停。
        // iOS 没有网页视频模式（VAD 静音暂停），离线模式的恢复都不需要静音预热
        fusionArbiter.reset(FusionArbiter.nowMs())

        // ★ 新增：恢复挂起的蓝牙动作
        if !suspendedBluetoothState.isEmpty {
            print("[恢复] 恢复动作: \(suspendedBluetoothState), 档位: \(suspendedLevel)")
            currentBluetoothState = suspendedBluetoothState
            currentLevel = suspendedLevel
            currentStateStartTime = Date().timeIntervalSince1970 * 1000
            currentLevelSinceMs = Date().timeIntervalSince1970 * 1000

            if BluetoothManager.shared.isConnected && !BluetoothManager.shared.isPausedByLocal {
                BluetoothManager.shared.sendAction(suspendedBluetoothState, suspendedLevel)
                lastBluetoothSendTime = Date().timeIntervalSince1970 * 1000
                lastSentLevel = suspendedLevel
                print("[恢复] 已发送恢复动作: \(suspendedBluetoothState) 档位: \(suspendedLevel)")
            }

            suspendedBluetoothState = ""
            suspendedLevel = 0
        }

        print("▶️ 分析恢复")
    }

    // MARK: - 视频结束处理
    @objc func videoDidEnd() {
        // 这个通知不保证在主线程投递；暂停要读融合仲裁、改蓝牙状态（都只在主线程访问），先切回主线程
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.videoDidEnd() }
            return
        }
        isVideoCompleted = true
        pauseAnalysis()

        // 视频节律已移除：
        // videoRhythmEstimator?.reset()
        // audioRhythmEstimator?.reset()
        self.audioLoudnessEstimator.reset()

        // 重置存储的结果
        analysisResults.resetRhythm()

        // 清空视频分类滑动窗口
        videoAnalysisQueue.async { [weak self] in
            self?.frameBuffer.removeAll()
            self?.lastVideoInferenceMs = 0
        }

        print("视频播放完成，已暂停分析等待用户操作")
    }

    // MARK: - 其他功能保持不变
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = videoView.bounds
    }

    // MARK: - 全屏控制，全屏与退出全屏
    // 加一个可变的方向掩码属性
    private var allowedOrientations: UIInterfaceOrientationMask = .portrait

    @objc func toggleFullscreen() {
        isFullscreen.toggle()
        
        allowedOrientations = isFullscreen ? .landscapeRight : .portrait
        
        if #available(iOS 16.0, *) {
            if let windowScene = view.window?.windowScene {
                let prefs = UIWindowScene.GeometryPreferences.iOS(
                    interfaceOrientations: allowedOrientations
                )
                windowScene.requestGeometryUpdate(prefs) { error in
                    if let err = error as? NSError {
                        print("❌ 方向切换失败: \(err.localizedDescription)")
                    }
                }
            }
        } else {
            // ---------------------- iOS 15 兜底 ----------------------
            // 只有 15 或更早系统才会走到这里
            UIDevice.current.setValue(
                allowedOrientations == .landscapeRight
                ? UIInterfaceOrientation.landscapeRight.rawValue
                : UIInterfaceOrientation.portrait.rawValue,
                forKey: "orientation"
            )
            UIViewController.attemptRotationToDeviceOrientation()
        }
        
        // 刷新系统 UI
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfSupportedInterfaceOrientations()
        navigationController?.setNavigationBarHidden(isFullscreen, animated: true)
        
        // 更新按钮图标
        let icon = isFullscreen
          ? "arrow.down.right.and.arrow.up.left"
          : "arrow.up.left.and.arrow.down.right"
        btnFullscreen.setImage(UIImage(systemName: icon), for: .normal)
    }

    // 让控制器返回我们维护的掩码
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        allowedOrientations
    }

    //（可选）如果你想彻底隐藏状态栏
    override var prefersStatusBarHidden: Bool { isFullscreen }

    // MARK: - 播放控制
    @objc func togglePlayPause() {
        if player.rate == 0 {
            // ▶️ 当前是暂停 → 恢复播放 + 分析
            player.play()
            resumeAnalysis()
            let icon = UIImage(systemName: "pause.fill")
            btnPlayPause.setImage(icon, for: .normal)
            print("▶️ 用户点击：恢复播放")
        } else {
            // ⏸️ 当前是播放 → 暂停播放 + 分析
            player.pause()
            pauseAnalysis()
            let icon = UIImage(systemName: "play.fill")
            btnPlayPause.setImage(icon, for: .normal)
            print("⏸️ 用户点击：暂停播放")
        }
    }

    // MARK: - 进度条控制
    @objc func sliderTouchDown() {
        isSeekingByUser = true
        player.pause()
    }

    @objc func sliderValueChanged() {
        let targetTime = CMTime(seconds: Double(progressSlider.value), preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        
        // 🆕 拖动时实时更新当前时间显示
        currentTimeLabel.text = formatTime(Double(progressSlider.value))
    }

    @objc func sliderTouchUp() {
        isSeekingByUser = false
        let targetTime = CMTime(seconds: Double(progressSlider.value), preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            if finished {
                self.didUserSeek = true // 设置人为拖动 flag
                print("🎯 用户主动 seek 到 \(self.progressSlider.value) 秒")
            }
        }
        player.play()
    }
    
    // MARK: - 进度条点击处理
    @objc func sliderTapped(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: progressSlider)
        let percentage = location.x / progressSlider.bounds.width
        let value = Float(percentage) * (progressSlider.maximumValue - progressSlider.minimumValue) + progressSlider.minimumValue
        
        // 暂停播放
        player.pause()
        
        // 更新进度条值
        progressSlider.value = value
        
        // 跳转到目标时间
        let targetTime = CMTime(seconds: Double(value), preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            if finished {
                self?.didUserSeek = true // 设置人为拖动 flag，触发 handleUserSeek
                print("🎯 用户点击进度条跳转到 \(value) 秒")
            }
        }
        
        // 恢复播放
        player.play()
    }
    
    // MARK: - 🆕 时间格式化
    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else {
            return "0:00"
        }
        
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    // MARK: - 清理资源
    // 用户从 SwiftUI 主页面左滑返回时, 结束播放与分析
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        print("🛑 页面将消失，停止播放与分析")
        
        // ★ 新增：退出时发送停止信号
        if BluetoothManager.shared.isConnected {
            BluetoothManager.shared.sendAction("Noise", 0)
            print("[退出] 已发送停止信号(Noise)")
        }
        
        // 视频节律已移除：
        // videoRhythmEstimator?.reset()
        // audioRhythmEstimator?.reset()
        self.audioLoudnessEstimator.reset()

        // 停止所有定时器
        videoAnalysisTimer?.cancel()
        audioAnalysisTimer?.cancel()
        fusionTimer?.invalidate()
        playStateTimer?.invalidate()
        // 停止自调度循环
        videoLoopWorkItem?.cancel()
        audioLoopWorkItem?.cancel()
        fusionLoopWorkItem?.cancel()
        
        player.pause()
        audioDecoder?.stop()
    }

    deinit {
        videoAnalysisTimer?.cancel()
        audioAnalysisTimer?.cancel()
        fusionTimer?.invalidate()
        playStateTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        audioDecoder?.stop()
        // 停止自调度循环
        videoLoopWorkItem?.cancel()
        audioLoopWorkItem?.cancel()
        fusionLoopWorkItem?.cancel()

    }
}

// MARK: - 工具扩展（保持不变）
extension Array where Element == PoseFrame {
    func toStgcnInput() -> [[[Float]]] {
        // 将滑动窗口 Pose 数据转换为 ST-GCN++ 输入
        return self
    }
}

extension Array where Element == Float {
    func argmax() -> Int {
        guard let maxVal = self.max(), let idx = self.firstIndex(of: maxVal) else { return 0 }
        return idx
    }
    
    func softmax() -> [Float] { // 置信度阈值法, 加 softmax 归一化后再判断
        let expVals = self.map { expf($0) }
        let sumExp = expVals.reduce(0, +)
        return expVals.map { $0 / sumExp }
    }
}

struct Math {
    static func argmax(_ array: [Float]) -> Int {
        guard let maxVal = array.max(), let idx = array.firstIndex(of: maxVal) else { return 0 }
        return idx
    }
}

// [ADD] 直接放在 VideoProcessViewController.swift 底部（工具扩展附近）
// 复刻 Windows ActionUtils.preNormalize2D / MMAction2 PreNormalize2D(align_center=true)
enum ActionUtilsSwift {
    static func preNormalize2D(_ window: [[[Float]]]) -> [[[Float]]] {
        guard !window.isEmpty, !window[0].isEmpty else { return window }

        var xMin = Float.greatestFiniteMagnitude
        var yMin = Float.greatestFiniteMagnitude
        var xMax = -Float.greatestFiniteMagnitude
        var yMax = -Float.greatestFiniteMagnitude

        for frame in window {
            for kp in frame {
                if kp.count < 3 { continue }
                if kp[2] <= 0 { continue }
                xMin = min(xMin, kp[0])
                yMin = min(yMin, kp[1])
                xMax = max(xMax, kp[0])
                yMax = max(yMax, kp[1])
            }
        }

        // 没有人体点：给一个默认 bbox，保持与 Java 版一致的兜底行为
        if xMax < xMin {
            xMin = 0; yMin = 0; xMax = 1; yMax = 1
        }

        let cx = 0.5 * (xMin + xMax)
        let cy = 0.5 * (yMin + yMax)
        var scale = max(xMax - xMin, yMax - yMin)
        if scale < 1e-6 { scale = 1e-6 }

        var out = window
        for t in 0..<out.count {
            for v in 0..<out[t].count {
                out[t][v][0] = (out[t][v][0] - cx) / scale
                out[t][v][1] = (out[t][v][1] - cy) / scale
                // out[t][v][2] = out[t][v][2] // conf 原样保留
            }
        }
        return out
    }
}

