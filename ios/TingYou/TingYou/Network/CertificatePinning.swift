import Foundation
import Security

/// 出站域名白名单（P1-1）：与安卓 network_security_config.xml 的 domain 列表语义对等。
/// includeSubdomains=true 的域按后缀放行（host == domain 或 host 以 ".domain" 结尾），
/// 其余精确匹配；不在白名单内的 host 一律取消挑战（fail-closed）。
enum PinnedDomainAllowlist {
    /// includeSubdomains = true（后缀域）
    static let suffixDomains: [String] = [
        "tingyou.fm",     // 听友 FM API 与封面域
        "tingyou8.vip",   // 听友 FM 运行时数据域（封面）
        "guoguo.org.cn",  // 音频直链白名单后缀
        "kuwo.cn",        // 书音FM 直链 302 跳转（音频+封面 img1-4）
        "ctyun.cn",       // 天翼云 OBS 跳转目标（*.obs.ctyun.cn 各区域）
        "bilibili.com",   // B站 API / Web
        "b23.tv",         // B站短链
        "bilivideo.com",  // B站 DASH 音轨 CDN
        "biliapi.net",    // B站 API 备用域
        "akamaized.net",  // Akamai CDN 节点
        "hdslb.com",      // B站自建 CDN
    ]

    /// includeSubdomains = false（精确域）
    static let exactDomains: Set<String> = [
        "file.hgeuz.cn",
        "m.ting15.com",
        "www.ting08.com",
        "m.mekui.com",
        "api.mekui.com",
        "api.aikeu.com",
        "mp3.aikeu.com",
        "shuyinfm.oss-cn-hangzhou.aliyuncs.com",
        "imge.kugou.com",
        // build 50 · 易听书（对齐 PC v1.1.8 音源）：站 / 图床 / 音频 CDN
        "www.yitingshu.com",
        "imagev2.xmcdn.com",
        "aod.cos.tx.xmcdn.com",
        // build 50 · 云同步（tingshu-sync 云函数，对齐 PC 端同一服务）
        "tingshu-d2gjera4688800c8e.service.tcloudbase.com",
    ]

    /// host 是否在白名单内（对等安卓 includeSubdomains 匹配）
    static func isAllowed(_ host: String) -> Bool {
        let h = host.lowercased()
        if exactDomains.contains(h) { return true }
        return suffixDomains.contains { h == $0 || h.hasSuffix(".\($0)") }
    }
}

/// iOS 27张锚点证书体系：URLSession delegate 实现证书校验/pinning。
/// 无 trust-all；ATS 全禁明文；system ∪ 锚点加法配置；
/// 域名白名单 fail-closed（不认识的出站域直接取消，与安卓 domain-config 边界对齐）。
final class PinningURLSessionDelegate: NSObject, URLSessionDelegate {

    private let anchors: [SecCertificate]

    override init() {
        var certs: [SecCertificate] = []
        let names = [
            "certum_trusted_network_ca",
            "digicert_global_root_ca_self",
            "digicert_global_root_g2_cross",
            "digicert_secure_site_g2_2022_ca1",
            "globalsign_gcc_r46_ov_ca_2025",
            "globalsign_r3_cross",
            "globalsign_root_ca",
            "globalsign_root_r46_cross",
            "globalsign_rsa_ov_ca_2018",
            "gts_root_r4_cross",
            "gts_root_r4_self",
            "gts_we1",
            "isrg_root_x1",
            "isrg_root_x2_cross",
            "isrg_root_x2_self",
            "isrg_root_ye_cross",
            "isrg_root_yr_cross",
            "letsencrypt_ye2",
            "letsencrypt_yr1",
            "letsencrypt_yr2",
            "litessl_ecc_ca_2025",
            "litessl_rsa_ca_2025",
            "sheca_ov_tls_rsa_ca_a1",
            "trustasia_dv_rsa_ca_2024",
            "trustasia_tls_ecc_root_cross",
            "trustasia_tls_rsa_root_cross",
            "uca_global_g2_root_cross",
        ]
        for name in names {
            if let url = Bundle.main.url(forResource: name, withExtension: "pem"),
               let data = try? Data(contentsOf: url),
               let cert = SecCertificateCreateWithData(nil, data as CFData) {
                certs.append(cert)
            }
        }
        anchors = certs
        super.init()
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let serverTrust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              !chain.isEmpty else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // 域名白名单 fail-closed（P1-1）
        let host = challenge.protectionSpace.host
        guard PinnedDomainAllowlist.isAllowed(host) else {
            print("Blocked non-allowlisted host: \(host)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, host as CFString)
        SecTrustCreateWithCertificates(chain as CFArray, policy, &trust)
        guard let t = trust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        SecTrustSetAnchorCertificates(t, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(t, false)

        var error: CFError?
        let ok = SecTrustEvaluateWithError(t, &error)
        if ok {
            let cred = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, cred)
        } else {
            // 诊断：记录对端链信息（类似安卓 NetDiag/TlsDiag）
            let chainInfo = chain.enumerated().map { i, cert in
                let subj = SecCertificateCopySubjectSummary(cert) as String? ?? "?"
                return "[\(i)] \(subj)"
            }.joined(separator: "; ")
            print("TLS pinning failed for \(host): \(chainInfo)")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
