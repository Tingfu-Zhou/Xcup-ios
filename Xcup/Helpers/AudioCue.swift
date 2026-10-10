//
//  AudioCue.swift
//  Xcup
//
//  逐行移植自 Android AudioCue.java（xcup-android 提交 6b50dd1，2026-10-11），
//  两端由 XcupTests/AudioCueTests.swift 用同一份 audio_cue_golden.csv 逐位对拍。
//  改分组或阈值必须三处同步：Android AudioCue.java、bench/tools/fusion_lab.py（cue_features / audio_cue）、这里，
//  然后由 Android 端重新生成对拍数据，换进 XcupTests 再跑一遍。
//

import Foundation

/// 音频线索：用 YAMNet 自带的 AudioSet 521 类分数（tflite 第 0 个输出，各帧平均）判断"音频这一刻靠不靠得住"。
/// 每个音频结果判一个线索，交给 `FusionArbiter`：
/// - `dialog` 对白：非语言人声组很低、Speech 高。剧情里分类头这时判"转"多半是把说话当成了动作声；
///   仲裁器在视频确定是剧情时不让它启动马达。
/// - `music` 音乐 / `quiet` 安静 / `blind` 听不出：没有人声、没有撞击 / 口腔声，分类头判什么都不可信
///   （动作被背景音乐盖住时它常判"不转"）。仲裁器在音频连续听不出、视频又很确定时让视频单独启动。
/// - `vocal` 人声 / `impact` 拍打 / `other` 其它：信息量正常，规则不看。
/// - `unknown` 未知：没有分数（模型没有 521 维输出、推理失败）。仲裁器的线索规则都不生效，行为与 v1 相同。
///
/// 类别组按含义定，阈值是 Android 端 2026-10-10/11 在 13 部片上用留一视频和新片检验后定的
/// （bench/README.md 第 6 节，bench/tools/cue_lab.py 的 PRESETS['a1bvid']）。
/// **精度**：分组求和按表中下标顺序做 Float 逐个累加（不要用 vDSP / SIMD，累加顺序不同末位就不同）；
/// 阈值先把 Float 转成 Double 再和 Double 常量比（Java 里是 (double) float 与 double 常量比；
/// 直接按 Float 比时 0.7f 比 0.7 小一点，阈值附近的结果会不同）。
enum AudioCue {

    static let unknown = 0
    static let other = 1
    static let dialog = 2
    static let music = 3
    static let quiet = 4
    static let blind = 5
    static let vocal = 6
    static let impact = 7

    /// 评测 CSV a_cue 列的写法（与 cue_lab.py 的线索名一致），unknown 写空串
    private static let names = ["", "other", "dialog", "music", "quiet", "blind", "vocal", "impact"]
    /// 界面上显示的中文名，unknown 为空串
    private static let labels = ["", "其它", "对白", "音乐", "安静", "听不出", "人声", "拍打"]

    /// AudioSet 类别数（YAMNet 第 0 个输出的最后一维）
    static let nClasses = 521

    // MARK: - 类别组（与 cue_lab.py 的 GROUPS 顺序、内容相同）

    /// 非语言人声核心组：呜咽 21、呻吟 22、叹气 23、哼 33、咕哝 34、呼吸 36、倒吸气 39、喘 40。只记录，规则不用
    static let vocCoreGroup = [21, 22, 23, 33, 34, 36, 39, 40]
    /// 非语言人声扩展组 = 核心组 + 尖叫 11、笑 13/15/16/17/18、哭 19。规则用这一组
    static let vocExtGroup = [11, 13, 15, 16, 17, 18, 19, 21, 22, 23, 33, 34, 36, 39, 40]
    static let speechGroup = [0]
    /// Speech + Conversation 2 + Narration 3。只记录，规则不用
    static let speechExtGroup = [0, 2, 3]
    static let musicGroup = [132]
    static let silenceGroup = [494]
    /// 撞击声和口腔声：咀嚼 49、敲 353、轻敲 354、挤压水声 441、拍打 461、重击 462。有它们就不算"听不出"
    static let impactGroup = [49, 353, 354, 441, 461, 462]

    /// `features` 返回数组的下标（也是评测 CSV a_cue_* 列的顺序）
    static let fVocCore = 0
    static let fVocExt = 1
    static let fSpeech = 2
    static let fSpeechExt = 3
    static let fMusic = 4
    static let fSilence = 5
    static let fImpact = 6
    static let nFeatures = 7
    private static let groups = [vocCoreGroup, vocExtGroup, speechGroup, speechExtGroup,
                                 musicGroup, silenceGroup, impactGroup]
    /// 评测 CSV 的列名（与 Android BenchLogger 的表头逐字相同）
    static let featureCols = ["a_cue_voc_core", "a_cue_voc_ext", "a_cue_speech", "a_cue_speech_ext",
                              "a_cue_music", "a_cue_silence", "a_cue_impact"]

