//
//  FramePreprocessor.swift
//  Xcup
//
//  逐行移植自 Android FramePreprocessor.java（xcup-android c326083，2026-10-14；cropRect(in:) 对应 f750061），两端由
//  XcupTests/FramePreprocessorTests.swift 用同一份 preprocess_golden.txt 对拍，喂给视频模型的画面逐像素一致。
//  改算法必须三处同步：Android FramePreprocessor.java、bench/tools/video_rescore.py、这里；改完在 Android 仓库跑
//  python3 bench/tools/video_rescore.py golden 重新生成对拍数据，换掉 XcupTests/preprocess_golden.txt。
//
//  文件末尾的 Orientation（把正方形画面转正）是 iOS 专有的，Android 由 SurfaceTexture 的变换矩阵完成。
//

import Foundation

/// 视频模型输入的预处理（纯计算，不依赖 UIKit / AVFoundation）：把一帧画面变成模型要的 160×160。
///
/// **必须和训练时一致。** 训练素材是这样来的（make_movinet_clips.py、train_mobilenetv3_tap_3class.py）：
///
///     ffmpeg -vf scale=224:224:force_original_aspect_ratio=increase,crop=224:224   短边缩到 224，居中裁 224×224
///     cv2.resize(frame, (160, 160), interpolation=cv2.INTER_AREA)                 面积平均缩到 160×160
///
/// 2026-10-15 之前 iOS 是把整帧压扁成 160×160：离线模式 AVAssetImageGenerator 先按宽高比缩进 160×160（16:9 → 160×90），
/// 再拉伸成 160×160（训练时裁掉的左右两边也送进了模型，竖直方向只剩 90 行）；在线模式整屏直接压扁。现在两种模式都走这里：
/// 1. 按 `cropRect` 居中裁正方形（离线模式在 VideoFrameExtractor 里裁好、用 vImage 缩到 672×672，在线模式在这里裁；
///    在线模式先用 ScreenCropper 去掉截屏里视频四周的黑边，再在视频画面里居中裁，见 `cropRect(in:)`）；
/// 2. 面积平均缩到 224（训练片段的尺寸）；
/// 3. 面积平均缩到 160（与训练读帧时的 cv2.INTER_AREA 同一套权重）。
///
/// 面积缩小与 OpenCV 的 INTER_AREA 是同一种算法（权重表、Float 累加顺序、四舍五入到偶数），与 cv2 最多差 1。
///
/// 像素统一用 ARGB 打包的 UInt32（0xAARRGGBB，与 Android Bitmap.getPixels 的 int 相同；小端机器上
/// kCVPixelFormatType_32BGRA 的内存 B,G,R,A 按 UInt32 读出来就是它），输出的 alpha 恒为 255。
enum FramePreprocessor {

    /// 模型输入边长（VideoClassifierHelper.SIZE 就是它）。
    static let modelSize = 160
    /// 训练片段的边长：ffmpeg 先裁成 224×224，训练读帧时再缩到 160。
    static let clipSize = 224

    /// true：居中裁正方形（与训练一致）；false：整帧压扁（2026-10-15 之前的做法，只留作 A/B 对比）。
    static let centerCrop = true

    /// 管线名里预处理的部分（与 Android 评测 CSV 参数行 VIDEO_PIPE 的写法相同）。
    static var geometryName: String { centerCrop ? "crop" : "squash" }

    /// 一块矩形区域（像素），原点左上。
    struct Region: Equatable {
        let x0: Int
        let y0: Int
        let w: Int
        let h: Int
    }

    /// 送进模型的区域。centerCrop 时是居中的正方形，边长等于短边，与 ffmpeg
    /// "scale=...:force_original_aspect_ratio=increase,crop" 取的是同一块（差不到半个像素）；否则是整帧。
    static func cropRect(w: Int, h: Int) -> Region {
        if !centerCrop { return Region(x0: 0, y0: 0, w: w, h: h) }
        let side = min(w, h)
        return Region(x0: (w - side) / 2, y0: (h - side) / 2, w: side, h: side)
    }

