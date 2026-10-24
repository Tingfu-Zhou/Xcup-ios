//
//  UpdateService.swift
//  Xcup
//
//  Created by tingfu on 2025/9/2.
//

// NEW file: UpdateService.swift
import Foundation

/// 远端版本配置（只解析 iOS 段）
struct RemoteVersionConfig: Decodable {
    let ios: IOS?
    struct IOS: Decodable {
        let latest: String
        let minSupported: String
        let appStoreUrl: String
        let notes: String?
        let notesJa: String?    // 可选：日文界面用的更新说明，没填就用 notes
        let notesEn: String?    // 可选：英文界面用的更新说明，没填就显示弹窗自带的英文默认说明

        enum CodingKeys: String, CodingKey {
            case latest, minSupported, appStoreUrl, notes
            case notesJa = "notes_ja"
            case notesEn = "notes_en"
        }

        /// 按界面语言挑更新说明：日文界面填了 notes_ja 就用它，否则用 notes（与原来一样）；
        /// 英文界面只用 notes_en，没填返回 nil，让弹窗显示自带的英文默认说明（中文 notes 英文用户看不懂）；
        /// 其余界面用 notes
        var localizedNotes: String? {
            switch Bundle.main.preferredLocalizations.first ?? "" {
            case "ja":
                if let ja = notesJa, !ja.isEmpty { return ja }
                return notes
            case "en":
                if let en = notesEn, !en.isEmpty { return en }
                return nil
            default:
                return notes
            }
        }
    }
}

/// 更新结果
enum UpdateResult {
    case required(info: UpdateInfo) // 强更
    case optional(info: UpdateInfo) // 推荐更新
    case none                       // 无需更新
}

struct UpdateInfo {
    let latest: String
    let minSupported: String
    let appStoreUrl: String
    let notes: String?
}

final class UpdateService {
    static let shared = UpdateService()

    /// TODO: 将下面的 URL 改为你的 version.json 地址（HTTPS）
    private let versionURL = URL(string: "https://cdn.xswy.tech/app/version.json")! // NEW

    /// 拉取并比对版本（主线程回调；失败时返回 .none 以静默）
    func check(completion: @escaping (UpdateResult) -> Void) {
        var req = URLRequest(url: versionURL, timeoutInterval: 6)
        req.setValue(userAgent(), forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: req) { data, _, error in
            guard
                error == nil,  // NEW: 网络失败
                let data = data,
                let cfg = try? JSONDecoder().decode(RemoteVersionConfig.self, from: data),
                let ios = cfg.ios
            else {
                // NEW: 网络失败策略——静默跳过，不打断用户
                DispatchQueue.main.async { completion(.none) }
                return
            }

            let local = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
            let result: UpdateResult

            if self.compareVersion(local, ios.minSupported) == .orderedAscending {
                // 本地 < minSupported → 强更
                result = .required(info: .init(latest: ios.latest,
                                               minSupported: ios.minSupported,
                                               appStoreUrl: ios.appStoreUrl,
                                               notes: ios.localizedNotes))
            } else if self.compareVersion(local, ios.latest) == .orderedAscending {
                // 本地 < latest → 推荐更新
                result = .optional(info: .init(latest: ios.latest,
                                               minSupported: ios.minSupported,
                                               appStoreUrl: ios.appStoreUrl,
                                               notes: ios.localizedNotes))
            } else {
                result = .none
            }

            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
    }

    // 简单的语义化版本比较：按“点”拆分为整数序列逐位比较
    private func compareVersion(_ a: String, _ b: String) -> ComparisonResult {
        return Self.compareVersion(a, b)
    }
    static func compareVersion(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        let n = max(x.count, y.count)
        for i in 0..<n {
            let xi = i < x.count ? x[i] : 0
            let yi = i < y.count ? y[i] : 0
            if xi < yi { return .orderedAscending }
            if xi > yi { return .orderedDescending }
        }
        return .orderedSame
    }

    private func userAgent() -> String {
        let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        return "Xcup-iOS/\(v)"
    }
}
