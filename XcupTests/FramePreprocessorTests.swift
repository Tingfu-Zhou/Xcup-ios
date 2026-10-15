//
//  FramePreprocessorTests.swift
//  XcupTests
//
//  对应 Android FramePreprocessorTest.java。最重要的是 matchesAndroidGolden：Android、iOS、bench/tools/video_rescore.py
//  三端用同一份 preprocess_golden.txt（python3 bench/tools/video_rescore.py golden 生成，取自 Android
//  app/src/test/resources/video/），保证两端喂给视频模型的画面逐像素一致，离线重算的结果能代表手机。
//  Android 改了 FramePreprocessor 会重新生成这个文件，换上新文件再跑一遍即可。
//

import Foundation
import Testing
@testable import Xcup

private final class BundleToken {}

struct FramePreprocessorTests {

    /// 第一处不一致就停下，报出 case、坐标和期望值。
    struct Mismatch: Error, CustomStringConvertible {
        let description: String
    }

    /// 与 video_rescore.golden_image / Java goldenImage 相同的确定性测试图（ARGB）。
    /// pattern：r=(x*7+y*3)&255, g=(x*x+y)&255, b=((x^y)*5)&255；noise：64 位 LCG，取最高字节，每个像素依次取 R、G、B。
    static func goldenImage(w: Int, h: Int, pattern: String, seed: UInt64) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: w * h)
        var s = seed
        for y in 0..<h {
            for x in 0..<w {
                let r, g, b: UInt32
                if pattern == "pattern" {
                    r = UInt32((x * 7 + y * 3) & 255)
                    g = UInt32((x * x + y) & 255)
                    b = UInt32(((x ^ y) * 5) & 255)
                } else {
                    s = s &* 6364136223846793005 &+ 1442695040888963407
                    r = UInt32(s >> 56)
                    s = s &* 6364136223846793005 &+ 1442695040888963407
                    g = UInt32(s >> 56)
                    s = s &* 6364136223846793005 &+ 1442695040888963407
                    b = UInt32(s >> 56)
                }
                out[y * w + x] = 0xFF00_0000 | (r << 16) | (g << 8) | b
            }
        }
        return out
    }

    static func goldenURL() -> URL? {
        if let url = Bundle(for: BundleToken.self).url(forResource: "preprocess_golden", withExtension: "txt") {
            return url
        }
        let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("preprocess_golden.txt")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    static func hex6(_ p: UInt32) -> String {
        String(format: "%06x", p & 0xFF_FFFF)
    }

    /// 每个 case：`case <种类> <图案> <种子> <w> <h> <x0> <y0> <cw> <ch> <dw> <dh>`，后面 dh 行期望输出，每个像素 RRGGBB。
    /// resize 种类调 resize(src, stride=w, x0, y0, cw, ch, dw, dh)；model 种类调 toModelInput（区域是整张图时传 nil）。
    @Test func matchesAndroidGolden() throws {
        let url = try #require(Self.goldenURL(),
                               "缺少测试资源 preprocess_golden.txt（Android 仓库 python3 bench/tools/video_rescore.py golden 生成）")
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines: [String] = text.split(whereSeparator: \.isNewline).map(String.init)
        lines.append("case end")                          // 哨兵：触发最后一个 case 的校验
        var head: [String]? = nil
        var rows: [String] = []
        var cases = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("case") {
                if let h = head {
                    try Self.check(h, rows)
                    cases += 1
                }
                head = line.split(whereSeparator: { (c: Character) in c == " " || c == "\t" }).map(String.init)
                rows.removeAll()
                continue
            }
            rows.append(line)
        }
        #expect(cases >= 8, "对拍数据里的 case 太少：\(cases)")
    }

    private static func check(_ f: [String], _ rows: [String]) throws {
        try #require(f.count >= 12, "case 行格式不对：\(f.joined(separator: " "))")
        let kind = f[1], pattern = f[2]
        let seed = try #require(UInt64(f[3]), "种子：\(f[3])")
        var v: [Int] = []
        for s in f[4...11] {
            v.append(try #require(Int(s), "case 行：\(s)"))
        }
        let (w, h, x0, y0, cw, ch, dw, dh) = (v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7])
        let tag = "\(kind) \(w)x\(h)->\(dw)x\(dh)"
        let img = goldenImage(w: w, h: h, pattern: pattern, seed: seed)
        let got: [UInt32]
        if kind == "model" {
            let whole = x0 == 0 && y0 == 0 && cw == w && ch == h
            got = FramePreprocessor.toModelInput(img, w: w, h: h,
                                                 region: whole ? nil : FramePreprocessor.Region(x0: x0, y0: y0, w: cw, h: ch))
        } else {
            got = FramePreprocessor.resize(img, stride: w, x0: x0, y0: y0, cw: cw, ch: ch, dw: dw, dh: dh)
        }
        try #require(rows.count == dh, "\(tag) 行数：期望 \(dh)，实际 \(rows.count)")
        try #require(got.count == dw * dh, "\(tag) 像素数：期望 \(dw * dh)，实际 \(got.count)")
        for y in 0..<dh {
            let row = Array(rows[y].utf8)
            try #require(row.count == dw * 6, "\(tag) 第 \(y) 行长度：\(row.count)")
            for x in 0..<dw {
                let hex = String(decoding: row[(x * 6)..<(x * 6 + 6)], as: UTF8.self)
                let want = 0xFF00_0000 | (try #require(UInt32(hex, radix: 16), "\(tag) (\(x),\(y))：\(hex)"))
                let g = got[y * dw + x]
                if want != g {
                    throw Mismatch(description: "\(tag) (\(x),\(y))：期望 \(hex6(want))，实际 \(hex6(g))")
                }
            }
        }
    }

    @Test func centerCropMatchesFfmpegCrop() {
        // ffmpeg scale=224:224:force_original_aspect_ratio=increase,crop=224:224 取的就是居中的正方形
        typealias R = FramePreprocessor.Region
        #expect(FramePreprocessor.cropRect(w: 1920, h: 1080) == R(x0: 420, y0: 0, w: 1080, h: 1080))
        #expect(FramePreprocessor.cropRect(w: 1280, h: 720) == R(x0: 280, y0: 0, w: 720, h: 720))
        #expect(FramePreprocessor.cropRect(w: 1080, h: 1920) == R(x0: 0, y0: 420, w: 1080, h: 1080))
        #expect(FramePreprocessor.cropRect(w: 640, h: 640) == R(x0: 0, y0: 0, w: 640, h: 640))
        #expect(FramePreprocessor.centerCrop, "默认应当居中裁剪（与训练一致）")
    }

    @Test func constantImageStaysConstant() {
        let c: UInt32 = 0xFF33_6699
        for (w, h) in [(672, 672), (540, 1170), (200, 120), (1000, 562)] {
            let img = [UInt32](repeating: c, count: w * h)
            let out = FramePreprocessor.toModelInput(img, w: w, h: h, region: FramePreprocessor.cropRect(w: w, h: h))
            #expect(out.count == FramePreprocessor.modelSize * FramePreprocessor.modelSize)
            #expect(out.allSatisfy { $0 == c }, "\(w)x\(h)")
        }
    }

    @Test func cropKeepsOnlyTheCenter() {
        // 左右两条与中间不同色：居中裁剪后一点都不应混进来；整帧压扁时两边会被缩进画面
        let w = 1280, h = 720
        var img = [UInt32](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { img[y * w + x] = (x < 280 || x >= 1000) ? 0xFFFF_0000 : 0xFF00_FF00 }
        }
        let out = FramePreprocessor.toModelInput(img, w: w, h: h, region: FramePreprocessor.cropRect(w: w, h: h))
        #expect(out.allSatisfy { $0 == 0xFF00_FF00 })
    }

    /// 带行尾填充的源图（CVPixelBuffer 的 bytesPerRow 常常大于 宽×4）：按 stride 走，结果与紧凑的源图相同。
    @Test func strideSkipsRowPadding() {
        let w = 700, h = 500, stride = 736
        let img = Self.goldenImage(w: w, h: h, pattern: "noise", seed: 42)
        var padded = [UInt32](repeating: 0xFFFF_FFFF, count: stride * h)
        for y in 0..<h {
            for x in 0..<w { padded[y * stride + x] = img[y * w + x] }
        }
        let r = FramePreprocessor.cropRect(w: w, h: h)
        let want = FramePreprocessor.toModelInput(img, w: w, h: h, region: r)
        let got = padded.withUnsafeBufferPointer {
            FramePreprocessor.toModelInput($0.baseAddress!, stride: stride, w: w, h: h, region: r)
        }
        #expect(got == want)
    }

    /// 3×3 的 1…9 按行排；期望值按"转正之后屏幕上看到的样子"写。
    @Test func orientationTurnsSquareUpright() {
        typealias O = FramePreprocessor.Orientation
        let src: [UInt32] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        #expect(O.identity.apply(src, side: 3) == src)
        // 竖拍的 iPhone 视频 (0, 1, -1, 0)：顺时针转 90°，左下角的 7 到了左上角
        #expect(O(a: 0, b: 1, c: -1, d: 0).apply(src, side: 3) == [7, 4, 1, 8, 5, 2, 9, 6, 3])
        #expect(O(a: -1, b: 0, c: 0, d: -1).apply(src, side: 3) == [9, 8, 7, 6, 5, 4, 3, 2, 1])   // 180°
        #expect(O(a: 0, b: -1, c: 1, d: 0).apply(src, side: 3) == [3, 6, 9, 2, 5, 8, 1, 4, 7])    // 逆时针 90°
        #expect(O(a: -1, b: 0, c: 0, d: 1).apply(src, side: 3) == [3, 2, 1, 6, 5, 4, 9, 8, 7])    // 左右镜像
        // 偶数边长没有中心像素，也要整像素对上
        #expect(O(a: 0, b: 1, c: -1, d: 0).apply([1, 2, 3, 4], side: 2) == [3, 1, 4, 2])
        // 转四次回到原样
        let big = Self.goldenImage(w: 160, h: 160, pattern: "noise", seed: 7)
        let cw = O(a: 0, b: 1, c: -1, d: 0)
        #expect(cw.apply(cw.apply(cw.apply(cw.apply(big, side: 160), side: 160), side: 160), side: 160) == big)
    }

    @Test func orientationSnapsPreferredTransform() {
        typealias O = FramePreprocessor.Orientation
        #expect(O(snapping: 1, 0, 0, 1) == .identity)
        #expect(O(snapping: 0, 1, -1, 0) == O(a: 0, b: 1, c: -1, d: 0))
        #expect(O(snapping: -1, 0, 0, -1) == O(a: -1, b: 0, c: 0, d: -1))
        #expect(O(snapping: 0, -1, 1, 0) == O(a: 0, b: -1, c: 1, d: 0))
        #expect(O(snapping: 6.1e-17, 1, -1, 6.1e-17) == O(a: 0, b: 1, c: -1, d: 0))   // cos 90° 的浮点残差
        #expect(O(snapping: 0, 0, 0, 0) == .identity)
    }
}
