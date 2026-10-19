//
//  BroadcastSampleHandler.swift
//  XcupBroadcast  ← 仅属于 Broadcast Upload Extension target
//
//  自包含版本：所有写端代码（AudioRingWriter、VideoFrameWriter、常量）直接内嵌，
//  不依赖任何外部共享文件，彻底避免跨 target 编译问题。
//

import ReplayKit
import AVFoundation
import CoreMedia
import CoreImage
import ImageIO
import AudioToolbox
import UIKit
import Foundation
import Darwin

// MARK: - 常量（与主 App 端 BroadcastBridge.swift 保持一致）

private let kAppGroupID    = "group.com.aibei.Xcup"
private let kAudioFile     = "xcup_audio_ring.bin"
private let kVideoFile     = "xcup_video_frame.bin"   // 帧头 + JPEG，见 VideoWriter
private let kNotifyAudio    = "com.aibei.xcup.audio"           as CFString
private let kNotifyVideo    = "com.aibei.xcup.video"           as CFString
private let kNotifyStop     = "com.aibei.xcup.stop"            as CFString
private let kNotifyStart    = "com.aibei.xcup.broadcastStart"  as CFString
private let kNotifyAudioRaw = "com.aibei.xcup.audioRaw"        as CFString   // 诊断：audioApp 原始到达

// 诊断 key（写入 App Groups UserDefaults，绕过 <private> 日志限制）
private let kDiagAudioFmt   = "xcup_diag_audio_fmt"    // 扩展收到的音频格式
private let kDiagAudioConv  = "xcup_diag_audio_conv"   // 转换结果
private let kDiagAudioRaw   = "xcup_diag_audio_raw"    // 是否收到 .audioApp
private let kDiagVideoFmt   = "xcup_diag_video_fmt"    // 扩展收到的画面：尺寸、像素格式、方向、颜色标注

// MARK: - 环形缓冲布局

private enum Ring {
    static let sampleRate  = 16000
    static let capacity    = sampleRate * 20          // 20 秒
    static let headerBytes = 16
    static let dataBytes   = capacity * MemoryLayout<Float>.size
    static let fileBytes   = headerBytes + dataBytes  // ≈ 1.22 MB
}

// MARK: - 音频写端

private final class AudioWriter {
    private var fd: Int32 = -1
    private var base: UnsafeMutableRawPointer?
    private var cursor: Int = 0
    private var seq: UInt32 = 0

    init?() {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: kAppGroupID)?
            .appendingPathComponent(kAudioFile) else {
            print("[XcupBroadcast] ⚠️ AudioWriter: App Groups 容器路径获取失败")
            return nil
        }

        // 用 O_CREAT|O_RDWR 直接创建或打开，避免在扩展进程内存中分配 1.22MB Data 对象
        fd = open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP)
        guard fd >= 0 else {
            print("[XcupBroadcast] ⚠️ AudioWriter: open 失败 errno=\(errno)")
            return nil
        }

        // ftruncate 将文件扩展到所需大小（不占用扩展进程的大块内存）
        guard ftruncate(fd, off_t(Ring.fileBytes)) == 0 else {
            print("[XcupBroadcast] ⚠️ AudioWriter: ftruncate 失败 errno=\(errno)")
            close(fd); fd = -1; return nil
        }

        base = mmap(nil, Ring.fileBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        if base == MAP_FAILED {
            print("[XcupBroadcast] ⚠️ AudioWriter: mmap 失败 errno=\(errno)")
            base = nil; close(fd); fd = -1; return nil
        }

        store(UInt32(0), at: 0); store(UInt32(0), at: 4)
        store(UInt32(Ring.sampleRate), at: 8); store(UInt32(0), at: 12)
        print("[XcupBroadcast] ✅ AudioWriter: 初始化成功，文件=\(url.lastPathComponent)")
    }

    deinit {
        if let b = base { munmap(b, Ring.fileBytes) }
        if fd >= 0 { close(fd) }
    }

    func write(_ samples: [Float]) {
        guard let b = base, !samples.isEmpty else { return }
        let data = b.advanced(by: Ring.headerBytes).assumingMemoryBound(to: Float.self)
        let cap = Ring.capacity
        for s in samples { data[cursor % cap] = s; cursor += 1 }
        seq &+= 1
        store(UInt32(cursor % cap), at: 0)
        store(seq, at: 4)
        notify(kNotifyAudio)
    }

    private func store(_ v: UInt32, at offset: Int) {
        base!.storeBytes(of: v, toByteOffset: offset, as: UInt32.self)
    }
}

