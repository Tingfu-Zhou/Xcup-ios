//
//  FusionArbiter.swift
//  Xcup
//
//  逐行移植自 Android FusionArbiter.java：v1 对应 xcup-android 提交 afd41df … 3030ade（2026-10-07），
//  v2（音频线索）对应 6b50dd1（2026-10-11）。两端由 XcupTests/FusionArbiterTests.swift 用同一份
//  arbiter_golden.csv 逐 tick 对拍。改规则或参数必须三处同步：Android FusionArbiter.java、
//  bench/tools/fusion_lab.py（ARB_DEFAULTS）、这里，然后由 Android 端重新生成对拍数据，换进 XcupTests 再跑一遍。
//

import Foundation

/// 融合仲裁：把"启动 / 维持 / 停止"分开判断，决定每个融合 tick 交给蓝牙状态机什么动作。
/// 2026-10-07 起替代原来的平滑投票 smoothedFusion 和启动仲裁 applyDoStartGate（都已删除），离线模式与在线模式共用。
///
/// **为什么改**（Android bench 7 部片）：原融合把"音频更可信"写死（投票权重 1.2 / 0.8，音频 ≥0.75 直接启动）。
/// 动作中 22 次误停全部是"只有一个模态说剧情"：视频遇到特写 / 遮挡判剧情时，音频一个 1 秒的 noise 就让马达停；
/// 或者视频稳稳判动作、音频听不到目标声音，马达也停。剧情里的误转则主要来自音频单独判"转"。
///
/// **证据**一律按"新推理结果"计数：同一个结果在多个 500ms tick 里重复出现只算一次（按结果时间戳去重），
/// 产出时已超过 2 秒的结果不记。维持 / 停止按"最近 n 个结果"计数，手机推理慢一些也不会失效。
///
/// **启动**（马达不转），满足任一条才交 "do"：
/// 1. 两路佐证：最近 `cWinMs` 内视频强"转"（置信度 ≥ `vFloor`）≥ `cV` 个，且音频强"转"（≥ `aFloor`）≥ `cA` 个，
///    并且此刻满足比"维持"更严一档的条件（视频"转"占比 ≥ `startVConsPct`%，或音频最近 `maN` 个里 ≥ `startMaK` 个"转"）。
///    启动比维持严（迟滞），证据在维持门槛上下晃时马达不会每几秒开关一次。
/// 2. 音频兜底：最近 `zWinMs` 内的音频结果至少 `zN` 个，而且**全部**判"转"（夹一个"不转"或 unclear 就不算）。
///    这条不看视频，特写 / 遮挡时也能启动；剧情里的音频常是"转"里夹"不转"，零容忍正好把它挡住。
///
/// **音频线索**（v2，2026-10-11，`AudioCue`）：每个音频结果带一个 YAMNet 判的线索，启动阶段多两条规则：
/// 3. 视频单独启动：音频最近 `a1N` 个结果都"听不出"（音乐 / 安静 / 听不出），而且最近 `cWinMs` 内视频强"转"
///    ≥ `a1CV` 个、"转"占比 ≥ `a1ConsPct`%（比两路佐证更严）。动作被背景音乐盖住时分类头一直判"不转"，
///    原来只能干等。原因记 start_video。
/// 4. 对白否决：视频最近 `bvN` 个结果都是置信度 ≥ `bvConf` 的"剧情"时，音频里线索为对白的"转"在第 1、2 条里
///    一律按 unclear 算。剧情对白常被分类头判成"转"、靠音频兜底误启动；边说话边口交时视频拿不准，不会否决。
///    维持和停止不受线索影响。
///
/// 线索未知（`AudioCue.unknown`：没有分数）时这两条都不生效，行为与 v1 完全相同。
///
/// 都不满足时：最近 `negWinMs` 内有"不转"结果交 "Noise"，否则交 ""（不驱动状态机）。
///
/// **维持**（马达在转），任一模态有支持就交 "do"：
/// - 音频：最近 `maN` 个音频结果（都在 `mMaxMs` 内）里"转" ≥ `maK` 个（能容忍一个 1 秒的 noise，一个孤立的"转"撑不住）。
/// - 视频：最近 `mvN` 个视频结果里"转" ≥ `mvK` 个，且最近 `consWinMs` 内"转"的占比 ≥ `vConsPct`%（一致性检查）。
///
/// 维持时**主动交 "do"** 而不是 ""：蓝牙状态机里尚未执行的停转计时会被取消（新动作和待确认动作不同就重新计时），
/// 之后的 Noise 必须重新稳定 1 秒才会停；如果交 ""，旧计时会保留下来，下一次 Noise 立刻停转。
///
/// **停止**（马达在转、两路都没有支持）：
/// - reset（seek / 恢复播放）之后的 `coldMs` 内，某一路的新结果还不够 `maN` / `mvN` 个，先继续交 "do" 等新结果
///   （否则恢复播放时恰好在特写，视频一个"剧情"就会在音频攒够结果之前把马达停掉）。
/// - 最近 `negWinMs` 内有任一"不转"结果，交 "Noise"（之后照旧要状态机稳定 1 秒 + 最短驻留 2 秒）。
/// - 看不清 / 听不清 / 结果过期时继续交 "do"，从最后一次有支持算起最多 `unclearMaxMs`，然后交 "Noise"。
///
/// 墙钟往回跳时账本里的时间戳都会变成"未来"，这里会自动 reset。
///
/// 线程：只在融合线程（主线程）调用，不加锁。
final class FusionArbiter {