    /// region 里的居中正方形（在线模式：ScreenCropper 找出的视频画面里再居中裁）。
    static func cropRect(in region: Region) -> Region {
        let r = cropRect(w: region.w, h: region.h)
        return Region(x0: region.x0 + r.x0, y0: region.y0 + r.y0, w: r.w, h: r.h)
    }

    /// CPU 阶段：取 region 区域 → 缩到 224×224 → 缩到 160×160。
    ///
    /// - Parameters:
    ///   - argb: 源图，ARGB 打包，行优先，宽 w、高 h
    ///   - region: nil 表示整张图（离线模式已经裁好、缩到 672×672 了）
    /// - Returns: 160×160 的 ARGB 像素
    static func toModelInput(_ argb: [UInt32], w: Int, h: Int, region: Region?) -> [UInt32] {
        precondition(w > 0 && h > 0 && argb.count >= w * h, "源图 \(w)x\(h)，像素 \(argb.count) 个")
        return argb.withUnsafeBufferPointer { toModelInput($0.baseAddress!, stride: w, w: w, h: h, region: region) }
    }

    /// 同上，源图直接给指针（CVPixelBuffer / vImage 的缓冲区，不用先拷成数组）。
    ///
    /// - Parameter stride: 源图一行的像素数（可以大于 w，例如 CVPixelBuffer 每行末尾有填充）
    static func toModelInput(_ src: UnsafePointer<UInt32>, stride: Int, w: Int, h: Int, region: Region?) -> [UInt32] {
        let r = region ?? Region(x0: 0, y0: 0, w: w, h: h)
        let clip = resize(src, stride: stride, x0: r.x0, y0: r.y0, cw: r.w, ch: r.h, dw: clipSize, dh: clipSize)
        return clip.withUnsafeBufferPointer {
            resize($0.baseAddress!, stride: clipSize, x0: 0, y0: 0, cw: clipSize, ch: clipSize,
                   dw: modelSize, dh: modelSize)
        }
    }

    /// 数组版的 resize（单元测试用）。
    static func resize(_ src: [UInt32], stride: Int, x0: Int, y0: Int, cw: Int, ch: Int, dw: Int, dh: Int) -> [UInt32] {
        precondition(src.count >= (y0 + ch - 1) * stride + x0 + cw, "源图像素不够")
        return src.withUnsafeBufferPointer {
            resize($0.baseAddress!, stride: stride, x0: x0, y0: y0, cw: cw, ch: ch, dw: dw, dh: dh)
        }
    }

    /// 把 src 中 {x0, y0, cw, ch} 这块缩放到 dw×dh。两个方向都是缩小时用面积平均（同 cv2.INTER_AREA，
    /// 整数倍时走与 OpenCV 相同的整块求和），否则双线性（只在源图比 224 还小时才会用到）。
    ///
    /// - Parameter stride: src 一行的像素数
    static func resize(_ src: UnsafePointer<UInt32>, stride: Int, x0: Int, y0: Int,
                       cw: Int, ch: Int, dw: Int, dh: Int) -> [UInt32] {
        if cw == dw && ch == dh {
            var out = [UInt32](repeating: 0, count: dw * dh)
            out.withUnsafeMutableBufferPointer { ob in
                let o = ob.baseAddress!
                for y in 0..<dh {
                    let row = src + (y0 + y) * stride + x0
                    for x in 0..<dw { o[y * dw + x] = 0xFF00_0000 | row[x] }
                }
            }
            return out
        }
        if cw >= dw && ch >= dh {
            if cw % dw == 0 && ch % dh == 0 {
                return areaInteger(src, stride: stride, x0: x0, y0: y0, cw: cw, ch: ch, dw: dw, dh: dh)
            }
            return area(src, stride: stride, x0: x0, y0: y0, cw: cw, ch: ch, dw: dw, dh: dh)
        }
        return bilinear(src, stride: stride, x0: x0, y0: y0, cw: cw, ch: ch, dw: dw, dh: dh)
    }

