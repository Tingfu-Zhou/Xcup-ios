//
//  ScreenCropper.swift
//  Xcup
//
//  逐行移植自 Android ScreenCropper.java（xcup-android f750061，2026-10-19），两端由
//  XcupTests/ScreenCropperTests.swift 用同一份 screen_crop_golden.txt 对拍，同样的截屏找出的视频画面逐帧一致。
//  改算法必须三处同步：Android ScreenCropper.java、bench/tools/video_rescore.py、这里；改完在 Android 仓库跑
//  python3 bench/tools/video_rescore.py golden 重新生成对拍数据，换掉 XcupTests/screen_crop_golden.txt。
//

import Foundation

/// 在线模式（录屏）专用：在截屏里找出视频画面的位置（去掉四周的黑边），再交给 FramePreprocessor 居中裁正方形。
/// 纯计算，不依赖 UIKit。
///
/// 训练素材是视频文件本身的画面取居中正方形；在线模式拿到的是整个屏幕。只有视频把屏幕的短边占满（横屏全屏）时，
/// "屏幕的居中正方形"才等于"视频的居中正方形"。其余情况视频四周是黑边，直接取屏幕的居中正方形会把黑边一起裁进来，
/// 视频被缩小（19.5:9 的 iPhone、16:9 的视频）：
/// - 竖屏全屏播放：视频是屏幕中间的一条，在居中正方形里只占 56% 的高度，上下是黑边；
/// - 横屏看竖屏视频：左右是大黑边，居中正方形里视频只占中间 56% 的宽度。
///
/// （Android 还有一种：截图尺寸没跟上转屏，系统把横屏画面缩进竖屏尺寸的截图、上下补黑。iOS 的截屏是整个屏幕，广播扩展按
/// RPVideoSampleOrientationKey 转正，宽高比总是和屏幕当前的方向一致，没有这种情况。）
///
/// 做法：播放器的黑边是纯黑的，而且上下（左右）对称。按行数"不黑"的像素，找出最长的一段连续亮着的行；
/// 两边剩下的黑边一样宽（差不超过 max(2, 高/50)）才当黑边裁掉，不对称（画面上沿暗、贴着视频的控制条）就不裁。
/// 列同样处理（只数留下的那些行）。最长的一段太短（黑场、只有黑边里的字幕或加载圈）这一帧不作数，沿用上一次的结果。
/// 裁过一次以后，只要亮着的范围没超出上次裁剩的范围（暗场景、视频边上暗下去）就沿用，不跟着缩：
/// 黑边不会自己变亮，范围变大了才说明画面的位置真的变了。
///
/// 局限：片源自己带的黑边（宽银幕压在 16:9 里）也是对称的纯黑，同样会被裁掉，比训练（连黑边一起居中裁）放大约 1.3 倍；
/// 背景不是纯黑（如 #121212）的播放器不裁，退回整个截屏的居中正方形。
///
/// 一个实例按时间顺序看同一路截屏（它记着上一次裁的范围）；只在视频分析队列里用，不加锁。
final class ScreenCropper {

    /// false：不去黑边，直接取整个截屏的居中正方形（2026-10-19 之前的做法，A/B 对比用）。
    static let enabled = true

    /// R、G、B 都不超过它算黑。播放器的黑边是 0。
    static let blackMax: UInt32 = 16
    /// 一行（列）里不黑的像素 ≥ 长度 / litDiv（至少 1 个）才算这一行（列）亮着：黑边里零星的亮点不算。
    static let litDiv = 64
    /// 最长的一段亮着的行（列）不到这一边的 15%：这一帧不作数（竖屏看宽银幕约 19%）。
    static let minKeepPct = 15
    /// 两边的黑边宽度差不超过 max(2, 长度 / symDiv) 才当黑边裁掉。
    static let symDiv = 50

    /// 一段连续的行（列）[a, b)。
    struct Span: Equatable {
        let a: Int
        let b: Int
    }

    private var width = -1
    private var height = -1
    private var rowCnt: [Int] = []
    private var colCnt: [Int] = []
    /// 上一次裁掉黑边后留下的行 / 列范围；nil = 没裁。
    private var rows: Span?
    private var cols: Span?
    private var last = FramePreprocessor.Region(x0: 0, y0: 0, w: 0, h: 0)

