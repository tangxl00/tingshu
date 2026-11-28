import Foundation

/// GitHub Release 检查更新结果
struct UpdateInfo {
    let latestVersion: String
    let changelog: String
    let htmlUrl: String
    let apkUrl: String?
    let publishedAt: String?

    /// 弹窗副标题：当前版本 → 最新版本 · 发布日期
    var versionLine: String {
        let current = Self.currentVersion
        let date = publishedAt ?? ""
        return "v\(current) → v\(latestVersion)\(date.isEmpty ? "" : " · \(date)")"
    }

    var hasNewer: Bool {
        Self.compare(Self.currentVersion, latestVersion) < 0
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// 语义化版本比较：相等 0，前者大 1，前者小 -1
    private static func compare(_ a: String, _ b: String) -> Int {
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
        let apk = assets
            .first { (($0["name"] as? String) ?? "").hasSuffix(".apk") }?["browser_download_url"] as? String
        let published = json["published_at"] as? String

        return UpdateInfo(
            latestVersion: latest,
            changelog: (json["body"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            htmlUrl: json["html_url"] as? String ?? fallbackURL,
            apkUrl: apk,
            publishedAt: published.map { String($0.prefix(10)) }
        )
    }
}