    // MARK: - 参数（与 Android FusionArbiter.java、fusion_lab.py 的 ARB_DEFAULTS 一致）
    //
    // 这些参数按 Android 的推理节奏定的：视频约 0.5~0.6 秒一个结果，音频 1 秒一个结果（iOS 两条分析循环与之相同）。
    // 节奏差得太多时要重新评估，例如音频慢到 2 秒以上一个结果，9 秒兜底就凑不齐 4 个结果。

    /// 结果产出后超过这么久就不再记账（与融合循环的 2 秒新鲜度过滤相同）
    static let maxAgeMs: Int64 = 2000
    /// 两路佐证启动时，视频 / 音频"强转"结果的置信度下限（32 位 Float，与 Android float 比较结果一致）
    static let vFloor: Float = 0.85
    static let aFloor: Float = 0.90
    /// 启动·两路佐证：窗口、需要的视频强"转"个数、需要的音频强"转"个数
    static let cWinMs: Int64 = 3000
    static let cV = 2
    static let cA = 1
    /// 启动·音频兜底：zWinMs 内的音频结果至少 zN 个，且全部判"转"
    static let zWinMs: Int64 = 9000
    static let zN = 4
    /// 维持：音频看最近 maN 个结果（≥ maK 个"转"），视频看最近 mvN 个结果（≥ mvK 个"转"），都须在 mMaxMs 内
    static let maN = 4
    static let maK = 3
    static let mvN = 4
    static let mvK = 2
    static let mMaxMs: Int64 = 12000        // 给结果来得慢的手机留余量：音频 3 秒一个时，最近 4 个仍落在窗口内
    /// 维持·视频一致性：consWinMs 内视频结果里"转"的占比下限（百分数，用整数运算，避免两端浮点边界不一致）
    static let consWinMs: Int64 = 6000
    static let vConsPct = 70
    /// 停止：多久内出现过"不转"结果，算有结束证据
    static let negWinMs: Int64 = 4000
    /// 停止：既没有支持、也没有结束证据（看不清 / 听不清 / 过期）时，最多再维持多久
    static let unclearMaxMs: Int64 = 6000
    /// 停止：reset 之后多久内，结果还不够判断的一路可以让马达先等（只管刚 seek / 恢复播放的冷启动）
    static let coldMs: Int64 = 6000
    /// 启动·两路佐证还要满足的"更严一档"的维持条件（迟滞）：视频"转"占比、音频最近 maN 个里"转"的个数
    static let startVConsPct = 80
    static let startMaK = 4
    /// 启动·视频单独启动（v2）：音频最近 a1N 个结果都听不出，视频 cWinMs 内强"转" ≥ a1CV 个、占比 ≥ a1ConsPct%
    static let a1N = 4
    static let a1CV = 3
    static let a1ConsPct = 90
    /// 启动·对白否决（v2）：视频最近 bvN 个结果都是置信度 ≥ bvConf 的"剧情"时，对白线索的音频"转"不算启动证据
    static let bvN = 4
    static let bvConf: Float = 0.90
    /// 静音暂停后恢复时，丢掉恢复后这么久内产出的结果（模型窗口里还混着暂停前的静音）。音频窗口 2 秒
    static let silenceResumeWarmupMs: Int64 = 2000
    /// 账本只需保留最长窗口（zWinMs / mMaxMs）以内的结果，这里留足余量
    static let keepMs: Int64 = 20000

