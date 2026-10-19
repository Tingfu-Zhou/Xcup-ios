//
//  ModelInputDumper.swift
//  Xcup
//
//  验收用，只在 Debug 包里编译：每隔几秒把送进视频模型的 160×160 存成 PNG，看画面对不对
//  （iOS 在线模式检查清单 6.2：应当是转正的、视频画面的居中正方形，没有黑边、没有压扁，与同一部片离线模式的输入看起来一样）。
//

#if DEBUG
import Foundation
import UIKit

/// 存到 App 的 Documents/model_inputs/<名字>/，文件名是 "时刻_说明.png"；只留最近 maxFiles 张，每次新建时清空这个目录。
///
/// 取图：Mac 上 Xcode → Window → Devices and Simulators → 选中手机 → Installed Apps 里的 Xcup → ⋯ →
/// Download Container…，在下载的 .xcappdata 上右键"显示包内容"，在 AppData/Documents/model_inputs/ 下。
///
/// 只在一条队列上用（各页面的视频分析队列），不加锁。
final class ModelInputDumper {

    private let dir: URL?
    private let intervalMs: Int64
    private let maxFiles: Int
    private var lastMs: Int64?
    private var written: [URL] = []
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmmss.SSS"
        return f
    }()

    init(name: String, intervalMs: Int64 = 3000, maxFiles: Int = 200) {
        self.intervalMs = intervalMs
        self.maxFiles = maxFiles
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("model_inputs", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        if let d {
            try? FileManager.default.removeItem(at: d)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            print("[验收] 送进视频模型的画面每 \(intervalMs)ms 存一张到 \(d.path)")
        }
        dir = d
    }

    /// 距上一张满 intervalMs、或 force（画面的位置刚变）时存一张。
    ///
    /// - Parameter pixels: 160×160 ARGB（FramePreprocessor 的输出，送进模型的就是它）
    func dumpIfDue(_ pixels: [UInt32], note: String, force: Bool = false) {
        let now = monotonicMs()
        guard let dir else { return }
        if !force, let last = lastMs, now - last < intervalMs { return }
        lastMs = now
        guard let png = Self.png(pixels, side: FramePreprocessor.modelSize) else { return }
        let url = dir.appendingPathComponent("\(stamp.string(from: Date()))_\(note).png")
        do {
            try png.write(to: url)
        } catch {
            print("[验收] 存图失败：\(error)")
            return
        }
        written.append(url)
        if written.count > maxFiles {
            try? FileManager.default.removeItem(at: written.removeFirst())
        }
    }

    /// side×side 的 ARGB（0xAARRGGBB）→ PNG。
    static func png(_ argb: [UInt32], side: Int) -> Data? {
        guard argb.count == side * side, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var px = argb
        // 与 VideoClassifierHelper.drawPixels 同一种排布：32 位小端 + alpha 在前，内存里是 B,G,R,A
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        // 在缓冲区还在的时候就编码好（makeImage 可能不立即拷贝像素）
        return px.withUnsafeMutableBytes { raw -> Data? in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space, bitmapInfo: bitmapInfo),
                  let image = ctx.makeImage() else { return nil }
            return UIImage(cgImage: image).pngData()
        }
    }
}
#endif