// MARK: - 视频写端
//
// 一帧一个文件、一次原子写入：32 字节的帧头（小端）+ JPEG。方向和画面在同一个文件里，主 App 读到的方向一定是这一帧的
// （主 App 靠它发现转屏，包括尺寸不变的 180° 翻转）。布局与主 App 端 BroadcastBridge.swift 的 VideoFrameFile 一致：
//   0   UInt32  magic "XCV1"
//   4   UInt32  RPVideoSampleOrientationKey 的原值（CGImagePropertyOrientation 1…8；没有这个附件时 0）
//   8   Int64   时间戳（Unix 毫秒）
//   16  UInt32  ReplayKit 原始画面的宽
//   20  UInt32  原始画面的高
//   24  UInt32  原始画面的像素格式（FourCC，如 '420f'）
//   28  UInt32  保留（0）
//   32  JPEG：已转正、短边缩到 480

private enum VideoFrameFile {
    static let magic: UInt32 = 0x3156_4358     // 按小端写出来是 "XCV1"
    static let headerBytes = 32
}

private final class VideoWriter {
    private let url: URL?

    init() {
        url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: kAppGroupID)?
            .appendingPathComponent(kVideoFile)
    }

    func write(jpeg: Data, timestampMs: Int64, orientation: UInt32,
               sourceWidth: Int, sourceHeight: Int, pixelFormat: OSType) {
        guard let u = url else { return }
        var data = Data(capacity: VideoFrameFile.headerBytes + jpeg.count)
        appendLE(&data, VideoFrameFile.magic)
        appendLE(&data, orientation)
        appendLE(&data, timestampMs)
        appendLE(&data, UInt32(clamping: sourceWidth))
        appendLE(&data, UInt32(clamping: sourceHeight))
        appendLE(&data, pixelFormat)
        appendLE(&data, UInt32(0))
        data.append(jpeg)
        try? data.write(to: u, options: .atomic)
        notify(kNotifyVideo)
    }

    private func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}

/// FourCC（如 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange = '420f'）→ 字符串，诊断用。
private func fourCC(_ v: OSType) -> String {
    let bytes = [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
                 UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    return bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) ? String(decoding: bytes, as: UTF8.self)
                                                         : "0x" + String(v, radix: 16)
}

// MARK: - Darwin 通知工具

private func notify(_ name: CFString) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(name), nil, nil, true)
}

// MARK: - BroadcastSampleHandler

// MARK: - 共享诊断工具（绕过 <private> 日志限制）

private func writeDiag(_ value: String, forKey key: String) {
    UserDefaults(suiteName: kAppGroupID)?.set(value, forKey: key)
}

// MARK: - BroadcastSampleHandler

class BroadcastSampleHandler: RPBroadcastSampleHandler {

    private var audioWriter: AudioWriter?
    private let videoWriter = VideoWriter()

    private var lastVideoTime: TimeInterval = 0
    private let VIDEO_INTERVAL: TimeInterval = 0.2
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var lastVideoFormat = ""     // 上一次记下的画面格式（noteVideoFormat）

    // 诊断：记录首条音频样本（.audioApp 或 .audioMic），只发一次通知
    private var audioRawDiagSent = false

