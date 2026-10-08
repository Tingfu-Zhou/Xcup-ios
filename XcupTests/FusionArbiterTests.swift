//
//  FusionArbiterTests.swift
//  XcupTests
//
//  对应 Android FusionArbiterTest.java。最重要的是 matchesAndroidGolden：Android、iOS、bench/tools/fusion_lab.py
//  三端用同一份 arbiter_golden.csv（python3 bench/tools/fusion_lab.py golden 生成，取自 Android
//  app/src/test/resources/fusion/），逐 tick 校验动作和原因一致；两边不一致，Android 离线评估出的效果在 iOS 上就不成立。
//  Android 改了规则或参数会重新生成这个文件，换上新文件再跑一遍即可。
//

import Foundation
import Testing
@testable import Xcup

private final class BundleToken {}

struct FusionArbiterTests {

    static func goldenURL() -> URL? {
        if let url = Bundle(for: BundleToken.self).url(forResource: "arbiter_golden", withExtension: "csv") {
            return url
        }
        let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("arbiter_golden.csv")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    /// 逐行回放对拍数据，动作和原因都要一致；第一处不一致就停下，报出行号和期望值。
    @Test func matchesAndroidGolden() throws {
        let url = try #require(Self.goldenURL(), "缺少测试资源 arbiter_golden.csv")
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        try #require(!lines.isEmpty, "arbiter_golden.csv 是空的")
        #expect(lines.removeFirst()
                == "reset,now,v_action,v_conf,v_ts,a_action,a_conf,a_ts,motor_on,exp_action,exp_reason")
        let arb = FusionArbiter()
        var n = 0
        for (k, line) in lines.enumerated() {
            let row = "golden 第 \(k + 2) 行"
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            try #require(f.count == 11, "\(row) 列数不对：\(line)")
            if !f[0].isEmpty {                                   // reset 列：<ms> 或 <ms>+<预热ms>
                let p = f[0].split(separator: "+", omittingEmptySubsequences: false).map(String.init)
                let at = try #require(Int64(p[0]), "\(row) reset 列：\(f[0])")
                var warmup: Int64 = 0
                if p.count > 1 { warmup = try #require(Int64(p[1]), "\(row) reset 列：\(f[0])") }
                arb.reset(at, warmupMs: warmup)
            }
            let now = try #require(Int64(f[1]), "\(row) now")
            let vConf = try #require(Float(f[3]), "\(row) v_conf")
            let vTs = try #require(Int64(f[4]), "\(row) v_ts")
            let aConf = try #require(Float(f[6]), "\(row) a_conf")
            let aTs = try #require(Int64(f[7]), "\(row) a_ts")
            let got = arb.decide(now: now,
                                 vAction: f[2], vConf: vConf, vTs: vTs,
                                 aAction: f[5], aConf: aConf, aTs: aTs,
                                 motorOn: f[8] == "1")
            try #require(got == f[9] && arb.lastReason == f[10],
                         "\(row)：期望 \(f[9])/\(f[10])，实际 \(got)/\(arb.lastReason)")
            n += 1
        }
        #expect(n >= 5000, "对拍数据太少：\(n)")
    }

    private static let T: Int64 = 1_700_000_000_000

    /// 维持时主动交 "do"：有支持就不会交 ""，蓝牙状态机里没执行的停转计时会被取消。
    @Test func holdReassertsDo() {
        let T = Self.T
        let arb = FusionArbiter()
        arb.reset(T)
        // 音频 4 个结果里 3 个 "转"：有支持，交 do
        for i in 0..<3 {
            let t = T + 1000 * Int64(i + 1)
            _ = arb.decide(now: t, vAction: "Noise", vConf: 0.99, vTs: t - 10,
                           aAction: "do", aConf: 0.8, aTs: t - 5, motorOn: true)
        }
        let a = arb.decide(now: T + 4000, vAction: "Noise", vConf: 0.99, vTs: T + 3990,
                           aAction: "Noise", aConf: 0.9, aTs: T + 3995, motorOn: true)
        #expect(a == "do")
        #expect(arb.lastReason == FusionArbiter.rHoldAudio)
        // 再来一个 "不转"：4 个里只剩 2 个 "转"，没有支持且有结束证据 -> Noise
        let b = arb.decide(now: T + 5000, vAction: "Noise", vConf: 0.99, vTs: T + 4990,
                           aAction: "Noise", aConf: 0.9, aTs: T + 4995, motorOn: true)
        #expect(b == "Noise")
        #expect(arb.lastReason == FusionArbiter.rStopNeg)
    }

