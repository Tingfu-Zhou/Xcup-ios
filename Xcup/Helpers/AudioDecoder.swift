//
//  AudioDecoder.swift
//  Xcup
//
//  Created by tingfu on 2025/4/20.
//


//  对应 Android Java: AudioDecoder.java
//

import Foundation
import AVFoundation

/// 离线模式送进 PcmCircularBuffer 的音频怎么处理。
enum AudioPipeline {
    /// 修复后：按解码输出的真实采样率/声道数下混成 (L+R)/2，用 PcmResampler 抗混叠重采样到 16kHz，
    /// 连续写入、时间戳连续，模型窗口就是真正的 [T-2s, T]。与 Android fixed 管线逐样本一致（resampler_golden.txt 对拍）。
    case fixed
    /// 修复前的旧处理，只为 A/B 对比保留：交错立体声当单声道（0.5 倍速、L/R 交错）、逐块线性插值、
    /// 块时间戳丢成 -1（窗口实际取的是播放位置之后 1~3 秒）。
    case legacy
}

/// 音频解码器：从视频中解码音频 PCM，并写入 CircularBuffer
class AudioDecoder {

    /// 离线模式音频管线（默认 fixed）。改成 .legacy 重新编译，可以回到修复前的处理做对比。
    static let pipeline: AudioPipeline = .fixed

    private let asset: AVAsset
    private let pcmBuffer: PcmCircularBuffer
    private let videoPositionProvider: () -> Int // 视频播放位置获取器（单位：ms）

    private var onCompleteListener: (() -> Void)?

    private let MAX_ADVANCE_MS: Int64 = 3000      // 解码最多超前播放位置 3 秒
    /// 相邻两个 sample buffer 的 pts 与按样本数推算的时间差超过这个，就当作不连续，重采样器重新起头（与 Android 相同）。
    private let DISCONTINUITY_US: Int64 = 100_000

    // 每次启动 / 停止都换一个代号；解码线程只在代号还是自己的那个时才继续跑。
    // 旧实现 stop() 后马上 startDecoding() 又把共享的 isDecoding 设回 true，seek 后旧线程不会退出。
    private let stateLock = NSLock()
    private var generation = 0

    init(asset: AVAsset, buffer: PcmCircularBuffer, positionProvider: @escaping () -> Int) {
        self.asset = asset
        self.pcmBuffer = buffer
        self.videoPositionProvider = positionProvider
    }

    /// 设置音频分析完成后的回调
    func setOnCompleteListener(_ listener: @escaping () -> Void) {
        self.onCompleteListener = listener
    }

    /// 外部请求 seek 到某个时间点（单位：ms）。
    /// 调用方（handleUserSeek）已做 0.5 秒防抖；这里不再丢弃 1 秒内的第二次 seek，否则解码位置会停在上一次 seek 处。
    func seekTo(_ ms: Int) {
        print("🔄 AudioDecoder.seekTo(", ms, ")")
        start(fromMs: max(ms, 0)) // 直接seek到当前位置，让限速机制自然控制播放量
    }

    /// 开始解码任务
    func startDecoding() {
        start(fromMs: nil)
    }

    /// 停止解码任务（正在跑的解码线程会在下一次检查时退出，包括正在限速等待的）
    func stop() {
        print("🛑 AudioDecoder: 请求停止解码线程")
        stateLock.lock()
        generation += 1
        stateLock.unlock()
    }

    private func start(fromMs: Int?) {
        stateLock.lock()
        generation += 1                         // 同时让旧线程退出
        let gen = generation
        stateLock.unlock()
        let thread = Thread { [self] in
            self.decodeLoop(generation: gen, startMs: fromMs)
        }
        thread.name = "AudioDecoder"
        thread.start()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == gen
    }

    /// 主解码逻辑
    private func decodeLoop(generation gen: Int, startMs: Int?) {
        let pipeline = AudioDecoder.pipeline
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            // 不写 AVSampleRateKey / AVNumberOfChannelsKey：保持源采样率和声道数，下混与重采样自己做
            // （系统下混的系数未必是 0.5，与训练用的 ffmpeg -ac 1 不一定一致）
        ]