    /// OpenCV computeResizeAreaTab 的权重表：第 k 项表示 dst[di[k]] += src[si[k]] * alpha[k]。
    struct AreaTab {
        var di: [Int] = []
        var si: [Int] = []
        var alpha: [Float] = []
        var n: Int { di.count }
    }

    static func areaTab(_ ssize: Int, _ dsize: Int) -> AreaTab {
        let scale = 1.0 / (Double(dsize) / Double(ssize))      // 与 cv::resize 相同：1 / inv_scale
        var t = AreaTab()
        t.di.reserveCapacity(ssize * 2 + 2)
        t.si.reserveCapacity(ssize * 2 + 2)
        t.alpha.reserveCapacity(ssize * 2 + 2)
        for dx in 0..<dsize {
            let fsx1 = Double(dx) * scale
            let fsx2 = fsx1 + scale
            let cellWidth = min(scale, Double(ssize) - fsx1)
            var sx1 = Int(fsx1.rounded(.up))
            var sx2 = Int(fsx2.rounded(.down))
            sx2 = min(sx2, ssize - 1)
            sx1 = min(sx1, sx2)
            if Double(sx1) - fsx1 > 1e-3 {
                t.di.append(dx)
                t.si.append(sx1 - 1)
                t.alpha.append(Float((Double(sx1) - fsx1) / cellWidth))
            }
            for sx in sx1..<sx2 {
                t.di.append(dx)
                t.si.append(sx)
                t.alpha.append(Float(1.0 / cellWidth))
            }
            if fsx2 - Double(sx2) > 1e-3 {
                t.di.append(dx)
                t.si.append(sx2)
                t.alpha.append(Float(min(min(fsx2 - Double(sx2), 1.0), cellWidth) / cellWidth))
            }
        }
        return t
    }