    /// 同一个结果在多个 tick 里出现只算一次：一个音频结果撑不起"4 个里 3 个"。
    @Test func duplicatesCountOnce() {
        let T = Self.T
        let arb = FusionArbiter()
        arb.reset(T)
        for i in 0..<6 {
            _ = arb.decide(now: T + 500 * Int64(i), vAction: "", vConf: 0, vTs: -1,
                           aAction: "do", aConf: 0.95, aTs: T + 100, motorOn: true)
        }
        let a = arb.decide(now: T + 3000, vAction: "", vConf: 0, vTs: -1,
                           aAction: "do", aConf: 0.95, aTs: T + 100, motorOn: true)
        // 只有 1 个音频结果：不构成支持；这一路结果还不够判断 -> 继续 do（有上限）
        #expect(a == "do")
        #expect(arb.lastReason == FusionArbiter.rWaitSparse)
    }

    /// 刚恢复播放（reset 后马达仍在转）时正好是特写：音频攒够结果之前，视频的"剧情"不能把马达停掉。
    @Test func resumeInCloseUpDoesNotStop() {
        let T = Self.T
        let arb = FusionArbiter()
        arb.reset(T)
        for k in 0..<16 {
            let now = T + 250 + 500 * Int64(k)
            let aTs: Int64 = k >= 2 ? T + 1000 * Int64(k / 2) - 100 : -1
            let g = arb.decide(now: now, vAction: "Noise", vConf: 0.9, vTs: now - 100,
                               aAction: aTs > 0 ? "do" : "", aConf: 0.95, aTs: aTs, motorOn: true)
            #expect(g == "do", "tick \(k) \(arb.lastReason)")
        }
        #expect(arb.lastReason == FusionArbiter.rHoldAudio)
    }

    /// 两路都是"转""不转"交替的强证据：不满足维持条件就不启动，避免每 2 秒开关一次。
    @Test func alternatingStrongEvidenceDoesNotStart() {
        let T = Self.T
        let arb = FusionArbiter()
        arb.reset(T)
        for k in 0..<40 {
            let now = T + 500 * Int64(k + 1)
            let v = k % 2 == 0 ? "do" : "Noise"
            let a = (k / 2) % 2 == 0 ? "do" : "Noise"
            let g = arb.decide(now: now, vAction: v, vConf: 0.95, vTs: now - 50,
                               aAction: a, aConf: 0.95, aTs: now - 100 - 500 * Int64(k % 2), motorOn: false)
            #expect(g != "do", "tick \(k) \(arb.lastReason)")
        }
    }

    /// 墙钟往回跳：自动清空证据；"未来"的旧结果不记，也不挡住之后的新结果。
    @Test func clockJumpBackResets() {
        let T = Self.T
        let arb = FusionArbiter()
        arb.reset(T)
        for k in 1...4 {
            let t = T + 1000 * Int64(k)
            _ = arb.decide(now: t, vAction: "", vConf: 0, vTs: -1,
                           aAction: "do", aConf: 0.95, aTs: t - 10, motorOn: true)
        }
        #expect(arb.lastReason == FusionArbiter.rHoldAudio)
        let back = T - 60000
        // 跳回 60 秒：旧结果在"未来"
        _ = arb.decide(now: back, vAction: "", vConf: 0, vTs: -1,
                       aAction: "do", aConf: 0.95, aTs: T + 3990, motorOn: true)
        #expect(arb.lastReason == FusionArbiter.rWaitSparse)
        var g = ""
        for k in 1...4 {
            let t = back + 1000 * Int64(k)
            g = arb.decide(now: t, vAction: "Noise", vConf: 0.9, vTs: t - 20,
                           aAction: "Noise", aConf: 0.9, aTs: t - 10, motorOn: true)
        }
        #expect(g == "Noise")
        #expect(arb.lastReason == FusionArbiter.rStopNeg)
    }

