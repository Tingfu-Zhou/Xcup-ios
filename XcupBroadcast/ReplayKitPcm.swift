//
//  ReplayKitPcm.swift
//  XcupBroadcast
//
//  把 ReplayKit 音频块（任意 Int16 / Int32 / Float32、交错或非交错、大端或小端）转成 PcmResampler 能吃的形式。
//  纯 Swift，不依赖 ReplayKit / CoreMedia，方便单独测试。
//

import Foundation

/// 一个音频块的原始格式（取自 AudioStreamBasicDescription）。
struct ReplayKitPcmFormat {
    var channels: Int
    var bitsPerChannel: Int
    var isFloat: Bool
    var isBigEndian: Bool        // kAudioFormatFlagIsBigEndian：ReplayKit 的 .audioApp 通常是大端 Int16
    var isNonInterleaved: Bool   // kAudioFormatFlagIsNonInterleaved：每个 AudioBuffer 一个声道
}

enum ReplayKitPcm {
    /// Int16 来源：交错 Int16（已转成本机字节序），下混交给 PcmResampler，与 Android 逐位一致。
    case int16(interleaved: [Int16], channels: Int)
    /// 其他来源：已下混（各声道平均）的单声道 Float，范围 [-1, 1]。
    case mono([Float])

    /// 喂给 PcmResampler 时的声道数。
    var channels: Int {
        switch self {
        case .int16(_, let ch): return ch
        case .mono: return 1
        }
    }

    /// buffers：AudioBufferList 里的各个 AudioBuffer（交错时只有 1 个）。不支持的格式或数据不足时返回 nil。
    static func convert(format f: ReplayKitPcmFormat, buffers: [UnsafeRawBufferPointer], frames: Int) -> ReplayKitPcm? {
        let ch = f.channels
        guard ch > 0, frames > 0, !buffers.isEmpty else { return nil }
        let bytesPerSample = f.bitsPerChannel / 8
        guard bytesPerSample == 2 || bytesPerSample == 4 else { return nil }
        // planes[c] 是第 c 个平面；交错时只有一个平面、步长 ch
        let planes: [UnsafeRawBufferPointer]
        let stride: Int
        if f.isNonInterleaved {
            guard buffers.count >= ch else { return nil }
            planes = Array(buffers.prefix(ch))
            stride = 1
        } else {
            planes = [buffers[0]]
            stride = ch
        }
        let needBytes = frames * stride * bytesPerSample
        guard planes.allSatisfy({ $0.count >= needBytes && $0.baseAddress != nil }) else { return nil }

        if !f.isFloat && bytesPerSample == 2 {
            var out = [Int16](repeating: 0, count: frames * ch)
            for (p, plane) in planes.enumerated() {
                var raw = [UInt16](repeating: 0, count: frames * stride)
                raw.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: plane[0..<needBytes])) }
                for i in 0..<raw.count {
                    let v = Int16(bitPattern: f.isBigEndian ? UInt16(bigEndian: raw[i]) : UInt16(littleEndian: raw[i]))
                    if f.isNonInterleaved { out[i * ch + p] = v } else { out[i] = v }
                }
            }
            return .int16(interleaved: out, channels: ch)
        }

        // Float32 / Int32：各声道平均成单声道
        var mono = [Float](repeating: 0, count: frames)
        for plane in planes {
            var raw = [UInt32](repeating: 0, count: frames * stride)
            raw.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: plane[0..<needBytes])) }
            for i in 0..<raw.count {
                let bits = f.isBigEndian ? UInt32(bigEndian: raw[i]) : UInt32(littleEndian: raw[i])
                let v = f.isFloat ? Float(bitPattern: bits) : Float(Int32(bitPattern: bits)) / 2147483648.0
                mono[f.isNonInterleaved ? i : i / ch] += v
            }
        }
        if ch > 1 {
            let inv = 1 / Float(ch)
            for i in 0..<frames { mono[i] *= inv }
        }
        return .mono(mono)
    }
}