    // MARK: - 阈值（Double，比较前先把 Float 分数转成 Double）

    /// 对白：人声组 < dVoc 且 Speech ≥ dSp
    static let dVoc: Double = 0.01
    static let dSp: Double = 0.7
    /// 听不出：人声组 < bVoc、撞击 / 口腔声 < bImp；Music ≥ bMus 且不低于 Speech 为音乐，
    /// 否则 Speech < bSp 时 Silence ≥ bSil 为安静、都不是为听不出
    static let bVoc: Double = 0.05
    static let bSp: Double = 0.2
    static let bImp: Double = 0.1
    static let bMus: Double = 0.3
    static let bSil: Double = 0.3
    /// 人声组 ≥ pVoc 为人声；撞击 / 口腔声 ≥ pImp 为拍打（只记录）
    static let pVoc: Double = 0.3
    static let pImp: Double = 0.2

    /// 521 类分数 → 各组分数（nFeatures 个，按 f* 下标）。每组按下标顺序 Float 逐个累加。
    /// - Returns: 分数不是 521 维时返回 nil（线索为 unknown）
    static func features(_ scores: [Float]?) -> [Float]? {
        guard let scores = scores, scores.count == nClasses else { return nil }
        var f = [Float](repeating: 0, count: nFeatures)
        for g in 0..<groups.count {
            var acc: Float = 0
            for idx in groups[g] { acc += scores[idx] }
            f[g] = acc
        }
        return f
    }

    /// 各组分数 → 线索。按顺序判：对白 → 听不出三种 → 人声 → 拍打 → 其它。f 为 nil 时 unknown。
    static func classify(_ f: [Float]?) -> Int {
        guard let f = f, f.count >= nFeatures else { return unknown }
        let voc = Double(f[fVocExt]), sp = Double(f[fSpeech]), mus = Double(f[fMusic])
        let sil = Double(f[fSilence]), imp = Double(f[fImpact])
        if voc < dVoc && sp >= dSp { return dialog }
        if voc < bVoc && imp < bImp {
            if mus >= bMus && mus >= sp { return music }
            if sp < bSp { return sil >= bSil ? quiet : blind }
        }
        if voc >= pVoc { return vocal }
        if imp >= pImp { return impact }
        return other
    }

    /// 521 类分数直接判线索
    static func of(_ scores: [Float]?) -> Int {
        return classify(features(scores))
    }

    /// 听不出：音乐 / 安静 / 听不出（仲裁器"音频听不出时视频单独启动"用）
    static func uninformative(_ cue: Int) -> Bool {
        return cue == music || cue == quiet || cue == blind
    }

    /// 评测 CSV 的写法（"dialog" 等），unknown 为空串
    static func name(_ cue: Int) -> String {
        return cue >= 0 && cue < names.count ? names[cue] : ""
    }

    /// a_cue 列 → 线索；空串或认不出的为 unknown
    static func fromName(_ s: String?) -> Int {
        guard let s = s, !s.isEmpty else { return unknown }
        for i in 1..<names.count where names[i] == s {
            return i
        }
        return unknown
    }

    /// 界面上显示的中文名，unknown 为空串
    static func label(_ cue: Int) -> String {
        return cue >= 0 && cue < labels.count ? labels[cue] : ""
    }

    /// 评测 CSV 的参数行（线索的阈值），格式与 Android AudioCue.paramsLine() 逐字相同。
    /// iOS 目前不写评测 CSV；以后要写时跟在 FusionArbiter.paramsLine() 后面，中间一个空格。
    static func paramsLine() -> String {
        let items: [String] = [
            "CUE=v1",
            "CUE_D_VOC=\(f4(dVoc))", "CUE_D_SP=\(f4(dSp))",
            "CUE_B_VOC=\(f4(bVoc))", "CUE_B_SP=\(f4(bSp))", "CUE_B_IMP=\(f4(bImp))",
            "CUE_B_MUS=\(f4(bMus))", "CUE_B_SIL=\(f4(bSil))",
            "CUE_P_VOC=\(f4(pVoc))", "CUE_P_IMP=\(f4(pImp))",
        ]
        return items.joined(separator: " ")
    }

    /// 四位小数（与 Java 的 %.4f 相同；String(format:) 不带 locale，小数点固定是 "."）
    private static func f4(_ x: Double) -> String {
        return String(format: "%.4f", x)
    }
}