    // MARK: - 本 tick 输出的原因（Android 评测 CSV 的 arb 列）

    static let rStartBoth = "start_both"
    static let rStartAudio = "start_audio"
    static let rStartVideo = "start_video"
    static let rOffNeg = "off_neg"
    static let rOffWait = "off_wait"
    static let rHoldBoth = "hold_both"
    static let rHoldVideo = "hold_video"
    static let rHoldAudio = "hold_audio"
    static let rStopNeg = "stop_neg"
    static let rStopUnclear = "stop_unclear"
    static let rWaitUnclear = "wait_unclear"
    static let rWaitSparse = "wait_sparse"

    /// 结果产出时刻与融合 tick 共用的时钟：墙钟毫秒，与 Android 的 System.currentTimeMillis() 一致。
    /// 分析线程给结果打时间戳、融合循环取 now、2 秒新鲜度过滤都必须用它，不能混用别的时钟。
    static func nowMs() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// 一次模型推理的判定结果。分析线程把它作为**一个**对象整体发布，融合线程每 tick 只读一次：
    /// 动作串、置信度、产出时刻（音频还有线索）必须来自同一次推理，否则按时间戳去重时会把旧动作记在新结果名下、
    /// 再把真正的新结果当成重复丢掉。
    struct Result {
        let action: String      // "do" / "Noise" / ""（unclear）
        let conf: Float
        let tsMs: Int64         // 产出时刻（FusionArbiter.nowMs()）
        let cue: Int            // 音频线索（AudioCue.*），视频结果为 AudioCue.unknown

        init(action: String, conf: Float, tsMs: Int64, cue: Int = AudioCue.unknown) {
            self.action = action
            self.conf = conf
            self.tsMs = tsMs
            self.cue = cue
        }
    }

    /// 动作串 -> 类别：1 = "转"(do)，-1 = "不转"(Noise)，0 = unclear
    static func kind(of action: String) -> Int {
        if action == "do" { return 1 }
        if action == "Noise" { return -1 }
        return 0
    }

    /// 一个模态的"新结果"账本：环形缓冲，按结果时间戳去重。
    struct Ledger {
        static let cap = 128                     // 视频最多约 2 个/秒 × keepMs 20 秒，留足余量
        private var ts = [Int64](repeating: 0, count: Ledger.cap)
        private var kinds = [Int](repeating: 0, count: Ledger.cap)
        private var confs = [Float](repeating: 0, count: Ledger.cap)
        private var dialog = [Bool](repeating: false, count: Ledger.cap)   // 音频线索是对白
        private var uninf = [Bool](repeating: false, count: Ledger.cap)    // 音频线索是听不出（音乐 / 安静 / 听不出）
        private var head = 0                     // 最旧一条的下标
        private var size = 0
        private var lastTs = Int64.min
        private var minTs = Int64.min

        /// 清空；产出时刻早于 minTs 的结果（seek / 重置之前的旧结果）以后也不再记。
        mutating func reset(minTs: Int64) {
            head = 0
            size = 0
            lastTs = Int64.min
            self.minTs = minTs
        }