    // App 音频优先（与 Android 在线模式的 AudioPlaybackCapture 一样抓的是播放的声音）；
    // 麦克风录的是房间里的声音，只在超过 MIC_FALLBACK_SEC 没收到 App 音频时兜底
    private var lastAppAudioUptime: TimeInterval = -.infinity
    private let MIC_FALLBACK_SEC: TimeInterval = 1.0

    // ReplayKit 可能在不同线程回调 App 音频和麦克风：下面这些音频状态和环形缓冲写端统一在 audioLock 里串行处理
    private let audioLock = NSLock()

    // 流式重采样（与离线模式同一个 PcmResampler）：同一来源、同一格式、时间连续时跨块沿用，不丢样本、不重置相位
    private var resampler: PcmResampler?
    private var resamplerKey = ""
    private var resamplerBaseUs: Int64 = 0
    /// 相邻音频块的 pts 与按样本数推算的时间差超过这个，就当作不连续，重采样器重新起头。
    private let DISCONTINUITY_US: Int64 = 100_000

    // MARK: - 广播生命周期

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        audioLock.lock()
        audioWriter = AudioWriter()
        audioRawDiagSent = false
        lastAppAudioUptime = -.infinity
        resampler = nil
        resamplerKey = ""
        audioLock.unlock()
        if audioWriter == nil {
            print("[XcupBroadcast] ⚠️ AudioWriter 初始化失败，请检查 App Groups 配置")
        }
        notify(kNotifyStart)
        print("[XcupBroadcast] 广播已启动，AudioWriter=\(audioWriter != nil ? "OK" : "nil")")
    }

    override func broadcastFinished() {
        notify(kNotifyStop)
        print("[XcupBroadcast] 广播已结束")
    }

    override func broadcastPaused()  { print("[XcupBroadcast] 广播暂停") }
    override func broadcastResumed() { print("[XcupBroadcast] 广播恢复") }

    // MARK: - 采样缓冲处理

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with type: RPSampleBufferType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .audioApp:
            // App 音频（播放的声音，与 Android AudioPlaybackCapture 等价）：优先使用
            audioLock.lock(); defer { audioLock.unlock() }
            lastAppAudioUptime = ProcessInfo.processInfo.systemUptime
            if !audioRawDiagSent {
                audioRawDiagSent = true
                writeDiag("YES(app)", forKey: kDiagAudioRaw)
                notify(kNotifyAudioRaw)
            }
            processAudio(sampleBuffer, source: "app")
        case .audioMic:
            // 麦克风：只在一段时间没有 App 音频时兜底，避免两路叠加
            audioLock.lock(); defer { audioLock.unlock() }
            guard ProcessInfo.processInfo.systemUptime - lastAppAudioUptime > MIC_FALLBACK_SEC else { return }
            if !audioRawDiagSent {
                audioRawDiagSent = true
                writeDiag("YES(mic)", forKey: kDiagAudioRaw)
                notify(kNotifyAudioRaw)
            }
            processAudio(sampleBuffer, source: "mic")
        case .video:
            processVideo(sampleBuffer)
        default:
            break
        }
    }

    // MARK: - 音频处理：取原始 PCM（按 ASBD 处理字节序 / 交错）→ PcmResampler 下混 + 抗混叠重采样到 16kHz → 共享环形缓冲

    private func processAudio(_ sampleBuffer: CMSampleBuffer, source: String) {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
            writeDiag("E1:fmtDesc_nil", forKey: kDiagAudioConv); return
        }
        let asbd      = asbdPtr.pointee
        let srcRate   = Int(asbd.mSampleRate)
        let srcCh     = Int(asbd.mChannelsPerFrame)
        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard srcRate > 0, srcCh > 0, numFrames > 0 else {
            writeDiag("E2:rate=\(srcRate) ch=\(srcCh) frames=\(numFrames)", forKey: kDiagAudioConv); return
        }

        let format = ReplayKitPcmFormat(
            channels: srcCh,
            bitsPerChannel: asbd.mBitsPerChannel == 0 ? 16 : Int(asbd.mBitsPerChannel),   // 0 按 16 位处理（与旧代码相同）
            isFloat: (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
            isBigEndian: (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0,
            isNonInterleaved: (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0)
        writeDiag("\(source) \(srcRate)Hz \(srcCh)ch \(format.bitsPerChannel)bit float=\(format.isFloat) "
                  + "nonI=\(format.isNonInterleaved) bigEndian=\(format.isBigEndian) "
                  + "flags=0x\(String(asbd.mFormatFlags, radix: 16))", forKey: kDiagAudioFmt)

        // ── 1. 两步法获取 ABL：先查询所需大小，再分配并填充（避免 kCMSampleBufferError_ArrayTooSmall）──
        var ablSizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &ablSizeNeeded,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil)
        guard ablSizeNeeded > 0 else {
            writeDiag("E3a:ablSize=0", forKey: kDiagAudioConv); return
        }

        let rawAbl = UnsafeMutableRawPointer.allocate(byteCount: ablSizeNeeded, alignment: 16)
        defer { rawAbl.deallocate() }
        let ablListPtr = rawAbl.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuf: CMBlockBuffer?
        let ablStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: ablListPtr, bufferListSize: ablSizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &blockBuf)
        guard ablStatus == noErr else {
            writeDiag("E3:abl=\(ablStatus)", forKey: kDiagAudioConv); return
        }

        // ── 2. 取原始 PCM：Int16 保持交错 Int16（转成本机字节序），其他格式下混成单声道 Float ──
        let buffers = UnsafeMutableAudioBufferListPointer(ablListPtr).map {
            UnsafeRawBufferPointer(start: UnsafeRawPointer($0.mData), count: $0.mData == nil ? 0 : Int($0.mDataByteSize))
        }
        guard let pcm = ReplayKitPcm.convert(format: format, buffers: buffers, frames: numFrames) else {
            writeDiag("E4:unsupported \(format.bitsPerChannel)bit float=\(format.isFloat) "
                      + "nonI=\(format.isNonInterleaved) buffers=\(buffers.count)", forKey: kDiagAudioConv)
            return
        }

        // ── 3. 流式重采样到 16 kHz：来源 / 格式变了、或时间不连续时重新起头 ──
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsUs: Int64? = pts.isValid
            ? CMTimeConvertScale(pts, timescale: 1_000_000, method: .roundTowardZero).value : nil
        let key = "\(source) \(srcRate) \(pcm.channels)"
        var restart = resampler == nil || key != resamplerKey
        if !restart, let us = ptsUs, let r = resampler {
            let expectUs = resamplerBaseUs + r.inputFrames * 1_000_000 / Int64(srcRate)
            if abs(us - expectUs) > DISCONTINUITY_US { restart = true }
        }
        if restart {
            resampler = PcmResampler(inputRate: srcRate, channelCount: pcm.channels)
            resamplerKey = key
            resamplerBaseUs = ptsUs ?? 0
        }
        let output: [Float]
        switch pcm {
        case .int16(let samples, _): output = resampler!.process(samples, frames: numFrames)
        case .mono(let samples):     output = resampler!.process(mono: samples)
        }

        guard !output.isEmpty else { return }   // 不足 16 个输出样本时先攒着，下一块一起出
        writeDiag("OK \(source) \(srcRate)→16k len=\(output.count)", forKey: kDiagAudioConv)
        audioWriter?.write(output)
    }

    // MARK: - 视频处理（转正 → 等比缩小 → JPEG → 共享文件，帧头带方向）

    private func processVideo(_ sampleBuffer: CMSampleBuffer) {
        let now = Date().timeIntervalSince1970
        guard now - lastVideoTime >= VIDEO_INTERVAL else { return }
        lastVideoTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // ReplayKit 给的缓冲区总是设备竖着时的方向：横屏全屏看视频时，画面是横躺在里面的，方向写在
        // RPVideoSampleOrientationKey（CGImagePropertyOrientation）里。先转正，主 App 的预览和送进视频模型的都是正的画面
        // （模型只见过正的画面；主 App 再去掉视频四周的黑边、取视频画面的居中正方形，见 ScreenCropper、FramePreprocessor）。
        // 方向的原值随帧传给主 App：方向变了（转屏）主 App 清空 12 帧窗口
        let rawOrientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                              attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 0
        if let orientation = CGImagePropertyOrientation(rawValue: rawOrientation), orientation != .up {
            ciImage = ciImage.oriented(uprightOrientation(fromReplayKit: orientation))
        }

        // 短边缩到 480（原来按宽缩到 480：转正后的横屏画面宽是长边，短边只剩约 220，比模型要的 224 还小）。
        // 等比缩小；YUV → RGB 由 Core Image 按像素格式（420f 全范围 / 420v 视频范围）和缓冲区标注的矩阵做
        let scale = 480.0 / min(ciImage.extent.width, ciImage.extent.height)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        // JPEG 质量 0.9（原来 0.6）：贴着视频的那几个 JPEG 块有压缩振铃，黑边里冒出 >16 的像素，主 App 去黑边时找到的
        // 范围就比视频大几行，送进模型的正方形里带上一点黑边。按 libjpeg 的质量在电脑上模拟（Apple 的刻度不完全一样）：
        // 竖屏全屏时质量 60 带上约 4%（最坏 11%），90 约 1.5%（最坏 3%）。文件大约大一倍
        guard let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9) else { return }

        noteVideoFormat(sampleBuffer, pixelBuffer, rawOrientation: rawOrientation,
                        uprightWidth: cgImage.width, uprightHeight: cgImage.height)
        videoWriter.write(jpeg: jpeg, timestampMs: Int64(now * 1000), orientation: rawOrientation,
                          sourceWidth: CVPixelBufferGetWidth(pixelBuffer),
                          sourceHeight: CVPixelBufferGetHeight(pixelBuffer),
                          pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer))
    }

    /// 画面的格式（原始尺寸、像素格式、方向、颜色标注）变了就记一次：print 一行，并写进 App Group 的诊断项（主 App 在截屏
    /// 布局变了时一并打出来）。用来在真机上确认 ReplayKit 给的是什么。
    private func noteVideoFormat(_ sampleBuffer: CMSampleBuffer, _ pixelBuffer: CVPixelBuffer, rawOrientation: UInt32,
                                 uprightWidth: Int, uprightHeight: Int) {
        let desc = CMSampleBufferGetFormatDescription(sampleBuffer)
        func ext(_ key: CFString) -> String {
            guard let d = desc, let v = CMFormatDescriptionGetExtension(d, extensionKey: key) else { return "-" }
            return (v as? String) ?? "\(v)"
        }
        let text = "\(fourCC(CVPixelBufferGetPixelFormatType(pixelBuffer))) "
            + "\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) 方向=\(rawOrientation) "
            + "矩阵=\(ext(kCMFormatDescriptionExtension_YCbCrMatrix)) "
            + "原色=\(ext(kCMFormatDescriptionExtension_ColorPrimaries)) "
            + "传递函数=\(ext(kCMFormatDescriptionExtension_TransferFunction)) "
            + "→ 转正缩小后 \(uprightWidth)x\(uprightHeight)"
        guard text != lastVideoFormat else { return }
        lastVideoFormat = text
        print("[XcupBroadcast] 画面：\(text)")
        writeDiag(text, forKey: kDiagVideoFmt)
    }

    /// RPVideoSampleOrientationKey 的值在两个 90° 方向上与 EXIF 的含义相反（CIImage.oriented 按 EXIF 转）：
    /// 真机横屏时直接拿原值去转，画面上下颠倒（右上角的"返回主页面"跑到了左下角）。left / right 互换；
    /// 0°、180° 两种说法一样，原样用
    private func uprightOrientation(fromReplayKit o: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
        switch o {
        case .left:  return .right
        case .right: return .left
        default:     return o
        }
    }
}
