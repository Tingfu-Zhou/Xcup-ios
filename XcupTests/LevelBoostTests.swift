//
//  LevelBoostTests.swift
//  XcupTests
//
//  对应 Android LevelBoostTest.java（7 个用例一一对应），另加设置读取（LevelBoostSettings）和单调时钟两条：
//  计时只算在跑的时间、播完 / 退出清零、加档不唤醒停着的马达并钳到最高档。
//

import Foundation
import Testing
@testable import Xcup

struct LevelBoostTests {

    private static let MIN: Int64 = 60_000
    private static let T: Int64 = 5_000_000   // 任意起点（单调时钟）

    @Test func boostsOnceDelayReached() {
        let (MIN, T) = (Self.MIN, Self.T)
        let b = LevelBoost(enabled: true, delayMin: 10, levels: 2)
        b.resume(at: T)
        #expect(b.boost(at: T) == 0)
        #expect(b.boost(at: T + 10 * MIN - 1) == 0)
        #expect(b.boost(at: T + 10 * MIN) == 2)
        #expect(b.boost(at: T + 90 * MIN) == 2)    // 到点后一直加，直到 reset
    }

    @Test func disabledNeverBoosts() {
        let (MIN, T) = (Self.MIN, Self.T)
        let b = LevelBoost(enabled: false, delayMin: 1, levels: 2)
        b.resume(at: T)
        #expect(b.boost(at: T + 120 * MIN) == 0)
    }

    @Test func pausedTimeDoesNotCount() {
        let (MIN, T) = (Self.MIN, Self.T)
        let b = LevelBoost(enabled: true, delayMin: 10, levels: 1)
        b.resume(at: T)
        b.pause(at: T + 6 * MIN)                        // 播了 6 分钟后暂停
        #expect(b.boost(at: T + 30 * MIN) == 0)         // 暂停期间不计时
        b.resume(at: T + 30 * MIN)
        #expect(b.boost(at: T + 34 * MIN - 1) == 0)
        #expect(b.boost(at: T + 34 * MIN) == 1)         // 6 + 4 = 10 分钟
    }

    /// 融合循环每个 tick 都调 resume（在跑）或 pause（暂停中）：重复调用不能重新起表，也不能重复累计
    @Test func repeatedResumeAndPauseAreIdempotent() {
        let (MIN, T) = (Self.MIN, Self.T)
        let b = LevelBoost(enabled: true, delayMin: 1, levels: 1)
        b.resume(at: T)
        b.resume(at: T + 30_000)
        #expect(b.elapsedMs(at: T + MIN) == MIN)
        b.pause(at: T + MIN)
        b.pause(at: T + 2 * MIN)
        #expect(b.elapsedMs(at: T + 5 * MIN) == MIN)
    }

    @Test func resetStartsOver() {
        let (MIN, T) = (Self.MIN, Self.T)
        let b = LevelBoost(enabled: true, delayMin: 1, levels: 2)
        b.resume(at: T)
        #expect(b.boost(at: T + MIN) == 2)
        b.reset()                                       // 视频播完 / 退出模式
        #expect(b.boost(at: T + 2 * MIN) == 0)          // 清零后停表，等下一次 resume
        b.resume(at: T + 3 * MIN)
        #expect(b.boost(at: T + 4 * MIN - 1) == 0)
        #expect(b.boost(at: T + 4 * MIN) == 2)
    }

    @Test func applyKeepsStopAndClampsToMax() {
        #expect(LevelBoost.apply(level: 0, boost: 2, maxLevel: 10) == 0)     // 0 档（停）不加
        #expect(LevelBoost.apply(level: 5, boost: 0, maxLevel: 10) == 5)
        #expect(LevelBoost.apply(level: 5, boost: 1, maxLevel: 10) == 6)
        #expect(LevelBoost.apply(level: 8, boost: 2, maxLevel: 10) == 10)    // 分析最高 8 档，+2 正好到 10
        #expect(LevelBoost.apply(level: 9, boost: 2, maxLevel: 10) == 10)    // 超过最高档的钳到最高档
    }

    @Test func settingsAreClamped() {
        let (MIN, T) = (Self.MIN, Self.T)
        let b = LevelBoost(enabled: true, delayMin: 0, levels: 5)     // 存储里的坏值
        b.resume(at: T)
        #expect(b.boost(at: T + MIN - 1) == 0)                       // 最短 1 分钟
        #expect(b.boost(at: T + MIN) == 2)                           // 最多 +2
        #expect(b.paramsLine == "BOOST=+2@1min")
        #expect(LevelBoost(enabled: false, delayMin: 10, levels: 1).paramsLine == "BOOST=off")
        #expect(LevelBoost.clampDelayMin(999) == LevelBoost.maxDelayMin)
        #expect(LevelBoost.clampLevels(-1) == LevelBoost.minLevels)
    }

    /// 没存过时关闭（打开后默认 10 分钟、+1 档）；存过的值照读，坏值钳到范围内
    @Test func settingsLoadDefaultsAndStoredValues() throws {
        let (MIN, T) = (Self.MIN, Self.T)
        let suite = "LevelBoostTests.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }

        let off = LevelBoostSettings.load(from: d)
        off.resume(at: T)
        #expect(off.boost(at: T + 120 * MIN) == 0)
        #expect(off.paramsLine == "BOOST=off")
        #expect(LevelBoostSettings.delayMin(from: d) == LevelBoost.defaultDelayMin)
        #expect(LevelBoostSettings.levels(from: d) == LevelBoost.defaultLevels)

        d.set(true, forKey: LevelBoostSettings.enabledKey)
        #expect(LevelBoostSettings.load(from: d).paramsLine == "BOOST=+1@10min")

        d.set(3, forKey: LevelBoostSettings.delayMinKey)
        d.set(2, forKey: LevelBoostSettings.levelsKey)
        let on = LevelBoostSettings.load(from: d)
        #expect(on.paramsLine == "BOOST=+2@3min")
        on.resume(at: T)
        #expect(on.boost(at: T + 3 * MIN - 1) == 0)
        #expect(on.boost(at: T + 3 * MIN) == 2)

        d.set(0, forKey: LevelBoostSettings.delayMinKey)
        d.set(9, forKey: LevelBoostSettings.levelsKey)
        #expect(LevelBoostSettings.delayMin(from: d) == LevelBoost.minDelayMin)
        #expect(LevelBoostSettings.levels(from: d) == LevelBoost.maxLevels)
    }

    @Test func monotonicClockAdvances() {
        let a = monotonicMs()
        Thread.sleep(forTimeInterval: 0.02)
        #expect(monotonicMs() - a >= 15)
    }
}