        guard let track = asset.tracks(withMediaType: .audio).first else {
            print("❌ 未找到音频轨道")
            return
        }

        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput

        do {
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
            reader.add(output)

            if let seekMs = startMs {
                let time = CMTimeMake(value: Int64(seekMs), timescale: 1000)
                reader.timeRange = CMTimeRangeMake(start: time, duration: asset.duration)
                print("🔄 解码器 Seek 到: \(seekMs)ms")
            }

            reader.startReading()
        } catch {
            print("❌ 创建 AVAssetReader 失败: \(error)")
            return
        }
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }
        print("🎵 音频管线: \(pipeline == .fixed ? "fixed" : "legacy")")

        var lastPtsMs: Int64 = -1

        // fixed 管线的状态
        var resampler: PcmResampler? = nil
        var resamplerBaseUs: Int64 = 0
        var pcm: [Int16] = []

        // legacy 管线的状态
        var legacy = pipeline == .legacy ? LegacyChunker(track: track) : nil

        while isCurrent(gen), reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                print("❌ 无法获取下一个样本缓冲区")
                break
            }

            let ptsTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let pts = Int64(ptsTime.seconds * 1000)

            // 检查PTS是否倒退
            if lastPtsMs >= 0 && pts < lastPtsMs {
                print("⚠️ 解码输出帧 pts 倒退，当前: \(pts)ms, 上一帧: \(lastPtsMs)ms，跳过此帧")

                // 防止死循环
                if pts == 0 && pts < lastPtsMs {
                    print("🛑 视频播放结束")
                    break
                }
                continue
            }
            lastPtsMs = pts

            // 限速：超前播放位置 3 秒以上就等播放追上（等待中也检查是否已被停止 / seek 取代）
            var d = pts - Int64(videoPositionProvider())
            while d > MAX_ADVANCE_MS {
                if !isCurrent(gen) { return }
                Thread.sleep(forTimeInterval: 0.05)
                d = pts - Int64(videoPositionProvider())
            }

            if legacy != nil {
                for seg in legacy!.push(sampleBuffer, ptsMs: pts) where isCurrent(gen) {
                    pcmBuffer.write(seg.data, startTimestampMs: seg.startMs, sampleRate: seg.sampleRate)
                }
                continue
            }

            // ===== fixed 管线 =====
            // 采样率 / 声道数以这个 sample buffer 的实际格式为准（不用轨道的格式描述：HE-AAC 等情况下可能不一致）
            guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                print("❌ 无法获取音频格式或数据缓冲区")
                continue
            }
            let rate = Int(asbd.mSampleRate)
            let ch = Int(asbd.mChannelsPerFrame)
            guard rate > 0, ch > 0, asbd.mBitsPerChannel == 16,
                  asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0,
                  asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 else {
                print("❌ 意外的解码输出格式: \(asbd.mSampleRate)Hz \(asbd.mChannelsPerFrame)ch \(asbd.mBitsPerChannel)bit flags=\(asbd.mFormatFlags)")
                continue
            }

            let frames = min(CMSampleBufferGetNumSamples(sampleBuffer), CMBlockBufferGetDataLength(blockBuffer) / (2 * ch))
            guard frames > 0 else { continue }
            if pcm.count < frames * ch { pcm = [Int16](repeating: 0, count: frames * ch) }
            let status = pcm.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: frames * ch * 2, destination: ptr.baseAddress!)
            }
            if status != kCMBlockBufferNoErr {
                print("❌ 复制音频数据失败")
                continue
            }

            // 时间戳 = 起头 buffer 的 pts + 样本序号/16000；pts 与按样本数推算的不连续时重新起头
            let ptsUs = CMTimeConvertScale(ptsTime, timescale: 1_000_000, method: .roundTowardZero).value
            let expectUs = resampler.map { resamplerBaseUs + $0.inputFrames * 1_000_000 / Int64(rate) } ?? 0
            if resampler == nil || resampler!.inputRate != rate || resampler!.channelCount != ch
                || abs(ptsUs - expectUs) > DISCONTINUITY_US {
                resampler = PcmResampler(inputRate: rate, channelCount: ch)
                resamplerBaseUs = ptsUs
                print("[音频修复] 重采样器起头: \(rate)Hz \(ch)ch, pts=\(ptsUs / 1000)ms")
            }
            let r = resampler!
            let first = r.outputCount
            let out = r.process(pcm, offset: 0, frames: frames)
            if !out.isEmpty && isCurrent(gen) {
                // 产出总是 16 的整数倍，first/16 正好是整毫秒，块与块之间时间戳连续
                pcmBuffer.write(out, startTimestampMs: resamplerBaseUs / 1000 + first / 16,
                                sampleRate: PcmResampler.outRate)
            }
        }

        if isCurrent(gen) {
            print("✅ 解码结束，调用 onCompleteListener")
            onCompleteListener?()
        }
    }
}

