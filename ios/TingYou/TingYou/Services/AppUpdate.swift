import Foundation

/// GitHub Release 检查更新结果
struct UpdateInfo {
    let latestVersion: String
    let changelog: String
    let htmlUrl: String
    let apkUrl: String?
    /// iOS 安装包直链（unsigned IPA），用于跳转到浏览器下载后自签。
    let ipaUrl: String?
    /// 从 IPA 资产名解析出的 iOS 版本（如 1.4.6）。iOS 检查更新必须以它为准，
    /// 不能拿 Release tag 比较——tag 跟随 Android 版本号（如 v1.2.7），与 iOS 版本不同步。
    let iosVersion: String?
    let publishedAt: String?

    /// 弹窗副标题：当前版本 → 最新版本 · 发布日期
    var versionLine: String {
        let current = Self.currentVersion
        let latest = displayVersion
        let date = publishedAt ?? ""
        return "v\(current) → v\(latest)\(date.isEmpty ? "" : " · \(date)")"
    }

    /// 用于展示的版本号：优先 IPA 里的 iOS 版本，回退到 tag。
    var displayVersion: String {
        if let iosVersion, !iosVersion.isEmpty { return iosVersion }
        return latestVersion
    }

    /// 是否有新版本：iOS 必须比 IPA 里的版本；没有 IPA 资产时不误报更新。
    var hasNewer: Bool {
        guard let iosVersion, !iosVersion.isEmpty else { return false }
        return Self.isNewer(current: Self.currentVersion, ipa: iosVersion)
    }

    /// 纯函数版本判断，便于单元测试（不依赖测试 bundle 的 CFBundleShortVersionString）。
    static func isNewer(current: String, ipa: String?) -> Bool {
        guard let ipa, !ipa.isEmpty else { return false }
        return compare(current, ipa) < 0
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// 语义化版本比较：相等 0，前者大 1，前者小 -1
    static func compare(_ a: String, _ b: String) -> Int {
        func numbers(_ s: String) -> [Int] {
            s.split(separator: ".").map { part in
                let digits = String(part.filter { $0.isNumber })
                return Int(digits) ?? 0
            }
        }
        let pa = numbers(a)
        let pb = numbers(b)
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }

    /// 从 IPA 资产名解析 iOS 版本与构建号。
    /// 支持 `TingYou-unsigned-1.4.6-61.ipa`（CI 打包命名）与 `TingYou-unsigned-1.4.6.ipa`。
    static func parseIPAVersion(_ name: String) -> (version: String, build: String?)? {
        guard name.hasPrefix("TingYou-unsigned-"), name.hasSuffix(".ipa") else { return nil }
        let core = String(name.dropFirst("TingYou-unsigned-".count).dropLast(".ipa".count))
        let parts = core.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, !first.isEmpty else { return nil }
        // 版本段必须形如 x.y.z
        let nums = first.split(separator: ".").map { $0.allSatisfy(\.isNumber) }
        guard nums.count >= 2, nums.allSatisfy({ $0 }) else { return nil }
        return (first, parts.count > 1 ? parts[1] : nil)
    }
}

private enum UpdateError: LocalizedError {
    case badStatus(Int)
    case badJSON

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "检查更新失败（HTTP \(code)）"
        case .badJSON: return "检查更新失败，返回数据异常"
        }
    }
}

/// 检查更新：读取 tangxl00/tingshu 的最新 Release
enum AppUpdate {
    private static let apiURL = "https://api.github.com/repos/tangxl00/tingshu/releases/latest"
    private static let fallbackURL = "https://github.com/tangxl00/tingshu/releases/latest"

    static func check() async throws -> UpdateInfo {
        guard let url = URL(string: apiURL) else { throw UpdateError.badJSON }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badJSON }
        guard (200...299).contains(http.statusCode) else {
            throw UpdateError.badStatus(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.badJSON
        }

        let rawTag = json["tag_name"] as? String ?? ""
        let latest = rawTag.hasPrefix("v") ? String(rawTag.dropFirst()) : rawTag
        let assets = json["assets"] as? [[String: Any]] ?? []

        let apkAsset = assets.first { (($0["name"] as? String) ?? "").hasSuffix(".apk") }
        let apk = apkAsset?["browser_download_url"] as? String

        let ipaAsset = assets.first {
            let name = ($0["name"] as? String) ?? ""
            return name.hasSuffix(".ipa") && UpdateInfo.parseIPAVersion(name) != nil
        }
        let ipa = ipaAsset?["browser_download_url"] as? String
        let ipaName = (ipaAsset?["name"] as? String) ?? ""
        let iosVersion = UpdateInfo.parseIPAVersion(ipaName)?.version

        let published = json["published_at"] as? String

        return UpdateInfo(
            latestVersion: latest,
            changelog: (json["body"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            htmlUrl: json["html_url"] as? String ?? fallbackURL,
            apkUrl: apk,
            ipaUrl: ipa,
            iosVersion: iosVersion,
            publishedAt: published.map { String($0.prefix(10)) }
        )
    }
}
