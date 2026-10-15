//
//  VideoFrameExtractor.swift
//  Xcup
//
//  Created by tingfu on 2025/4/20.
//
//  对应 Android VideoFrameExtractor.java + EGLRenderer.java（Android 2026-10-14 重写，iOS 2026-10-15 重写）。
//

import Foundation
import AVFoundation
import CoreVideo
import Accelerate
import QuartzCore

/// 离线模式的抽帧器：取播放器**此刻正在显示的那一帧**，已经按 FramePreprocessor 处理成模型输入（160×160 ARGB）。
///
/// **2026-10-15 之前的问题**（与 Android 2026-10-14 修掉的"只取到关键帧"是同一个问题）：用 AVAssetImageGenerator 按播放位置
/// 取帧，requestedTimeToleranceBefore / After 都是 .positiveInfinity，拿到的其实是离播放位置最近的关键帧（可能在前也可能在后，
/// 最多差半个关键帧间隔）。关键帧间隔 4~12 秒的片子，12 帧窗口里只有 1~2 张不同的图（同一张关键帧还会被重复放进窗口），
/// 视频结果每个关键帧间隔才变一次；融合仲裁按"新结果个数"计证据，同一张关键帧的十几个结果被当成了独立证据。
/// 另外 maximumSize = 160×160 先把 16:9 的画面缩成 160×90，再被拉伸成 160×160（与训练不一致，见 FramePreprocessor）。
///
/// **现在的做法**：
/// - 给 playerItem 挂一个 AVPlayerItemVideoOutput，按当前宿主时刻取这一刻该显示的帧，与 AVPlayerLayer 显示的是同一帧
///   （相当于 Android 网页模式截 TextureView）。帧时刻用 itemTimeForDisplay（这一帧的 pts），与请求时刻最多差一帧。
///   解码由播放器完成，不用自己 seek、追赶，所以也没有 Android 旧版"解码器里积压着前几次请求的帧、晚 0.5~1.3 秒"的问题。
/// - 没有新帧（暂停、卡顿、seek 后还没解出来）时返回 nil，调用方就不往窗口里放：窗口应当是 12 个不同时刻。
/// - 输出格式只指定 32BGRA、不指定宽高（让 AVFoundation 缩放就不知道用了什么滤波），拿原尺寸自己处理：
///   居中裁正方形 → vImage（Lanczos，抗混叠）缩到 672×672（= 3×224，对应 Android 在 GPU 上画成 672×672 那一步）
///   → FramePreprocessor 面积平均缩到 224 → 160 → 按 preferredTransform 转正。
///   YUV → RGB 由 AVFoundation 按片源标注的矩阵和范围做（高清片一般是 BT.709，与 Android 相同）。
///
/// **线程**：init 在主线程、play() 之前调用（output 要先挂上）；frameNow() 只在视频分析队列里调用（暂存缓冲区不加锁）。
/// 视频分析队列是串行队列，seek 时清空帧窗口也在这条队列上，所以不会有"seek 之前取的帧、seek 之后才放进窗口"的情况
/// （Android 抽帧在单独的线程、异步送回视频线程，才需要按 seek 编号作废在途的帧）。
final class VideoFrameExtractor {

    /// 一次取帧的结果。
    struct Frame {
        /// 模型输入：160×160 ARGB（0xAARRGGBB），已居中裁剪、缩小、转正
        let pixels: [UInt32]
        /// 这一帧的显示时刻（pts，毫秒）
        let ptsMs: Int64
        /// 取帧时的播放位置（毫秒）。正常情况下与 ptsMs 相差不超过一帧（30fps 约 33ms）
        let requestMs: Int64
    }

    /// 居中的正方形先用 vImage 缩到这个边长（3×224），再交给 FramePreprocessor（672 → 224 是整 3 倍，走整块求和）。
    static let stageSize = 672

    /// 管线名，与 Android 评测 CSV 参数行 VIDEO_PIPE 同一写法（抽帧_预处理；exact = 取的是这一刻的帧）。
    static var pipelineName: String { "exact_" + FramePreprocessor.geometryName }