    /// 非整数倍的面积缩小：与 OpenCV ResizeArea_Invoker 相同的计算顺序（先横向、再按行加权累加，Float）。
    /// 热循环都走指针、移位用 &>>：Xcode 直接 Run 到手机的 Debug 包不优化，数组下标每次检查越界，
    /// UInt32 的 >> 和整数类型转换走泛型实现，都会慢几倍到几十倍（结果完全一样）。
    static func area(_ src: UnsafePointer<UInt32>, stride: Int, x0: Int, y0: Int,
                     cw: Int, ch: Int, dw: Int, dh: Int) -> [UInt32] {
        let xt = areaTab(cw, dw)
        let yt = areaTab(ch, dh)
        let n3 = dw * 3
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: n3)
        let sum = UnsafeMutablePointer<Float>.allocate(capacity: n3)
        buf.initialize(repeating: 0, count: n3)
        sum.initialize(repeating: 0, count: n3)
        defer {
            buf.deallocate()
            sum.deallocate()
        }
        var out = [UInt32](repeating: 0, count: dw * dh)
        out.withUnsafeMutableBufferPointer { ob in
            let o = ob.baseAddress!
            xt.di.withUnsafeBufferPointer { xdiB in
                xt.si.withUnsafeBufferPointer { xsiB in
                    xt.alpha.withUnsafeBufferPointer { xalB in
                        let xdi = xdiB.baseAddress!, xsi = xsiB.baseAddress!, xal = xalB.baseAddress!
                        let xn = xt.n
                        var prevDy = yt.di[0]
                        for j in 0..<yt.n {
                            let dy = yt.di[j]
                            let beta = yt.alpha[j]
                            let row = src + (y0 + yt.si[j]) * stride + x0
                            buf.update(repeating: 0, count: n3)
                            for k in 0..<xn {
                                let p = row[xsi[k]]
                                let a = xal[k]
                                let d = xdi[k] * 3
                                buf[d] = buf[d] + Float((p &>> 16) & 0xFF) * a
                                buf[d + 1] = buf[d + 1] + Float((p &>> 8) & 0xFF) * a
                                buf[d + 2] = buf[d + 2] + Float(p & 0xFF) * a
                            }
                            if dy != prevDy {
                                emitRow(o, prevDy, dw, sum)
                                for i in 0..<n3 { sum[i] = beta * buf[i] }
                                prevDy = dy
                            } else {
                                for i in 0..<n3 { sum[i] = sum[i] + beta * buf[i] }
                            }
                        }
                        emitRow(o, prevDy, dw, sum)
                    }
                }
            }
        }
        return out
    }

    /// 整数倍的面积缩小：整块求和后乘 1/面积（与 OpenCV 的 resizeAreaFast 相同）。
    static func areaInteger(_ src: UnsafePointer<UInt32>, stride: Int, x0: Int, y0: Int,
                            cw: Int, ch: Int, dw: Int, dh: Int) -> [UInt32] {
        let fx = cw / dw, fy = ch / dh
        let scale: Float = 1 / Float(fx * fy)
        var out = [UInt32](repeating: 0, count: dw * dh)
        out.withUnsafeMutableBufferPointer { ob in
            let o = ob.baseAddress!
            for dy in 0..<dh {
                for dx in 0..<dw {
                    // 和都用 UInt32（255 × 块面积，不会溢出）：Int(UInt32) 和 >> 在 Debug 包里走泛型，这个循环会慢几十倍
                    var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0
                    for yy in 0..<fy {
                        let row = src + (y0 + dy * fy + yy) * stride + x0 + dx * fx
                        for xx in 0..<fx {
                            let p = row[xx]
                            r &+= (p &>> 16) & 0xFF
                            g &+= (p &>> 8) & 0xFF
                            b &+= p & 0xFF
                        }
                    }
                    o[dy * dw + dx] = pack(sat(Float(r) * scale), sat(Float(g) * scale), sat(Float(b) * scale))
                }
            }
        }
        return out
    }

    /// 放大（源图比目标还小时）：像素中心对齐的双线性，Double 计算。
    static func bilinear(_ src: UnsafePointer<UInt32>, stride: Int, x0: Int, y0: Int,
                         cw: Int, ch: Int, dw: Int, dh: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: dw * dh)
        let sx = Double(cw) / Double(dw), sy = Double(ch) / Double(dh)
        out.withUnsafeMutableBufferPointer { ob in
            let o = ob.baseAddress!
            for dy in 0..<dh {
                let fy = (Double(dy) + 0.5) * sy - 0.5
                let ya = Int(fy.rounded(.down))
                let wy = fy - Double(ya)
                let y1 = clamp(ya, ch), y2 = clamp(ya + 1, ch)
                for dx in 0..<dw {
                    let fx = (Double(dx) + 0.5) * sx - 0.5
                    let xa = Int(fx.rounded(.down))
                    let wx = fx - Double(xa)
                    let x1 = clamp(xa, cw), x2 = clamp(xa + 1, cw)
                    let p11 = src[(y0 + y1) * stride + x0 + x1], p12 = src[(y0 + y1) * stride + x0 + x2]
                    let p21 = src[(y0 + y2) * stride + x0 + x1], p22 = src[(y0 + y2) * stride + x0 + x2]
                    func lerp(_ sh: UInt32) -> UInt32 {
                        let top = (1 - wx) * Double((p11 &>> sh) & 0xFF) + wx * Double((p12 &>> sh) & 0xFF)
                        let bot = (1 - wx) * Double((p21 &>> sh) & 0xFF) + wx * Double((p22 &>> sh) & 0xFF)
                        return sat((1 - wy) * top + wy * bot)
                    }
                    o[dy * dw + dx] = pack(lerp(16), lerp(8), lerp(0))
                }
            }
        }
        return out
    }

    private static func emitRow(_ out: UnsafeMutablePointer<UInt32>, _ dy: Int, _ dw: Int,
                                _ sum: UnsafeMutablePointer<Float>) {
        let o = dy * dw
        for dx in 0..<dw {
            out[o + dx] = pack(sat(sum[3 * dx]), sat(sum[3 * dx + 1]), sat(sum[3 * dx + 2]))
        }
    }

    @inline(__always) private static func clamp(_ i: Int, _ n: Int) -> Int {
        i < 0 ? 0 : (i >= n ? n - 1 : i)
    }

    /// 与 OpenCV saturate_cast<uchar>(float) 相同：四舍五入到偶数，再截到 0..255。
    @inline(__always) private static func sat(_ v: Float) -> UInt32 {
        sat(Double(v))
    }

    @inline(__always) private static func sat(_ v: Double) -> UInt32 {
        let r = v.rounded(.toNearestOrEven)
        if !(r > 0) { return 0 }                // 也接住 NaN（Java 的 (int) NaN 是 0）
        return r >= 255 ? 255 : UInt32(r)
    }

    @inline(__always) private static func pack(_ r: UInt32, _ g: UInt32, _ b: UInt32) -> UInt32 {
        0xFF00_0000 | (r &<< 16) | (g &<< 8) | b
    }
}

