//
//  PcmResampler.swift
//  Xcup
//
//  逐行移植自 Android PcmResampler.java（xcup-android 分支 claude/video-annotation-benchmark-automation-85f1ju），
//  两端由 XcupTests/PcmResamplerTests.swift 用同一份 resampler_golden.txt 对拍，喂给模型的音频逐样本一致。
//  改算法必须三处同步：Android PcmResampler.java、bench/tools/audio_rescore.py、这里。
//
//  XcupBroadcast/PcmResampler.swift 是这个文件的逐字拷贝（广播扩展是独立 target，按约定自包含）。
//  改这里必须同步改那份；PcmResamplerTests 会检查两份是否一致。
//

import Foundation

/// 交错 16-bit PCM → 单声道 Float、16kHz，流式。
///
/// 1. 下混：每帧各声道整数相加再除以 (声道数 × 32768)，即 (L+R)/2，与训练用的 `ffmpeg -ac 1`（16-bit WAV）一致。
/// 2. 重采样：Blackman 窗 sinc 低通插值，截止 7600Hz（YAMNet 的 mel 上限是 7500Hz），每侧 24 个过零点。
///    第 n 个输出样本对应输入里 n/16000 秒处。输入输出采样率之比是有理数 num/den，插值相位只有 den 种
///    （48k：1 种，44.1k：160 种），系数表预先算好；每个相位的系数归一化到和为 1。输入就是 16kHz 时只下混。
/// 3. 输出只按 16 的整数倍给（16 个样本 = 1ms），调用方用 "起点 ms + i*1000/16000" 打时间戳
///    （PcmCircularBuffer.write）时就与全局连续计时一致，块与块之间不丢样本、不重置相位。
final class PcmResampler {

    static let outRate = 16000
    static let cutoffHz = 7600.0
    static let zeroCrossings = 24
    /// 相位数超过这个就不建表，逐个输出现算系数（只有很奇怪的采样率才会走到）。
    static let maxTablePhases: Int64 = 2048

    let inputRate: Int
    let channelCount: Int
    private let passthrough: Bool
    private let num: Int64           // 输出第 n 个样本在输入里的位置 = n * num / den
    private let den: Int64
    private let half: Int            // 用输入 [i0-half+1, i0+half] 这 2*half 个样本
    private let fc: Double           // 截止频率，单位：周期/输入样本
    private let width: Double        // 窗半宽（输入样本）
    private var table: [[Double]]?   // [相位][2*half]，nil = 现算

    private var buf: [Float] = []    // 尚未丢弃的单声道输入
    private var bufStart: Int64      // buf[0] 对应的输入下标（开头补的零下标为负）
    /// 已收到的输入帧数（每帧含全部声道）。
    private(set) var inputFrames: Int64 = 0
    /// 已产出的 16kHz 输出样本数；下一次 process 返回的第一个样本就是第 outputCount 个。总是 16 的倍数。
    private(set) var outputCount: Int64 = 0

    init(inputRate: Int, channelCount: Int) {
        precondition(inputRate > 0 && channelCount > 0, "inputRate=\(inputRate) channelCount=\(channelCount)")
        self.inputRate = inputRate
        self.channelCount = channelCount
        passthrough = inputRate == PcmResampler.outRate
        let g = PcmResampler.gcd(Int64(inputRate), Int64(PcmResampler.outRate))
        num = Int64(inputRate) / g
        den = Int64(PcmResampler.outRate) / g
        let cutoff = min(PcmResampler.cutoffHz, 0.475 * Double(min(inputRate, PcmResampler.outRate)))
        fc = cutoff / Double(inputRate)
        width = Double(PcmResampler.zeroCrossings) / (2.0 * fc)
        half = Int(ceil(width))
        // 开头补 half-1 个零：第 0 个输出要用到下标 -half+1 .. half
        let lead = passthrough ? 0 : half - 1
        buf = [Float](repeating: 0, count: lead)
        bufStart = -Int64(lead)
        if !passthrough && den <= PcmResampler.maxTablePhases {
            table = (0..<den).map { weights($0) }
        }
    }