        /// 每个 tick 喂一次当前最新结果；resultTs <= 0 表示还没有结果。返回是否记了一条新结果。
        /// 产出时刻晚于 now 的结果（只会在墙钟往回跳之后出现）不记、也不推进去重游标，免得挡住之后的新结果；
        /// reset 之前产出的、产出时已过期的结果不记，但要推进去重游标。cue 是该结果的音频线索（视频传 unknown）。
        @discardableResult
        mutating func feed(_ action: String, _ conf: Float, _ resultTs: Int64, _ now: Int64, _ cue: Int) -> Bool {
            if resultTs <= 0 || resultTs > now || resultTs <= lastTs { return false }
            lastTs = resultTs
            if resultTs < minTs || now - resultTs > FusionArbiter.maxAgeMs { return false }
            if size == Ledger.cap {              // 正常到不了；万一满了丢最旧的
                head = (head + 1) % Ledger.cap
                size -= 1
            }
            let i = (head + size) % Ledger.cap
            ts[i] = resultTs
            kinds[i] = FusionArbiter.kind(of: action)
            confs[i] = conf
            dialog[i] = cue == AudioCue.dialog
            uninf[i] = AudioCue.uninformative(cue)
            size += 1
            let lim = now - FusionArbiter.keepMs
            while size > 0 && ts[head] <= lim {
                head = (head + 1) % Ledger.cap
                size -= 1
            }
            return true
        }

        /// 第 k 新的一条（k = 0 为最新）
        private func idx(_ k: Int) -> Int {
            return (head + size - 1 - k) % Ledger.cap
        }

        /// (now - win, now] 内类别为 kind 且置信度 ≥ minConf 的结果数；
        /// vetoDialog 时线索为对白的"转"按 unclear 算（不计入 kind = 1）
        func count(_ now: Int64, _ win: Int64, _ kind: Int, _ minConf: Float, _ vetoDialog: Bool = false) -> Int {
            let lo = now - win
            var n = 0
            for k in 0..<size {
                let i = idx(k)
                if ts[i] <= lo { break }
                if kinds[i] == kind && confs[i] >= minConf && !(vetoDialog && kind == 1 && dialog[i]) { n += 1 }
            }
            return n
        }

        /// (now - win, now] 内的结果总数
        func total(_ now: Int64, _ win: Int64) -> Int {
            let lo = now - win
            var n = 0
            for k in 0..<size {
                if ts[idx(k)] <= lo { break }
                n += 1
            }
            return n
        }

        /// 最近 n 个结果里落在 (now - maxWin, now] 内的有几个（≤ n）
        func recent(_ now: Int64, _ n: Int, _ maxWin: Int64) -> Int {
            let lo = now - maxWin
            var got = 0
            for k in 0..<min(size, n) {
                if ts[idx(k)] <= lo { break }
                got += 1
            }
            return got
        }

        /// 最近 n 个结果（须在 (now - maxWin, now] 内）里判"转"的个数；vetoDialog 时线索为对白的"转"不算
        func lastNPos(_ now: Int64, _ n: Int, _ maxWin: Int64, _ vetoDialog: Bool = false) -> Int {
            let lo = now - maxWin
            var pos = 0
            for k in 0..<min(size, n) {
                let i = idx(k)
                if ts[i] <= lo { break }
                if kinds[i] == 1 && !(vetoDialog && dialog[i]) { pos += 1 }
            }
            return pos
        }

        /// 最近 n 个结果都在 (now - maxWin, now] 内，而且线索全是听不出。不足 n 个时为 false
        func lastNUninformative(_ now: Int64, _ n: Int, _ maxWin: Int64) -> Bool {
            if size < n { return false }
            let lo = now - maxWin
            for k in 0..<n {
                let i = idx(k)
                if ts[i] <= lo || !uninf[i] { return false }
            }
            return true
        }

        /// 最近 n 个结果都在 (now - maxWin, now] 内，而且全是置信度 ≥ minConf 的"不转"。不足 n 个时为 false
        func lastNNegative(_ now: Int64, _ n: Int, _ maxWin: Int64, _ minConf: Float) -> Bool {
            if size < n { return false }
            let lo = now - maxWin
            for k in 0..<n {
                let i = idx(k)
                if ts[i] <= lo || kinds[i] != -1 || confs[i] < minConf { return false }
            }
            return true
        }
    }

    private var video = Ledger()
    private var audio = Ledger()
    private var lastSupportMs: Int64 = -1        // 维持阶段最后一次有支持的时刻；马达不转时为 -1
    private var prevNowMs = Int64.min            // Int64.min = 没有；做减法前先判断，Swift 整数溢出会直接崩溃
    private var resetAtMs = Int64.min            // 上次 reset 的时刻（冷启动窗口从这里算）