// MARK: - 转正（iOS 专有）

extension FramePreprocessor {

    /// 视频轨道 preferredTransform 里的旋转 / 翻转（90° 的整数倍）。
    ///
    /// AVPlayerItemVideoOutput 给的像素是编码时的方向（竖拍的片子是横着的），AVPlayerLayer 显示时才按 preferredTransform
    /// 转正；模型要的是转正之后的画面（Android 的解码器按 KEY_ROTATION 转正，SurfaceTexture 的变换矩阵里已经包含）。
    /// 居中裁剪是对称的：编码方向上居中的正方形，转正之后还是居中的正方形，所以先裁剪缩放、最后在 160×160 上转正即可。
    struct Orientation: Equatable {
        /// CGAffineTransform 的 2×2 部分，取值 0 / ±1：显示坐标 (x', y') = (a·x + c·y, b·x + d·y) + 平移，y 轴朝下。
        /// 竖拍的 iPhone 视频是 (0, 1, -1, 0)，即顺时针转 90°。
        let a: Int
        let b: Int
        let c: Int
        let d: Int

        static let identity = Orientation(a: 1, b: 0, c: 0, d: 1)

        init(a: Int, b: Int, c: Int, d: Int) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
        }

        /// 取 preferredTransform 最接近的 90° 整数倍旋转（可带翻转）；退化的变换当作不转。
        init(snapping a: Double, _ b: Double, _ c: Double, _ d: Double) {
            func unit(_ v: Double) -> Int { v < 0 ? -1 : 1 }
            if abs(a) + abs(d) >= abs(b) + abs(c) {
                if a == 0 && d == 0 {
                    self = .identity
                } else {
                    self.init(a: unit(a), b: 0, c: 0, d: unit(d))
                }
            } else {
                self.init(a: 0, b: unit(b), c: unit(c), d: 0)
            }
        }

        var isIdentity: Bool { self == .identity }

        /// 正方形画面（边长 n，行优先 ARGB）转正。输出 (x', y') 取自源 (x, y)：以中心为原点时 (x, y) = Mᵀ·(x', y')
        /// （M 是正交矩阵，逆就是转置）。乘 2 免得出现半个像素：2x = m + a·u + b·v，2y = m + c·u + d·v，
        /// 其中 m = n − 1，u = 2x' − m，v = 2y' − m。
        func apply(_ src: [UInt32], side n: Int) -> [UInt32] {
            precondition(src.count == n * n, "不是 \(n)x\(n) 的正方形：\(src.count) 个像素")
            if isIdentity { return src }
            var out = [UInt32](repeating: 0, count: n * n)
            let m = n - 1
            src.withUnsafeBufferPointer { sb in
                out.withUnsafeMutableBufferPointer { ob in
                    let s = sb.baseAddress!, o = ob.baseAddress!
                    for yp in 0..<n {
                        let v = 2 * yp - m
                        for xp in 0..<n {
                            let u = 2 * xp - m
                            let x = (m + a * u + b * v) / 2
                            let y = (m + c * u + d * v) / 2
                            o[yp * n + xp] = s[y * n + x]
                        }
                    }
                }
            }
            return out
        }
    }
}
