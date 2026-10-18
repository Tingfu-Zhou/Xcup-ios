//
//  LevelBoost.swift
//  Xcup
//
//  逐行移植自 Android LevelBoost.java（xcup-android 47ed8a1，2026-10-18），另加设置读取（LevelBoostSettings）
//  和单调时钟（monotonicMs）。XcupTests/LevelBoostTests.swift 与 Android LevelBoostTest 一一对应。
//  改规则必须两边一起改：Android LevelBoost.java、这里。
//

import Foundation

/// 定时加档（模拟临近高潮）：进入离线视频 / 在线录屏模式后，分析累计跑满用户选定的时间，视频分析给出的档位自动再加 1 或 2 档。
/// 在手动电子菜单里开关，默认关闭（设置的读写见 `LevelBoostSettings`、ManualControlView）。
///
/// - 计时只累计融合循环在跑的时间：视频暂停、静音暂停分析时 `pause`，恢复后 `resume` 接着计；seek 不影响。
/// - 退出当前模式、视频播放完毕时 `reset`，从头计时。在线模式看不到视频什么时候播完，连续静音约 10 秒就当播完。
/// - 只加在发给设备的档位上（`apply`）：蓝牙状态机的 currentLevel 仍是分析档位，迟滞、档位确认都不变；
///   lastSentLevel 记的是发出去的档位，所以到点那一刻档位没变也会按状态机原有的节流（距上次发送 ≥ 1600ms）补发一次，
///   不另起一路发送。0 档（停）仍是 0，不会把停着的马达唤醒；其余加上后最高到 10 档。
///   分析链路自己最高只给到 8 档，所以 9、10 档只有加档之后才会用到。没打开时发出去的档位与原来完全相同。
///
/// 纯逻辑、不依赖 UIKit，时钟由调用方传入（毫秒，单调时钟）。每个分析页面一个实例，只在融合循环所在的线程（主线程）调用。
final class LevelBoost {

    /// 开始加档的时间（分钟），与手动菜单里滑杆的范围一致
    static let minDelayMin = 1
    static let maxDelayMin = 30
    static let defaultDelayMin = 10
    /// 加几档
    static let minLevels = 1
    static let maxLevels = 2
    static let defaultLevels = 1

    private let enabled: Bool
    private let delayMin: Int
    private let levels: Int

    private var accumulatedMs: Int64 = 0     // 之前各段（已暂停）累计的时长
    private var runningSinceMs: Int64 = -1   // 这一段开始计时的时刻；-1 = 没在计时

    init(enabled: Bool, delayMin: Int, levels: Int) {
        self.enabled = enabled
        self.delayMin = LevelBoost.clampDelayMin(delayMin)
        self.levels = LevelBoost.clampLevels(levels)
    }

    /// 融合循环在跑：开始或接着计时。已经在计时就什么都不做（每个 tick 都会调）
    func resume(at nowMs: Int64) {
        if runningSinceMs < 0 { runningSinceMs = nowMs }
    }

    /// 分析暂停：停表，已经计的时间保留。没在计时就什么都不做
    func pause(at nowMs: Int64) {
        guard runningSinceMs >= 0 else { return }
        accumulatedMs += max(0, nowMs - runningSinceMs)
        runningSinceMs = -1
    }

    /// 退出模式 / 视频播完：清零并停表，下一次 resume 从头计时
    func reset() {
        accumulatedMs = 0
        runningSinceMs = -1
    }

    /// 累计计了多久（毫秒）
    func elapsedMs(at nowMs: Int64) -> Int64 {
        let running: Int64 = runningSinceMs < 0 ? 0 : max(0, nowMs - runningSinceMs)
        return accumulatedMs + running
    }

    /// 此刻该加几档：没打开或还没到点为 0
    func boost(at nowMs: Int64) -> Int {
        return enabled && elapsedMs(at: nowMs) >= Int64(delayMin) * 60_000 ? levels : 0
    }

    /// Android 评测 CSV 参数行里的一项：BOOST=off，或 BOOST=+<档数>@<分钟>min（iOS 没有评测日志，只在测试里核对两端一致）
    var paramsLine: String {
        return enabled ? "BOOST=+\(levels)@\(delayMin)min" : "BOOST=off"
    }

    /// 把加档加到分析档位上：0 档（停）不加，不会把停着的马达唤醒；其余加上后钳到 maxLevel（协议最高档 BluetoothManager.LEVEL_MAX）
    static func apply(level: Int, boost: Int, maxLevel: Int) -> Int {
        if level <= 0 || boost <= 0 { return level }
        return min(maxLevel, level + boost)
    }

    /// 存储里的旧值 / 坏值钳到 minDelayMin...maxDelayMin
    static func clampDelayMin(_ delayMin: Int) -> Int {
        return max(minDelayMin, min(maxDelayMin, delayMin))
    }

    /// 钳到 minLevels...maxLevels
    static func clampLevels(_ levels: Int) -> Int {
        return max(minLevels, min(maxLevels, levels))
    }
}

/// 「定时加档」设置：手动电子菜单里改，分析页面进入时用 `load` 读一次（所以改了之后下次进入生效）。键名与 Android 相同。
/// 分析和设置都在主 App 里（录屏扩展只负责采集），用 UserDefaults.standard 即可，与变频模式的存法一致。
/// 没存过时为默认值（关闭、10 分钟、+1 档）；读出来的值先钳到范围内。
enum LevelBoostSettings {
    static let enabledKey = "boost_enabled"
    static let delayMinKey = "boost_delay_min"
    static let levelsKey = "boost_levels"

    static func load(from defaults: UserDefaults = .standard) -> LevelBoost {
        return LevelBoost(enabled: enabled(from: defaults),
                          delayMin: delayMin(from: defaults),
                          levels: levels(from: defaults))
    }

    static func enabled(from defaults: UserDefaults = .standard) -> Bool {
        return defaults.bool(forKey: enabledKey)
    }

    static func delayMin(from defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: delayMinKey) != nil else { return LevelBoost.defaultDelayMin }
        return LevelBoost.clampDelayMin(defaults.integer(forKey: delayMinKey))
    }

    static func levels(from defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: levelsKey) != nil else { return LevelBoost.defaultLevels }
        return LevelBoost.clampLevels(defaults.integer(forKey: levelsKey))
    }
}

/// 单调时钟（毫秒），改系统时间不影响。对应 Android 的 SystemClock.elapsedRealtime()
func monotonicMs() -> Int64 {
    return Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
}
