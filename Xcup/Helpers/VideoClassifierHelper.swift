//
//  VideoClassifierHelper.swift
//  Xcup
//
//  对应 Android Java: VideoClassifierHelper.java
//
//  MobileNetV3Small + Temporal Average Pooling + 3分类 视频动作识别器
//  模型文件：mobilenetv3small_tap_3class_float32.tflite
//
//  输入 [1, 12, 160, 160, 3] float32（NHWC，t→h→w→c）
//    - 原始像素值 0–255，不归一化（模型内含 Rescaling 层）
//    - RGB 顺序
//    - 每帧先经 FramePreprocessor 处理（居中裁正方形 → 224 → 160，与训练一致）
//  输出 [1, 3] softmax 概率
//    - 索引 0 = normal_plot
//    - 索引 1 = oral
//    - 索引 2 = sex
//

import Foundation
import CoreGraphics
import TensorFlowLite

final class VideoClassifierHelper {

    // MARK: - 模型常量
    static let TIME: Int = 12
    static let SIZE: Int = FramePreprocessor.modelSize   // 160（预处理见 FramePreprocessor）
    static let CHANNELS: Int = 3
    static let NUM_CLASSES: Int = 3

    private var interpreter: Interpreter?
    /// 输入张量的缓冲（12×160×160×3 个 Float），每次推理复用。predict 只在视频分析队列里调用
    private var inputBuffer = [Float](repeating: 0, count: TIME * SIZE * SIZE * CHANNELS)

    init() {
        do {
            guard let path = Bundle.main.path(
                forResource: "mobilenetv3small_tap_3class_float32",
                ofType: "tflite"
            ) else {
                print("❌ mobilenetv3small_tap_3class_float32.tflite 未找到")
                return
            }

            var options = Interpreter.Options()
            options.threadCount = 4

            interpreter = try Interpreter(modelPath: path, options: options)
            try interpreter?.allocateTensors()
            print("✅ VideoClassifier 加载成功（MobileNetV3Small + TAP + 3class）")
        } catch {
            print("❌ VideoClassifier 初始化失败: \(error)")
        }
    }

    /// 任意尺寸的画面 → 模型输入（160×160 ARGB）：按 FramePreprocessor 居中裁正方形、面积平均缩小，与训练一致。
    /// 在线模式（截屏）用它；离线模式在 VideoFrameExtractor 里已经处理好了。对应 Android 的 toModelBitmap()。
    ///
    /// 2026-10-15 之前是 resizeTo160：整张图直接画进 160×160（压扁），而且走 UIGraphicsImageRenderer / CGContext，
    /// 颜色还可能被转换（广色域屏幕上默认是扩展色彩空间）。
    ///
    /// - Parameter scratch: 可复用的像素缓冲（不够大时重新分配），避免每帧分配几 MB
    static func toModelInput(_ image: CGImage, scratch: inout [UInt32]) -> [UInt32]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        if scratch.count < w * h {
            scratch = [UInt32](repeating: 0, count: w * h)
        }
        // 32 位小端 + alpha 在前：内存里是 B,G,R,A，按 UInt32 读出来就是 0xAARRGGBB。不透明的图预乘不改变颜色。
        // 按 sRGB 画（截屏 JPEG 就是 sRGB），不做颜色转换
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let drawn: Bool = scratch.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space, bitmapInfo: bitmapInfo) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        return FramePreprocessor.toModelInput(scratch, w: w, h: h, region: FramePreprocessor.cropRect(w: w, h: h))
    }

    /// 12 帧 → 模型输入张量 [1, 12, 160, 160, 3]：t → h → w → c，R、G、B 顺序，0–255 原值（不除以 255、不减均值）。
    ///
    /// - Parameter frames: 12 帧 160×160 ARGB（FramePreprocessor 的输出），从旧到新
    /// - Returns: 帧数或尺寸不对时 false
    static func writeInput(_ frames: [[UInt32]], into buffer: inout [Float]) -> Bool {
        let perFrame = SIZE * SIZE
        guard frames.count == TIME, buffer.count >= TIME * perFrame * CHANNELS,
              frames.allSatisfy({ $0.count == perFrame }) else { return false }
        buffer.withUnsafeMutableBufferPointer { bb in
            let dst = bb.baseAddress!
            for (t, frame) in frames.enumerated() {
                frame.withUnsafeBufferPointer { fb in
                    let src = fb.baseAddress!
                    let o = dst + t * perFrame * CHANNELS
                    for i in 0..<perFrame {
                        let p = src[i]
                        o[i * 3] = Float((p &>> 16) & 0xFF)      // R
                        o[i * 3 + 1] = Float((p &>> 8) & 0xFF)   // G
                        o[i * 3 + 2] = Float(p & 0xFF)           // B
                    }
                }
            }
        }
        return true
    }

    /// 推理 12 帧 → 三分类
    /// - Parameter frames: 12 帧 160×160 ARGB（FramePreprocessor / VideoFrameExtractor 的输出），从旧到新
    /// - Returns: (argmax 索引, 最大概率, [normal_plot, oral, sex])
    func predict(frames: [[UInt32]]) -> (index: Int, confidence: Float, probs: [Float])? {
        guard let interpreter = interpreter else {
            print("❌ VideoClassifier 未初始化")
            return nil
        }
        guard Self.writeInput(frames, into: &inputBuffer) else {
            print("❌ 帧数或尺寸错误：期望 \(Self.TIME) 帧 \(Self.SIZE)x\(Self.SIZE)，实际 \(frames.count) 帧"
                  + (frames.first.map { "，第一帧 \($0.count) 个像素" } ?? ""))
            return nil
        }

        do {
            let data = inputBuffer.withUnsafeBufferPointer { Data(buffer: $0) }
            try interpreter.copy(data, toInputAt: 0)
            try interpreter.invoke()

            let outTensor = try interpreter.output(at: 0)
            let raw = outTensor.data.toArray(type: Float32.self)
            let probs = Array(raw.prefix(Self.NUM_CLASSES))

            var maxIdx = 0
            var maxP = probs[0]
            for i in 1..<probs.count {
                if probs[i] > maxP {
                    maxP = probs[i]
                    maxIdx = i
                }
            }
            return (maxIdx, maxP, probs)
        } catch {
            print("❌ VideoClassifier 推理失败: \(error)")
            return nil
        }
    }

    func close() {
        interpreter = nil
    }
}