    /// 看不清 / 听不清 / 过期时最多再维持 unclearMaxMs，然后停。
    @Test func unclearHoldIsFinite() {
        let T = Self.T
        let arb = FusionArbiter()
        arb.reset(T)
        #expect(arb.decide(now: T, vAction: "", vConf: 0, vTs: -1,
                           aAction: "", aConf: 0, aTs: -1, motorOn: true) == "do")
        #expect(arb.decide(now: T + FusionArbiter.unclearMaxMs - 1, vAction: "", vConf: 0, vTs: -1,
                           aAction: "", aConf: 0, aTs: -1, motorOn: true) == "do")
        #expect(arb.decide(now: T + FusionArbiter.unclearMaxMs, vAction: "", vConf: 0, vTs: -1,
                           aAction: "", aConf: 0, aTs: -1, motorOn: true) == "Noise")
        #expect(arb.lastReason == FusionArbiter.rStopUnclear)
    }

    /// reset(now) 之后，now 之前产出的结果（seek 前的旧结果）不再算证据。
    @Test func resetDropsOlderResults() {
        let T = Self.T
        let arb = FusionArbiter()
        arb.reset(T)
        let a = arb.decide(now: T + 100, vAction: "do", vConf: 0.99, vTs: T - 50,
                           aAction: "do", aConf: 0.99, aTs: T - 20, motorOn: false)
        #expect(a == "")
        #expect(arb.lastReason == FusionArbiter.rOffWait)
        let b = arb.decide(now: T + 600, vAction: "do", vConf: 0.99, vTs: T + 500,
                           aAction: "do", aConf: 0.99, aTs: T + 550, motorOn: false)
        #expect(b == "")                                   // 视频强"转"只有 1 个，还不够
        let c = arb.decide(now: T + 1100, vAction: "do", vConf: 0.99, vTs: T + 1000,
                           aAction: "do", aConf: 0.99, aTs: T + 550, motorOn: false)
        #expect(c == "do")
        #expect(arb.lastReason == FusionArbiter.rStartBoth)
    }

    /// 音频兜底零容忍：9 秒内夹一个 unclear 就不启动。
    @Test func audioValveNeedsUninterruptedPositives() {
        let T = Self.T
        let arb = FusionArbiter()
        arb.reset(T)
        var last = ""
        for i in 0..<4 {
            let t = T + 1000 * Int64(i + 1)
            last = arb.decide(now: t, vAction: "Noise", vConf: 0.99, vTs: t - 1,
                              aAction: i == 1 ? "" : "do", aConf: 0.7, aTs: t, motorOn: false)
        }
        #expect(last == "Noise")
        for i in 4..<14 {
            let t = T + 1000 * Int64(i + 1)
            last = arb.decide(now: t, vAction: "Noise", vConf: 0.99, vTs: t - 1,
                              aAction: "do", aConf: 0.7, aTs: t, motorOn: false)
            if last == "do" { break }
        }
        #expect(last == "do")
        #expect(arb.lastReason == FusionArbiter.rStartAudio)
    }

    /// 暂停时只有"有证据撑着"的 do 才带过暂停：维持 / 启动算，等结果（wait_sparse / wait_unclear）和 reset 之后都不算。
    @Test func lastDoHadEvidenceOnlyForStartAndHold() {
        let T = Self.T
        let arb = FusionArbiter()
        arb.reset(T)
        #expect(!arb.lastDoHadEvidence)
        // 刚 reset，音频只有 1 个结果
        _ = arb.decide(now: T + 500, vAction: "", vConf: 0, vTs: -1,
                       aAction: "do", aConf: 0.95, aTs: T + 400, motorOn: true)
        #expect(arb.lastReason == FusionArbiter.rWaitSparse)
        #expect(!arb.lastDoHadEvidence)
        for k in 1...4 {
            _ = arb.decide(now: T + 500 + 1000 * Int64(k), vAction: "", vConf: 0, vTs: -1,
                           aAction: "do", aConf: 0.95, aTs: T + 400 + 1000 * Int64(k), motorOn: true)
        }
        #expect(arb.lastReason == FusionArbiter.rHoldAudio)
        #expect(arb.lastDoHadEvidence)
        arb.reset(T + 10000)
        #expect(!arb.lastDoHadEvidence)
        #expect(arb.decide(now: T + 10000 + FusionArbiter.unclearMaxMs - 1, vAction: "", vConf: 0, vTs: -1,
                           aAction: "", aConf: 0, aTs: -1, motorOn: true) == "do")
        #expect(!arb.lastDoHadEvidence)                    // wait_sparse / wait_unclear
    }
}