// MARK: - 修复前的旧处理（AudioPipeline.legacy，仅供 A/B 对比，逻辑与修复前逐行相同，不要再改）

private struct LegacyChunker {
    private let sampleRate: Int         // 取自轨道 formatDescription（不看声道数）
    private let windowSize: Int         // 按 Int16 个数算：双声道时只有 1 秒真实音频
    private let targetSampleRate = 16000
    private let targetWindowSize = 32000
    private var buffer: [Float] = []
    private var segmentStartMs: Int64 = -1

    init(track: AVAssetTrack) {
        var rate = 48000
        if let formatDescriptions = track.formatDescriptions as? [CMFormatDescription],
           let formatDescription = formatDescriptions.first,
           let streamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
            rate = Int(streamBasicDescription.pointee.mSampleRate)
            print("🎵 音频采样率: \(rate) Hz")
        }
        sampleRate = rate
        windowSize = rate * 2
    }

    mutating func push(_ sampleBuffer: CMSampleBuffer, ptsMs pts: Int64) -> [(data: [Float], startMs: Int64, sampleRate: Int)] {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return [] }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let result = data.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }
        if result != kCMBlockBufferNoErr { return [] }
        let samples = data.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Int16.self).map { Float($0) / 32768.0 }
        }
        if buffer.isEmpty {
            segmentStartMs = pts
        }
        buffer.append(contentsOf: samples)
        guard buffer.count >= windowSize else { return [] }

        let segment = Array(buffer.prefix(windowSize))
        let segmentStartPts = segmentStartMs
        buffer.removeFirst(windowSize)
        segmentStartMs = -1
        if sampleRate != targetSampleRate {
            return [(legacyResample(input: segment, fromSampleRate: sampleRate, toSampleRate: targetSampleRate,
                                    targetSize: targetWindowSize), segmentStartPts, targetSampleRate)]
        }
        return [(segment, segmentStartPts, sampleRate)]
    }
}

private func legacyResample(input: [Float], fromSampleRate: Int, toSampleRate: Int, targetSize: Int) -> [Float] {
    var output = [Float](repeating: 0.0, count: targetSize)

    // 创建时间轴
    let originalTime = (0..<input.count).map { Float($0) / Float(fromSampleRate) }
    let targetTime = (0..<targetSize).map { Float($0) / Float(toSampleRate) }

    // 线性插值
    var j = 0
    for i in 0..<targetSize {
        while j < input.count - 1 && originalTime[j + 1] < targetTime[i] {
            j += 1
        }

        if j < input.count - 1 {
            let t1 = originalTime[j]
            let t2 = originalTime[j + 1]
            let v1 = input[j]
            let v2 = input[j + 1]
            let ratio = (targetTime[i] - t1) / (t2 - t1)
            output[i] = v1 + ratio * (v2 - v1)
        } else {
            output[i] = input[j]
        }
    }

    return output
}
