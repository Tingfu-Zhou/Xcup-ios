//
//  ScreenCropperTests.swift
//  XcupTests
//
//  对应 Android ScreenCropperTest.java。最重要的是 matchesAndroidGolden：Android、iOS、bench/tools/video_rescore.py
//  三端用同一份 screen_crop_golden.txt（python3 bench/tools/video_rescore.py golden 生成，取自 Android
//  app/src/test/resources/video/），保证同样的截屏两端找出的视频画面逐帧一致（裁不裁、沿用不沿用都一样）。
//  每个场景该得到什么结果在 video_rescore.py --selftest 里另外核对。Android 改了 ScreenCropper 会重新生成这个文件，
//  换上新文件再跑一遍即可。
//

import Foundation
import Testing
@testable import Xcup

private final class ScreenCropperBundleToken {}

struct ScreenCropperTests {

    typealias R = FramePreprocessor.Region

    static let lcgA: UInt64 = 6364136223846793005
    static let lcgC: UInt64 = 1442695040888963407

    /// 与 video_rescore.crop_golden_frame / Java ScreenCropperTest.frame 相同的测试图：先全黑，再按顺序画矩形
    /// "x0,y0,w,h,填充"。填充：n<种子> 随机噪声（同 FramePreprocessorTests.goldenImage，每个通道走一步 LCG），
    /// c<RRGGBB> 纯色，k<步长> 在 (x + y) % 步长 == 0 的位置画白点（模拟状态栏图标、字幕）。
    static func frame(w: Int, h: Int, rects: [String]) throws -> [UInt32] {
        var img = [UInt32](repeating: 0xFF00_0000, count: w * h)
        for rect in rects {
            let f = rect.split(separator: ",").map(String.init)
            try #require(f.count == 5, "矩形格式不对：\(rect)")
            try #require(!f[4].isEmpty, "矩形没有填充：\(rect)")
            var v: [Int] = []
            for s in f[0...3] {
                v.append(try #require(Int(s), "矩形：\(rect)"))
            }
            let (x0, y0, cw, ch) = (v[0], v[1], v[2], v[3])
            try #require(x0 >= 0 && y0 >= 0 && x0 + cw <= w && y0 + ch <= h, "矩形超出 \(w)x\(h)：\(rect)")
            let kind = f[4].first!
            let arg = String(f[4].dropFirst())
            switch kind {
            case "n":
                var s = try #require(UInt64(arg), "种子：\(rect)")
                for y in y0..<(y0 + ch) {
                    for x in x0..<(x0 + cw) {
                        s = s &* lcgA &+ lcgC
                        let r = UInt32(s >> 56)
                        s = s &* lcgA &+ lcgC
                        let g = UInt32(s >> 56)
                        s = s &* lcgA &+ lcgC
                        let b = UInt32(s >> 56)
                        img[y * w + x] = 0xFF00_0000 | (r << 16) | (g << 8) | b
                    }
                }
            case "c":
                let color = 0xFF00_0000 | (try #require(UInt32(arg, radix: 16), "颜色：\(rect)"))
                for y in y0..<(y0 + ch) {
                    for x in x0..<(x0 + cw) {
                        img[y * w + x] = color
                    }
                }
            case "k":
                let step = try #require(Int(arg), "步长：\(rect)")
                for y in y0..<(y0 + ch) {
                    for x in x0..<(x0 + cw) where (x + y) % step == 0 {
                        img[y * w + x] = 0xFFFF_FFFF
                    }
                }
            default:
                Issue.record("不认识的填充：\(rect)")
            }
        }
        return img
    }

    static func goldenURL() -> URL? {
        if let url = Bundle(for: ScreenCropperBundleToken.self).url(forResource: "screen_crop_golden", withExtension: "txt") {
            return url
        }
        let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("screen_crop_golden.txt")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    /// 每个 case 是同一个 ScreenCropper 依次看的几帧：`case <名字>`，后面每帧一行
    /// `frame <w> <h> <期望 x0> <y0> <w> <h> [<x0>,<y0>,<w>,<h>,<填充>]...`。
    @Test func matchesAndroidGolden() throws {
        let url = try #require(Self.goldenURL(),
                               "缺少测试资源 screen_crop_golden.txt（Android 仓库 python3 bench/tools/video_rescore.py golden 生成）")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines: [String] = text.split(whereSeparator: \.isNewline).map(String.init)
        var cropper: ScreenCropper? = nil
        var name = ""
        var cases = 0, frames = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let f = line.split(whereSeparator: { (c: Character) in c == " " || c == "\t" }).map(String.init)
            if f[0] == "case" {
                name = f.count > 1 ? f[1] : "?"
                cropper = ScreenCropper()          // 每个 case 一个新的：它记着上一次裁的范围
                cases += 1
                continue
            }
            try #require(f[0] == "frame" && f.count >= 7, "frame 行格式不对：\(line)")
            let c = try #require(cropper, "frame 行前面没有 case：\(line)")
            var v: [Int] = []
            for s in f[1...6] {
                v.append(try #require(Int(s), "frame 行：\(line)"))
            }
            let (w, h) = (v[0], v[1])
            let want = R(x0: v[2], y0: v[3], w: v[4], h: v[5])
            let got = c.update(try Self.frame(w: w, h: h, rects: Array(f[7...])), w: w, h: h)
            #expect(got == want, "\(name) 第 \(frames) 帧（\(line)）")
            frames += 1
        }
        #expect(cases >= 10 && frames > cases, "对拍数据里的 case 太少：\(cases) 个 case、\(frames) 帧")
    }

    /// 与 Android 的同名测试相同（场景是 Android 的：2400×1080 的手机截一半、截图没跟上转屏）。
    @Test func squareInsideVideoMatchesTraining() throws {
        let w = 540, h = 1200
        let img = try Self.frame(w: w, h: h, rects: ["54,478,432,243,c33aa55"])
        let video = ScreenCropper().update(img, w: w, h: h)
        #expect(video == R(x0: 54, y0: 478, w: 432, h: 243))
        // 再取居中正方形：就是视频自己的居中正方形（训练素材的取法），一点黑边都不带
        #expect(FramePreprocessor.cropRect(in: video) == R(x0: 148, y0: 478, w: 243, h: 243))
        let out = FramePreprocessor.toModelInput(img, w: w, h: h, region: FramePreprocessor.cropRect(in: video))
        #expect(out.allSatisfy { $0 == 0xFF33_AA55 })
        // 不去黑边（2026-10-19 之前）：整个截图的居中正方形，上下大半是黑的
        let whole = FramePreprocessor.toModelInput(img, w: w, h: h, region: FramePreprocessor.cropRect(w: w, h: h))
        let black = whole.filter { !ScreenCropper.lit($0) }.count
        #expect(black > FramePreprocessor.modelSize * FramePreprocessor.modelSize / 2, "黑的像素 \(black)")
    }

    /// iOS 竖屏全屏播放：广播扩展转正、短边缩到 480 后约 480×1040（19.5:9），16:9 的视频是中间 480×270 的一条；
    /// 上面有状态栏图标，下面黑边里有字幕。
    @Test func portraitFullScreenStrip() throws {
        let w = 480, h = 1040
        let img = try Self.frame(w: w, h: h, rects: ["0,385,480,270,c3366cc", "0,0,480,30,k5", "60,700,360,20,k3"])
        let video = ScreenCropper().update(img, w: w, h: h)
        #expect(video == R(x0: 0, y0: 385, w: 480, h: 270))
        #expect(FramePreprocessor.cropRect(in: video) == R(x0: 105, y0: 385, w: 270, h: 270))
        let out = FramePreprocessor.toModelInput(img, w: w, h: h, region: FramePreprocessor.cropRect(in: video))
        #expect(out.allSatisfy { $0 == 0xFF33_66CC })
        // 不去黑边：整个截屏的居中正方形里四成是黑边，视频缩到 0.56 倍
        let whole = FramePreprocessor.toModelInput(img, w: w, h: h, region: FramePreprocessor.cropRect(w: w, h: h))
        let black = whole.filter { !ScreenCropper.lit($0) }.count
        #expect(black > FramePreprocessor.modelSize * FramePreprocessor.modelSize / 3, "黑的像素 \(black)")
    }

    /// 横屏全屏看 16:9：视频占满屏幕的高，左右是窄黑边。去不去黑边，居中正方形都一样（取整最多差 1 个像素）。
    @Test func landscapeFullScreenKeepsCenterSquare() throws {
        let w = 1040, h = 480
        let img = try Self.frame(w: w, h: h, rects: ["93,0,853,480,n13"])
        let video = ScreenCropper().update(img, w: w, h: h)
        #expect(video == R(x0: 93, y0: 0, w: 853, h: 480))
        let a = FramePreprocessor.cropRect(in: video), b = FramePreprocessor.cropRect(w: w, h: h)
        #expect(abs(a.x0 - b.x0) <= 1 && a.y0 == b.y0 && a.w == b.w && a.h == b.h, "\(a) vs \(b)")
    }

    @Test func wholeFrameWhenNothingToTrim() throws {
        let w = 1200, h = 540
        let img = try Self.frame(w: w, h: h, rects: ["0,0,1200,540,n7"])
        #expect(ScreenCropper().update(img, w: w, h: h) == R(x0: 0, y0: 0, w: w, h: h))
        #expect(ScreenCropper.enabled, "默认去黑边")
    }

    /// 带行尾填充的截屏：按 stride 走，结果与紧凑的截屏相同。reset 之后不再沿用上一次裁的范围。
    @Test func strideAndReset() throws {
        let w = 216, h = 480, stride = 240
        let img = try Self.frame(w: w, h: h, rects: ["0,179,216,121,n4"])
        var padded = [UInt32](repeating: 0xFFFF_FFFF, count: stride * h)
        for y in 0..<h {
            for x in 0..<w { padded[y * stride + x] = img[y * w + x] }
        }
        let strip = R(x0: 0, y0: 179, w: 216, h: 121)
        let c = ScreenCropper()
        let got = padded.withUnsafeBufferPointer { c.update($0.baseAddress!, stride: stride, w: w, h: h) }
        #expect(got == strip)
        // 暗场景：视频上下两截暗下去，亮着的只剩中间，没超出上次裁剩的范围，沿用
        let dark = try Self.frame(w: w, h: h, rects: ["0,200,216,80,n5"])
        #expect(c.update(dark, w: w, h: h) == strip)
        // reset（方向变了而尺寸没变、长时间静音）之后从头找：只看这一帧
        c.reset()
        #expect(c.update(dark, w: w, h: h) == R(x0: 0, y0: 200, w: 216, h: 80))
    }
}