    /// 相位 k（小数位置 k/den）的 2*half 个系数，第 j 个乘输入下标 i0-half+1+j。
    func weights(_ k: Int64) -> [Double] {
        let f = Double(k) / Double(den)
        var w = [Double](repeating: 0, count: 2 * half)
        var sum = 0.0
        for j in 0..<(2 * half) {
            let t = f + Double(half) - 1 - Double(j)      // 输出位置 - 该输入样本的位置
            var v = 0.0
            if abs(t) < width {
                let x = 2.0 * fc * t
                let sinc = x == 0 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                let u = t / width
                let win = 0.42 + 0.5 * cos(Double.pi * u) + 0.08 * cos(2.0 * Double.pi * u)
                v = 2.0 * fc * sinc * win
            }
            w[j] = v
            sum += v
        }
        for j in 0..<w.count { w[j] /= sum }
        return w
    }

    /// 喂入 frames 帧交错 Int16 PCM（pcm[offset] 起，共 frames*channelCount 个），
    /// 返回这次能产出的 16kHz 样本（长度为 16 的倍数，可能为 0）。
    func process(_ pcm: UnsafeBufferPointer<Int16>, offset: Int = 0, frames: Int) -> [Float] {
        let ch = channelCount
        precondition(offset >= 0 && offset + frames * ch <= pcm.count, "PCM 长度不足")
        let scale = Float(ch) * 32768
        buf.reserveCapacity(buf.count + frames)
        for i in 0..<frames {
            var sum: Int32 = 0
            let base = offset + i * ch
            for c in 0..<ch { sum += Int32(pcm[base + c]) }
            buf.append(Float(sum) / scale)
        }
        inputFrames += Int64(frames)
        return produce()
    }

    func process(_ pcm: [Int16], offset: Int = 0, frames: Int) -> [Float] {
        pcm.withUnsafeBufferPointer { process($0, offset: offset, frames: frames) }
    }

    /// 喂入已经下混好的单声道样本（[-1, 1]）。给 Float32/Int32 等非 Int16 来源用；
    /// Int16 来源请用上面的版本，才能与 Android 逐位一致。
    func process(mono: [Float]) -> [Float] {
        buf.append(contentsOf: mono)
        inputFrames += Int64(mono.count)
        return produce()
    }

    private func produce() -> [Float] {
        let last = inputFrames - 1                         // 已有的最大输入下标
        var avail: Int64                                   // 能算的输出个数（从 0 起计）
        if passthrough {
            avail = inputFrames
        } else {
            // 第 n 个输出需要 floor(n*num/den)+half <= last，即 n*num < (last-half+1)*den
            let lim = last - Int64(half)
            avail = lim < 0 ? 0 : ((lim + 1) * den - 1) / num + 1
            while avail > 0 && ((avail - 1) * num) / den + Int64(half) > last { avail -= 1 }   // 防御：整除边界
        }
        let n1 = avail - (avail % 16)                      // 只产出到 16 的整数倍
        let count = Int(max(0, n1 - outputCount))
        var out = [Float](repeating: 0, count: count)
        for m in 0..<count {
            let n = outputCount + Int64(m)
            if passthrough {
                out[m] = buf[Int(n - bufStart)]
                continue
            }
            let p = n * num
            let i0 = p / den
            let k = p % den
            let w = table?[Int(k)] ?? weights(k)
            let s = Int(i0 - Int64(half) + 1 - bufStart)
            var acc = 0.0
            for j in 0..<w.count { acc += Double(buf[s + j]) * w[j] }
            out[m] = Float(acc)
        }
        outputCount += Int64(count)
        compact()
        return out
    }

    /// 丢掉以后再也用不到的输入。
    private func compact() {
        let keepFrom: Int64
        if passthrough {
            keepFrom = outputCount
        } else {
            keepFrom = (outputCount * num) / den - Int64(half) + 1   // 下一个输出要用的最小下标
        }
        let drop = Int(min(Int64(buf.count), max(0, keepFrom - bufStart)))
        if drop > 0 {
            buf.removeFirst(drop)
            bufStart += Int64(drop)
        }
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var a = a, b = b
        while b != 0 {
            let t = a % b
            a = b
            b = t
        }
        return a
    }
}
