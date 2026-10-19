//
//  BroadcastBridge.swift  ── 主 App 端（读端）
//  Xcup target 专用，只包含主 App 需要的读端代码
//
//  Extension 端的写端代码在 XcupBroadcast/BroadcastSampleHandler.swift
//

import Foundation
import Darwin

// MARK: - 共享常量

let kBroadcastAppGroupID = "group.com.aibei.Xcup"
let kAudioRingFile       = "xcup_audio_ring.bin"
let kVideoFrameFile      = "xcup_video_frame.bin"   // 帧头 + JPEG，见 VideoFrameFile

let kDarwinStart    = "com.aibei.xcup.broadcastStart" as CFString
let kDarwinAudio    = "com.aibei.xcup.audio"          as CFString
let kDarwinVideo    = "com.aibei.xcup.video"          as CFString
let kDarwinStop     = "com.aibei.xcup.stop"           as CFString
let kDarwinAudioRaw = "com.aibei.xcup.audioRaw"       as CFString   // 诊断：.audioApp 原始到达

// 诊断 UserDefaults key（与扩展侧保持一致）
let kDiagAudioFmt  = "xcup_diag_audio_fmt"
let kDiagAudioConv = "xcup_diag_audio_conv"
let kDiagAudioRaw  = "xcup_diag_audio_raw"
let kDiagVideoFmt  = "xcup_diag_video_fmt"    // 扩展收到的画面：尺寸、像素格式、方向、颜色标注

// MARK: - 环形缓冲布局

enum AudioRing {
    static let sampleRate  = 16000
    static let capSec      = 20
    static let capacity    = sampleRate * capSec
    static let headerBytes = 16
    static let dataBytes   = capacity * MemoryLayout<Float>.size
    static let fileBytes   = headerBytes + dataBytes
}

// MARK: - 音频读端

final class AudioRingReader {
    private var fd: Int32 = -1
    private var base: UnsafeRawPointer?
    private let readLock = NSLock()
    private var lastCursor: Int? = nil   // readNew() 上次读到的写游标
    private var lastSeq: UInt32 = 0      // readNew() 上次看到的写序号（扩展重启后从 0 重新计）

    init?(groupID: String = kBroadcastAppGroupID) {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(kAudioRingFile),
              FileManager.default.fileExists(atPath: url.path) else { return nil }

        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }

        let raw = mmap(nil, AudioRing.fileBytes, PROT_READ, MAP_SHARED, fd, 0)
        if raw == MAP_FAILED { close(fd); fd = -1; return nil }
        base = UnsafeRawPointer(raw)
    }

    deinit {
        if let b = base { munmap(UnsafeMutableRawPointer(mutating: b), AudioRing.fileBytes) }
        if fd >= 0 { close(fd) }
    }

    /// 读出上次调用之后扩展新写入的全部样本（按写入顺序，连续、不重复、不遗漏）。
    /// 第一次调用只记下位置、不返回历史数据。两次调用之间写入超过整个环形缓冲（20 秒）时，只能拿到最近的部分。
    /// 扩展重启过（AudioWriter 重新初始化，游标和序号都归零）时，只返回重启之后写入的部分，不会把上一次的旧数据当成新数据。
    func readNew() -> [Float] {
        guard let b = base else { return [] }
        readLock.lock()
        defer { readLock.unlock() }
        let writeCursor = Int(b.load(fromByteOffset: 0, as: UInt32.self))
        let seq = b.load(fromByteOffset: 4, as: UInt32.self)
        let cap = AudioRing.capacity
        defer { lastCursor = writeCursor; lastSeq = seq }
        guard writeCursor < cap, let last = lastCursor else { return [] }
        let start = seq < lastSeq ? 0 : last          // 序号回退 = 扩展重启：重启后写入的就是 [0, writeCursor)
        let n = ((writeCursor - start) % cap + cap) % cap
        guard n > 0 else { return [] }
        let data = b.advanced(by: AudioRing.headerBytes).assumingMemoryBound(to: Float.self)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = data[(start + i) % cap] }
        return out
    }

    func readLatest(count: Int) -> [Float]? {
        guard let b = base else { return nil }
        let writeCursor = Int(b.load(fromByteOffset: 0, as: UInt32.self))
        let data = b.advanced(by: AudioRing.headerBytes).assumingMemoryBound(to: Float.self)
        let cap  = AudioRing.capacity
        let n    = min(count, cap)
        var out  = [Float](repeating: 0, count: n)
        let start = ((writeCursor - n) % cap + cap) % cap
        for i in 0..<n { out[i] = data[(start + i) % cap] }
        return out
    }
}