    /// 本 tick 输出的原因
    private(set) var lastReason = ""

    /// 上一个 tick 交 "do" 是不是有证据撑着（启动 / 维持），而不是在"等结果"（wait_sparse / wait_unclear）。
    /// 暂停时用它决定马达要不要带过暂停：只是在等结果的 "do" 不能带过去。
    var lastDoHadEvidence: Bool {
        return lastReason.hasPrefix("start_") || lastReason.hasPrefix("hold_")
    }

    /// seek、暂停后恢复时调用：清空证据，nowMs + warmupMs 之前产出的结果以后都不算。
    /// 静音暂停后恢复时 warmupMs = silenceResumeWarmupMs：那时模型窗口里还有暂停前的静音，头一两个结果不可信
    /// （音频兜底启动要求窗口内全是"转"，一个陈旧的"不转"就能把启动拖后 9 秒）。
    func reset(_ nowMs: Int64, warmupMs: Int64 = 0) {
        video.reset(minTs: nowMs + warmupMs)
        audio.reset(minTs: nowMs + warmupMs)
        lastSupportMs = -1
        prevNowMs = Int64.min
        resetAtMs = nowMs
        lastReason = ""
    }

    /// 每个融合 tick 调一次。
    /// - Parameters:
    ///   - now: 本 tick 的时刻（FusionArbiter.nowMs()，与结果时间戳同一个时钟）
    ///   - vAction: 视频动作串（"do" / "Noise" / ""，已按 2 秒新鲜度过滤）
    ///   - vConf: 视频置信度
    ///   - vTs: 该视频结果的产出时刻，还没有结果传 -1（过期的结果照样传，账本自己去重 / 丢弃）
    ///   - aCue: 该音频结果的线索（AudioCue.*），与 aAction / aConf / aTs 来自同一个结果对象；没有分数传
    ///     AudioCue.unknown（省略时也是 unknown，行为与 v1 相同）。音频结果过期时动作串清空，线索照样传：
    ///     账本只在记新结果时记线索，过期的结果本来就不记
    ///   - motorOn: 蓝牙状态机当前是否在转（isSexAction(currentBluetoothState)），必须在 updateBluetoothState 之前取
    /// - Returns: "do" / "Noise" / ""（"" = 本 tick 不驱动蓝牙状态机；马达在转时不会返回 ""）
    func decide(now: Int64,
                vAction: String, vConf: Float, vTs: Int64,
                aAction: String, aConf: Float, aTs: Int64,
                aCue: Int = AudioCue.unknown,
                motorOn: Bool) -> String {
        if prevNowMs != Int64.min && now < prevNowMs { reset(now) }   // 墙钟往回跳
        prevNowMs = now
        video.feed(vAction, vConf, vTs, now, AudioCue.unknown)
        audio.feed(aAction, aConf, aTs, now, aCue)

        if !motorOn {
            lastSupportMs = -1
            // 对白否决：视频确定是剧情时，对白线索的音频"转"不算启动证据
            let veto = video.lastNNegative(now, Self.bvN, Self.mMaxMs, Self.bvConf)
            if video.count(now, Self.cWinMs, 1, Self.vFloor) >= Self.cV
                && audio.count(now, Self.cWinMs, 1, Self.aFloor, veto) >= Self.cA
                && (videoSupport(now, Self.startVConsPct)
                    || audio.lastNPos(now, Self.maN, Self.mMaxMs, veto) >= Self.startMaK) {
                lastReason = Self.rStartBoth
                return "do"
            }
            let n = audio.total(now, Self.zWinMs)
            if n >= Self.zN && audio.count(now, Self.zWinMs, 1, 0, veto) == n {
                lastReason = Self.rStartAudio
                return "do"
            }
            // 视频单独启动：音频连续听不出（被音乐盖住 / 安静），视频又很确定
            if audio.lastNUninformative(now, Self.a1N, Self.mMaxMs)
                && video.count(now, Self.cWinMs, 1, Self.vFloor) >= Self.a1CV
                && videoSupport(now, Self.a1ConsPct) {
                lastReason = Self.rStartVideo
                return "do"
            }
            if hasNeg(now) {
                lastReason = Self.rOffNeg
                return "Noise"
            }
            lastReason = Self.rOffWait
            return ""
        }

        if lastSupportMs < 0 { lastSupportMs = now }
        let sa = audio.lastNPos(now, Self.maN, Self.mMaxMs) >= Self.maK
        let sv = videoSupport(now, Self.vConsPct)
        if sv || sa {
            lastSupportMs = now
            lastReason = (sv && sa) ? Self.rHoldBoth : (sv ? Self.rHoldVideo : Self.rHoldAudio)
            return "do"
        }
        let waiting = now - lastSupportMs < Self.unclearMaxMs
        let cold = resetAtMs != Int64.min && now - resetAtMs < Self.coldMs   // 先判哨兵，避免溢出
        if waiting && cold
            && (audio.recent(now, Self.maN, Self.mMaxMs) < Self.maN
                || video.recent(now, Self.mvN, Self.mMaxMs) < Self.mvN) {
            lastReason = Self.rWaitSparse
            return "do"
        }
        if hasNeg(now) {
            lastReason = Self.rStopNeg
            return "Noise"
        }
        if !waiting {
            lastReason = Self.rStopUnclear
            return "Noise"
        }
        lastReason = Self.rWaitUnclear
        return "do"
    }