    /// 清空（下一帧从头找）。截屏尺寸变了时 update 会自己清；方向变了而尺寸没变（180°）时要手动清。
    func reset() {
        width = -1
        height = -1
    }

    /// 看一帧截屏，返回视频画面的位置（没有黑边就是整张图）。按时间顺序喂同一路截屏。
    ///
    /// - Parameter argb: 截屏像素，ARGB 打包（0xAARRGGBB），行优先，宽 w、高 h（可以比 w×h 长，多出的不看）
    func update(_ argb: [UInt32], w: Int, h: Int) -> FramePreprocessor.Region {
        precondition(w > 0 && h > 0 && argb.count >= w * h, "截屏 \(w)x\(h)，像素 \(argb.count) 个")
        return argb.withUnsafeBufferPointer { update($0.baseAddress!, stride: w, w: w, h: h) }
    }

    /// 同上，截屏直接给指针。
    ///
    /// - Parameter stride: 一行的像素数（可以大于 w）
    func update(_ src: UnsafePointer<UInt32>, stride: Int, w: Int, h: Int) -> FramePreprocessor.Region {
        if w != width || h != height {
            width = w
            height = h
            rowCnt = [Int](repeating: 0, count: h)
            colCnt = [Int](repeating: 0, count: w)
            rows = nil
            cols = nil
            last = FramePreprocessor.Region(x0: 0, y0: 0, w: w, h: h)
        }
        // 热循环走指针（与 FramePreprocessor 相同的考虑：Xcode 直接 Run 的 Debug 包不优化，数组下标每次都检查）
        rowCnt.withUnsafeMutableBufferPointer { rb in
            let rc = rb.baseAddress!
            for y in 0..<h {
                let row = src + y * stride
                var n = 0
                for x in 0..<w where Self.lit(row[x]) {
                    n += 1
                }
                rc[y] = n
            }
        }
        guard let rowRun = Self.longestRun(rowCnt, h, max(1, w / Self.litDiv)),
              (rowRun.b - rowRun.a) * 100 >= Self.minKeepPct * h else { return last }
        rows = Self.choose(rowRun, h, rows)
        let y0 = rows?.a ?? 0, y1 = rows?.b ?? h

        colCnt.withUnsafeMutableBufferPointer { cb in
            let cc = cb.baseAddress!
            cc.update(repeating: 0, count: w)
            for y in y0..<y1 {
                let row = src + y * stride
                for x in 0..<w where Self.lit(row[x]) {
                    cc[x] += 1
                }
            }
        }
        if let colRun = Self.longestRun(colCnt, w, max(1, (y1 - y0) / Self.litDiv)),
           (colRun.b - colRun.a) * 100 >= Self.minKeepPct * w {
            cols = Self.choose(colRun, w, cols)
        }
        let x0 = cols?.a ?? 0, x1 = cols?.b ?? w
        last = FramePreprocessor.Region(x0: x0, y0: y0, w: x1 - x0, h: y1 - y0)
        return last
    }

    @inline(__always) static func lit(_ p: UInt32) -> Bool {
        ((p &>> 16) & 0xFF) > blackMax || ((p &>> 8) & 0xFF) > blackMax || (p & 0xFF) > blackMax
    }

    /// cnt[0..<n] 里最长的一段连续 ≥ need 的，一样长取前面的；没有返回 nil。
    static func longestRun(_ cnt: [Int], _ n: Int, _ need: Int) -> Span? {
        var bestA = 0, bestLen = 0, a = -1
        for i in 0...n {
            let on = i < n && cnt[i] >= need
            if on && a < 0 {
                a = i
            } else if !on && a >= 0 {
                if i - a > bestLen {
                    bestA = a
                    bestLen = i - a
                }
                a = -1
            }
        }
        return bestLen == 0 ? nil : Span(a: bestA, b: bestA + bestLen)
    }

    /// 这一边留下的范围，nil = 不裁。亮着的范围没超出上次裁剩的 kept 就沿用；否则两边的黑边对称才裁。
    static func choose(_ run: Span, _ n: Int, _ kept: Span?) -> Span? {
        let a = run.a, b = run.b
        if let k = kept, a >= k.a, b <= k.b { return k }
        if b - a < n && abs(a - (n - b)) <= max(2, n / symDiv) { return run }
        return nil
    }
}