    private let output: AVPlayerItemVideoOutput
    private let orientation: FramePreprocessor.Orientation
    /// vImage 输出的暂存图。内存里是 B,G,R,A，iOS 是小端，按 UInt32 读出来就是 0xAARRGGBB
    private let stage: UnsafeMutablePointer<UInt32>
    private var loggedSize = false
    private var loggedError = false

    /// 给 playerItem 挂上 AVPlayerItemVideoOutput。没有视频轨道时返回 nil。
    init?(playerItem: AVPlayerItem) {
        guard let track = playerItem.asset.tracks(withMediaType: .video).first else {
            print("❌ [抽帧] 没有视频轨道")
            return nil
        }
        // 竖拍的片子编码时是横着的，AVPlayerItemVideoOutput 给的像素也是横着的，要按 preferredTransform 转正
        let t = track.preferredTransform
        orientation = FramePreprocessor.Orientation(snapping: Double(t.a), Double(t.b), Double(t.c), Double(t.d))
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        playerItem.add(output)
        let n = Self.stageSize * Self.stageSize
        stage = .allocate(capacity: n)
        stage.initialize(repeating: 0, count: n)
        print("[抽帧] 已挂上 AVPlayerItemVideoOutput，VIDEO_PIPE=\(Self.pipelineName)，转正 (a,b,c,d)="
              + "(\(orientation.a),\(orientation.b),\(orientation.c),\(orientation.d))")
    }

    deinit {
        stage.deallocate()
    }

    /// 取此刻正在显示的那一帧。没有新帧（暂停、卡顿、seek 后还没解出来、这一帧已经取过）或出错时返回 nil。
    func frameNow() -> Frame? {
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard itemTime.isNumeric, output.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        var shown = CMTime.invalid
        guard let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &shown),
              let pixels = process(pb) else { return nil }
        let requestMs = Self.ms(itemTime)
        return Frame(pixels: pixels, ptsMs: shown.isNumeric ? Self.ms(shown) : requestMs, requestMs: requestMs)
    }

    /// BGRA 原图 → 居中正方形 → 672×672（vImage）→ 160×160（FramePreprocessor）→ 转正。
    private func process(_ pb: CVPixelBuffer) -> [UInt32]? {
        let format = CVPixelBufferGetPixelFormatType(pb)
        guard format == kCVPixelFormatType_32BGRA else {
            logError("像素格式不是 32BGRA：\(format)")
            return nil
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            logError("取不到像素地址")
            return nil
        }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard w > 0, h > 0 else { return nil }
        let r = FramePreprocessor.cropRect(w: w, h: h)
        if !loggedSize {
            loggedSize = true
            print("[抽帧] 解码帧 \(w)x\(h)，送进模型的区域 x0=\(r.x0) y0=\(r.y0) \(r.w)x\(r.h)"
                  + (FramePreprocessor.centerCrop ? "（居中正方形）" : "（整帧压扁）"))
        }

        var src = vImage_Buffer(data: base.advanced(by: r.y0 * rowBytes + r.x0 * 4),
                                height: vImagePixelCount(r.h), width: vImagePixelCount(r.w), rowBytes: rowBytes)
        var dst = vImage_Buffer(data: UnsafeMutableRawPointer(stage),
                                height: vImagePixelCount(Self.stageSize), width: vImagePixelCount(Self.stageSize),
                                rowBytes: Self.stageSize * 4)
        let err = vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else {
            logError("vImageScale_ARGB8888 失败：\(err)")
            return nil
        }
        let px = FramePreprocessor.toModelInput(UnsafePointer(stage), stride: Self.stageSize,
                                                w: Self.stageSize, h: Self.stageSize, region: nil)
        return orientation.apply(px, side: FramePreprocessor.modelSize)
    }

    private func logError(_ msg: String) {
        if loggedError { return }                // 每 250ms 都会走到，只打一次
        loggedError = true
        print("❌ [抽帧] \(msg)")
    }

    private static func ms(_ t: CMTime) -> Int64 {
        Int64((CMTimeGetSeconds(t) * 1000).rounded())
    }
}
