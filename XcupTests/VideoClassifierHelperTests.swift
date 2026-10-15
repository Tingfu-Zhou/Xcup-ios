//
//  VideoClassifierHelperTests.swift
//  XcupTests
//
//  模型输入张量的排布：[1, 12, 160, 160, 3]，t → h → w → c，R、G、B 顺序，0–255 原值（模型里自带 Rescaling）。
//  R/B 对调、多除一次 255 是移植时最常见的错误，模型照样能跑出结果，只是不准，所以专门测。
//

import Testing
@testable import Xcup

struct VideoClassifierHelperTests {

    static let perFrame = VideoClassifierHelper.SIZE * VideoClassifierHelper.SIZE

    @Test func tensorIsRawRGB() {
        var frames = [[UInt32]](repeating: [UInt32](repeating: 0xFF10_2030, count: Self.perFrame),
                                count: VideoClassifierHelper.TIME)
        frames[VideoClassifierHelper.TIME - 1][Self.perFrame - 1] = 0xFFFF_0001   // 最后一帧右下角：R=255 G=0 B=1
        frames[1][VideoClassifierHelper.SIZE] = 0xFF00_FF00                       // 第 2 帧第 2 行第 1 个像素：纯绿
        var buf = [Float](repeating: -1, count: VideoClassifierHelper.TIME * Self.perFrame * VideoClassifierHelper.CHANNELS)
        #expect(VideoClassifierHelper.writeInput(frames, into: &buf))
        #expect(Array(buf[0..<3]) == [16, 32, 48])
        #expect(Array(buf[(buf.count - 3)...]) == [255, 0, 1])
        let g = (Self.perFrame + VideoClassifierHelper.SIZE) * 3
        #expect(Array(buf[g..<(g + 3)]) == [0, 255, 0])
        #expect(!buf.contains(-1), "每个元素都应写到")
    }

    @Test func rejectsWrongFrameCountOrSize() {
        var buf = [Float](repeating: 0, count: VideoClassifierHelper.TIME * Self.perFrame * VideoClassifierHelper.CHANNELS)
        let ok = [UInt32](repeating: 0, count: Self.perFrame)
        #expect(!VideoClassifierHelper.writeInput([[UInt32]](repeating: ok, count: 11), into: &buf))
        var bad = [[UInt32]](repeating: ok, count: VideoClassifierHelper.TIME)
        bad[3] = [UInt32](repeating: 0, count: Self.perFrame - 1)
        #expect(!VideoClassifierHelper.writeInput(bad, into: &buf))
    }
}
