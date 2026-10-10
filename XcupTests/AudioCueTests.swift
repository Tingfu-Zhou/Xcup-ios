//
//  AudioCueTests.swift
//  XcupTests
//
//  对应 Android AudioCueTest.java。最重要的是 matchesAndroidGolden：Android、iOS、bench/tools/fusion_lab.py
//  三端用同一份 audio_cue_golden.csv（python3 bench/tools/fusion_lab.py golden 生成，取自 Android
//  app/src/test/resources/fusion/）：真实结果的 YAMNet 分数、阈值的单精度值和前后 1 ulp、累加顺序敏感的值。
//  分组分数逐位比较、线索逐行比较。Android 改了分组或阈值会重新生成这个文件，换上新文件再跑一遍即可。
//

import Foundation
import Testing
@testable import Xcup

private final class BundleToken {}

struct AudioCueTests {

    static func goldenURL() -> URL? {
        if let url = Bundle(for: BundleToken.self).url(forResource: "audio_cue_golden", withExtension: "csv") {
            return url
        }
        let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("audio_cue_golden.csv")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    /// 每行建一个 521 维数组，全部填 NaN，只把 s 列的值填进对应下标（分组时用错一个下标，和就成了 NaN）；
    /// 7 个分组分数要和期望逐位相等，线索名要和最后一列相同。第一处不一致就停下，报出行号和期望值。
    @Test func matchesAndroidGolden() throws {
        let url = try #require(Self.goldenURL(), "缺少测试资源 audio_cue_golden.csv")
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        try #require(!lines.isEmpty, "audio_cue_golden.csv 是空的")
        let head = lines.removeFirst().split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        // 表头：s<下标>… 是线索用到的那几个 AudioSet 下标，然后是 7 个分组分数列（与评测 CSV 的列名相同）和线索名
        let nIdx = head.count - AudioCue.nFeatures - 1
        try #require(nIdx > 0, "表头列数不对：\(head.count)")
        var idx: [Int] = []
        for j in 0..<nIdx {
            try #require(head[j].hasPrefix("s"), "表头第 \(j + 1) 列：\(head[j])")
            let i = try #require(Int(head[j].dropFirst()), "表头第 \(j + 1) 列：\(head[j])")
            try #require(i >= 0 && i < AudioCue.nClasses, "表头第 \(j + 1) 列下标越界：\(head[j])")
            idx.append(i)
        }
        #expect(Array(head[nIdx..<(nIdx + AudioCue.nFeatures)]) == AudioCue.featureCols)
        #expect(head[head.count - 1] == "a_cue")

        var n = 0
        for (k, line) in lines.enumerated() {
            let row = "golden 第 \(k + 2) 行"
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            try #require(f.count == head.count, "\(row) 列数不对：\(line)")
            var scores = [Float](repeating: .nan, count: AudioCue.nClasses)
            for j in 0..<nIdx {
                scores[idx[j]] = try #require(Float(f[j]), "\(row) \(head[j])：\(f[j])")
            }
            let got = try #require(AudioCue.features(scores), "\(row) features 返回 nil")
            for g in 0..<AudioCue.nFeatures {
                let want = try #require(Float(f[nIdx + g]), "\(row) \(AudioCue.featureCols[g])：\(f[nIdx + g])")
                try #require(got[g].bitPattern == want.bitPattern,
                             "\(row) \(AudioCue.featureCols[g]) 期望 \(want) 实际 \(got[g])")
            }
            let wantCue = f[f.count - 1]
            let gotCue = AudioCue.name(AudioCue.classify(got))
            try #require(gotCue == wantCue, "\(row) 线索：期望 \(wantCue)，实际 \(gotCue)")
            try #require(AudioCue.name(AudioCue.of(scores)) == wantCue, "\(row) of()：期望 \(wantCue)")
            n += 1
        }
        #expect(n >= 1000, "对拍数据太少：\(n)")
    }