    /// 视频支持：最近 mvN 个结果里"转" ≥ mvK 个，且 consWinMs 内"转"占比 ≥ consPct%（整数运算）
    private func videoSupport(_ now: Int64, _ consPct: Int) -> Bool {
        if video.lastNPos(now, Self.mvN, Self.mMaxMs) < Self.mvK { return false }
        let n = video.total(now, Self.consWinMs)
        let p = video.count(now, Self.consWinMs, 1, 0)
        return n > 0 && p * 100 >= consPct * n
    }

    private func hasNeg(_ now: Int64) -> Bool {
        return video.count(now, Self.negWinMs, -1, 0) + audio.count(now, Self.negWinMs, -1, 0) > 0
    }

    /// 评测 CSV 的参数行，格式与 Android FusionArbiter.paramsLine() 逐字相同（bench 工具靠 ARB= 选回放规则）。
    /// iOS 目前不写评测 CSV；以后要写时在它后面加一个空格和 AudioCue.paramsLine()。
    static func paramsLine() -> String {
        let items: [String] = [
            "ARB=v2",
            "ARB_V_FLOOR=\(f4(vFloor))", "ARB_A_FLOOR=\(f4(aFloor))",
            "ARB_C_WIN=\(cWinMs)", "ARB_C_V=\(cV)", "ARB_C_A=\(cA)",
            "ARB_Z_WIN=\(zWinMs)", "ARB_Z_N=\(zN)", "ARB_MA_N=\(maN)", "ARB_MA_K=\(maK)",
            "ARB_MV_N=\(mvN)", "ARB_MV_K=\(mvK)", "ARB_M_MAX=\(mMaxMs)",
            "ARB_CONS_WIN=\(consWinMs)", "ARB_V_CONS=\(vConsPct)",
            "ARB_NEG_WIN=\(negWinMs)", "ARB_UNCLEAR_MAX=\(unclearMaxMs)", "ARB_MAX_AGE=\(maxAgeMs)",
            "ARB_KEEP=\(keepMs)", "ARB_COLD=\(coldMs)",
            "ARB_START_V_CONS=\(startVConsPct)", "ARB_START_MA_K=\(startMaK)",
            "ARB_A1_N=\(a1N)", "ARB_A1_CV=\(a1CV)", "ARB_A1_CONS=\(a1ConsPct)",
            "ARB_BV_N=\(bvN)", "ARB_BV_CONF=\(f4(bvConf))",
        ]
        return items.joined(separator: " ")
    }

    /// Float 按 Java 的 %.4f 写四位小数（先转 Double，与 Java 格式化 float 的做法相同）
    private static func f4(_ x: Float) -> String {
        return String(format: "%.4f", Double(x))
    }
}