// MARK: - 视频读端

/// 扩展写的视频帧文件：32 字节的帧头（小端）+ JPEG，一次原子写入，方向和画面不会错开。布局与扩展端
/// BroadcastSampleHandler.swift 的 VideoWriter 一致（扩展那边是自包含的，改格式两边一起改）：
///
///     0   UInt32  magic "XCV1"
///     4   UInt32  RPVideoSampleOrientationKey 的原值（CGImagePropertyOrientation 1…8；没有这个附件时 0）
///     8   Int64   时间戳（Unix 毫秒）
///     16  UInt32  ReplayKit 原始画面的宽
///     20  UInt32  原始画面的高
///     24  UInt32  原始画面的像素格式（FourCC，如 '420f'）
///     28  UInt32  保留（0）
///     32  JPEG：已转正、短边缩到 480
enum VideoFrameFile {
    static let magic: UInt32 = 0x3156_4358     // 按小端读，文件里是 "XCV1"
    static let headerBytes = 32
}

/// 扩展写的一帧。
struct SharedVideoFrame {
    /// 已转正、短边缩到 480 的画面
    let jpeg: Data
    /// RPVideoSampleOrientationKey 的原值（0 = 没有）。扩展已经按它转正过；变了就是转屏
    let orientation: UInt32
    /// 扩展收到这一帧的时刻（Unix 毫秒）
    let timestampMs: Int64
    /// ReplayKit 原始画面的宽、高、像素格式（FourCC）
    let sourceWidth: Int
    let sourceHeight: Int
    let pixelFormat: UInt32

    /// CGImagePropertyOrientation 的名字，日志用
    static func orientationName(_ raw: UInt32) -> String {
        switch raw {
        case 1: return "up"
        case 2: return "upMirrored"
        case 3: return "down"
        case 4: return "downMirrored"
        case 5: return "leftMirrored"
        case 6: return "right"
        case 7: return "rightMirrored"
        case 8: return "left"
        default: return "无"
        }
    }

    /// FourCC（如 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange = '420f'）→ 字符串，日志用
    static func fourCC(_ v: UInt32) -> String {
        let bytes = [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
                     UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
        return bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) ? String(decoding: bytes, as: UTF8.self)
                                                             : "0x" + String(v, radix: 16)
    }
}

final class VideoFrameReader {
    private let frameURL: URL?

    init(groupID: String = kBroadcastAppGroupID) {
        frameURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(kVideoFrameFile)
    }

    /// 扩展最新写的一帧；没有文件、或不是这个格式时返回 nil。
    func readLatest() -> SharedVideoFrame? {
        guard let url = frameURL, let data = try? Data(contentsOf: url),
              data.count > VideoFrameFile.headerBytes else { return nil }
        let (magic, orientation, ts, w, h, format) = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            (UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)),
             UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)),
             Int64(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: Int64.self)),
             UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self)),
             UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self)),
             UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self)))
        }
        guard magic == VideoFrameFile.magic else { return nil }
        return SharedVideoFrame(jpeg: data.subdata(in: VideoFrameFile.headerBytes..<data.count),
                                orientation: orientation, timestampMs: ts,
                                sourceWidth: Int(w), sourceHeight: Int(h), pixelFormat: format)
    }
}

// MARK: - Darwin 通知注册（主 App 用）

typealias DarwinCallback = () -> Void

func registerDarwinObserver(name: CFString, callback: @escaping DarwinCallback) -> AnyObject {
    let box = CallbackBox(callback)
    let ptr = Unmanaged.passRetained(box).toOpaque()
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        ptr,
        { _, observer, _, _, _ in
            guard let obs = observer else { return }
            Unmanaged<CallbackBox>.fromOpaque(obs).takeUnretainedValue().callback()
        },
        name, nil, .deliverImmediately)
    return box
}

func unregisterDarwinObserver(_ token: AnyObject) {
    let ptr = Unmanaged.passRetained(token as AnyObject).toOpaque()
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), ptr, nil, nil)
    _ = Unmanaged<AnyObject>.fromOpaque(ptr).takeRetainedValue()
}

private final class CallbackBox {
    let callback: DarwinCallback
    init(_ cb: @escaping DarwinCallback) { callback = cb }
}