    /// 分组分数 → 线索（只放组里一个下标，组和就是它本身）
    private static func cueOf(_ voc: Float, _ speech: Float, _ music: Float, _ silence: Float, _ impact: Float) -> Int {
        var s = [Float](repeating: 0, count: AudioCue.nClasses)
        s[11] = voc            // 尖叫：只在扩展人声组
        s[0] = speech
        s[132] = music
        s[494] = silence
        s[461] = impact        // 拍打
        return AudioCue.of(s)
    }

    @Test func classifyOrderAndThresholds() {
        #expect(Self.cueOf(0, 0.9, 0, 0, 0) == AudioCue.dialog)
        #expect(Self.cueOf(0.02, 0.9, 0, 0, 0) == AudioCue.other)           // 有一点人声：不算对白
        #expect(Self.cueOf(0, 0.1, 0.5, 0, 0) == AudioCue.music)
        #expect(Self.cueOf(0, 0.4, 0.4, 0, 0) == AudioCue.music)            // 音乐 = Speech 算音乐
        #expect(Self.cueOf(0, 0.45, 0.4, 0, 0) == AudioCue.other)           // Speech 更高：不是音乐，也不算安静
        #expect(Self.cueOf(0, 0.1, 0.1, 0.5, 0) == AudioCue.quiet)
        #expect(Self.cueOf(0, 0.1, 0.1, 0.1, 0) == AudioCue.blind)
        #expect(Self.cueOf(0.5, 0.1, 0.5, 0, 0) == AudioCue.vocal)          // 人声多：不算听不出
        #expect(Self.cueOf(0, 0.1, 0.5, 0, 0.3) == AudioCue.impact)         // 有拍打声：不算听不出
        #expect(Self.cueOf(0, 0.1, 0.5, 0, 0.15) == AudioCue.other)         // 撞击声 0.1~0.2：不听不出也不算拍打
        // 阈值按 Double 比：0.7f 比 0.7 小一点，不算对白；大 1 ulp 才算
        #expect(Self.cueOf(0, 0.7, 0, 0, 0) == AudioCue.other)
        #expect(Self.cueOf(0, Float(0.7).nextUp, 0, 0, 0) == AudioCue.dialog)
    }

    @Test func unknownWithoutScores() {
        #expect(AudioCue.features(nil) == nil)
        #expect(AudioCue.features([]) == nil)
        #expect(AudioCue.features([Float](repeating: 0, count: 1024)) == nil)
        #expect(AudioCue.of(nil) == AudioCue.unknown)
        #expect(AudioCue.of([]) == AudioCue.unknown)
        #expect(AudioCue.classify(nil) == AudioCue.unknown)
        #expect(AudioCue.name(AudioCue.unknown) == "")
        #expect(AudioCue.label(AudioCue.unknown) == "")
    }

    @Test func namesRoundTrip() {
        for c in AudioCue.unknown...AudioCue.impact {
            #expect(AudioCue.fromName(AudioCue.name(c)) == c)
        }
        #expect(AudioCue.fromName("bogus") == AudioCue.unknown)
        #expect(AudioCue.fromName(nil) == AudioCue.unknown)
        #expect(AudioCue.name(AudioCue.dialog) == "dialog")
        #expect(AudioCue.label(AudioCue.dialog) == "对白")
    }

    @Test func uninformativeIsMusicQuietBlind() {
        for c in AudioCue.unknown...AudioCue.impact {
            let want = c == AudioCue.music || c == AudioCue.quiet || c == AudioCue.blind
            #expect(AudioCue.uninformative(c) == want, "\(AudioCue.name(c))")
        }
    }

    /// 参数行与 Android AudioCue.paramsLine() 逐字相同
    @Test func paramsLineMatchesAndroid() {
        let expected: String = "CUE=v1 CUE_D_VOC=0.0100 CUE_D_SP=0.7000 CUE_B_VOC=0.0500 CUE_B_SP=0.2000 "
            + "CUE_B_IMP=0.1000 CUE_B_MUS=0.3000 CUE_B_SIL=0.3000 CUE_P_VOC=0.3000 CUE_P_IMP=0.2000"
        #expect(AudioCue.paramsLine() == expected)
    }
}
