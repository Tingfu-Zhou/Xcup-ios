//
//  PcmResamplerTests.swift
//  XcupTests
//
//  对应 Android PcmResamplerTest.java。最重要的是 matchesPythonGolden：Android、iOS、bench/tools/audio_rescore.py
//  三端用同一份 resampler_golden.txt（python3 bench/tools/audio_rescore.py golden 生成），保证两端喂给模型的音频
//  逐样本一致，同一份融合配置在两端效果相同。
//

import Foundation
import Testing
@testable import Xcup

private final class BundleToken {}

struct PcmResamplerTests {

    /// 与 audio_rescore.golden_pcm / Java goldenPcm 相同的 64 位 LCG 白噪声。
    static func goldenPcm(sampleRate sr: Int, channels ch: Int, frames: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: frames * ch)
        var s = UInt64(bitPattern: Int64(sr) * 31 + Int64(ch))
        for i in 0..<out.count {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            out[i] = Int16(Int64(s >> 48) - 32768)
        }
        return out
    }

    /// 按随机长度（1~1500 帧）分块喂入（模拟 AVAssetReader 一次给一个 buffer），把输出拼起来。
    static func runChunked(_ r: PcmResampler, _ pcm: [Int16], channels ch: Int, seed: UInt64) -> [Float] {
        var rng = seed
        let frames = pcm.count / ch
        var all: [Float] = []
        var f = 0
        while f < frames {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let n = min(frames - f, 1 + Int((rng >> 33) % 1500))
            let o = r.process(pcm, offset: f * ch, frames: n)
            #expect(o.count % 16 == 0, "每次产出都应是 16 的整数倍")
            all.append(contentsOf: o)
            f += n
        }
        #expect(Int64(all.count) == r.outputCount)
        return all
    }

    static func goldenURL() -> URL? {
        if let url = Bundle(for: BundleToken.self).url(forResource: "resampler_golden", withExtension: "txt") {
            return url
        }
        let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("resampler_golden.txt")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    @Test func matchesPythonGolden() throws {
        let url = try #require(Self.goldenURL(), "缺少测试资源 resampler_golden.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        var cases = 0
        var header: [Int]? = nil
        var want: [Float] = []
        func check() {
            guard let h = header else { return }
            let (sr, ch, frames, nOut) = (h[0], h[1], h[2], h[3])
            let tag = "\(sr)Hz/\(ch)ch"
            #expect(want.count == nOut, "\(tag) 对拍数据行数")
            let got = Self.runChunked(PcmResampler(inputRate: sr, channelCount: ch),
                                      Self.goldenPcm(sampleRate: sr, channels: ch, frames: frames),
                                      channels: ch, seed: UInt64(sr + ch))
            #expect(got.count == nOut, "\(tag) 输出个数")
            var worst: Float = 0
            for i in 0..<min(nOut, got.count) { worst = max(worst, abs(got[i] - want[i])) }
            // Swift 与 numpy 的 sin/cos 可能差 1ulp，系数随之差一点点；累加顺序两边相同
            #expect(worst <= 1e-6, "\(tag) 最大误差 \(worst)")
            cases += 1
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: " ")
            if fields.first == "case" {
                check()
                header = fields.dropFirst().compactMap { Int($0) }
                want.removeAll()
                continue
            }
            want.append(contentsOf: fields.compactMap { Float($0) })
        }
        check()
        #expect(cases >= 5, "对拍数据里没有 case")
    }

    @Test func chunkingDoesNotChangeOutput() {
        let pcm = Self.goldenPcm(sampleRate: 44100, channels: 2, frames: 44100)
        let once = PcmResampler(inputRate: 44100, channelCount: 2).process(pcm, frames: pcm.count / 2)
        let chunked = Self.runChunked(PcmResampler(inputRate: 44100, channelCount: 2), pcm, channels: 2, seed: 7)
        #expect(once == chunked, "分块喂入与一次喂入应逐位相同")
    }

    /// 输出第 n 个样本对应输入的 n/16000 秒：1kHz 正弦重采样后应几乎原样（幅度、相位），10kHz 应被滤掉。
    @Test(arguments: [48000, 44100])
    func filterKeepsPassbandAndRemovesAliases(sampleRate sr: Int) {
        let lowRms = Self.toneRms(sampleRate: sr, hz: 1000, checkMatch: true)
        let highRms = Self.toneRms(sampleRate: sr, hz: 10000, checkMatch: false)
        #expect(lowRms < 1e-3, "\(sr)Hz: 1kHz 应基本无损，误差 rms=\(lowRms)")
        #expect(highRms < 0.5 * 1e-3, "\(sr)Hz: 10kHz 应被压到 -60dB 以下，rms=\(highRms)")
    }

    /// checkMatch=true 返回与理想 1kHz 正弦的误差 rms；否则返回输出本身的 rms。幅度 0.5。
    static func toneRms(sampleRate sr: Int, hz: Double, checkMatch: Bool) -> Double {
        let frames = sr                                    // 1 秒
        var pcm = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Int16((16384 * sin(2 * Double.pi * hz * Double(i) / Double(sr))).rounded())
            pcm[2 * i] = v
            pcm[2 * i + 1] = v
        }
        let y = PcmResampler(inputRate: sr, channelCount: 2).process(pcm, frames: frames)
        var acc = 0.0
        var n = 0
        for i in 800..<(y.count - 800) {                   // 跳过开头补零造成的过渡
            let ref = checkMatch ? 0.5 * sin(2 * Double.pi * hz * Double(i) / 16000.0) : 0
            acc += (Double(y[i]) - ref) * (Double(y[i]) - ref)
            n += 1
        }
        return (acc / Double(n)).squareRoot()
    }

    @Test func passthroughAt16kOnlyDownmixes() {
        let r = PcmResampler(inputRate: 16000, channelCount: 2)
        var y = r.process([100, 300, -200, 200, 32767, 32767], frames: 3)
        #expect(y.isEmpty, "不足 16 个不产出")
        y = r.process([Int16](repeating: 0, count: 2 * 13), frames: 13)
        #expect(y.count == 16)
        #expect(y[0] == Float(400) / 65536)
        #expect(y[1] == 0)
        #expect(y[2] == Float(65534) / 65536)
    }

    @Test func monoInputMatchesInt16Path() {
        // Float 来源（广播扩展里的 Float32 音频）走 process(mono:)，与先下混再走 Int16 路径的结果相同
        let pcm = Self.goldenPcm(sampleRate: 48000, channels: 2, frames: 4800)
        let a = PcmResampler(inputRate: 48000, channelCount: 2).process(pcm, frames: 4800)
        let mono = (0..<4800).map { Float(Int32(pcm[2 * $0]) + Int32(pcm[2 * $0 + 1])) / 65536 }
        let b = PcmResampler(inputRate: 48000, channelCount: 1).process(mono: mono)
        #expect(a == b)
    }

    // 广播扩展里有一份逐字拷贝（扩展是独立 target）。只在能读到源码时检查（模拟器 / 本机 swift test）。
    static let sourceCopies: (String, String)? = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard let a = try? String(contentsOf: root.appendingPathComponent("Xcup/Helpers/PcmResampler.swift"), encoding: .utf8),
              let b = try? String(contentsOf: root.appendingPathComponent("XcupBroadcast/PcmResampler.swift"), encoding: .utf8)
        else { return nil }
        return (a, b)
    }()

    @Test(.enabled(if: sourceCopies != nil))
    func broadcastExtensionCopyIsIdentical() {
        #expect(Self.sourceCopies?.0 == Self.sourceCopies?.1,
                "XcupBroadcast/PcmResampler.swift 必须与 Xcup/Helpers/PcmResampler.swift 一致")
    }
}
