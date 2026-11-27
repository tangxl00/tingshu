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
        "guoguo.org.cn",  // 音频直链白名单后缀（听友FM 音频域）
        "kuwo.cn",        // 音频直链 302 跳转后缀（酷我 CDN，多源共用）
        "ctyun.cn",       // 天翼云 OBS 跳转目标（*.obs.ctyun.cn 各区域）
        "bilibili.com",   // B站 API / Web
        "b23.tv",         // B站短链
        "bilivideo.com",  // B站 DASH 音轨 CDN
        "biliapi.net",    // B站 API 备用域
        "akamaized.net",  // Akamai CDN 节点
        "hdslb.com",      // B站自建 CDN
    ]

    /// includeSubdomains = false（精确域）
    /// build 51（质检必修 · 音源残留）：已下架源的主机全部删除——原来 ting15（听十五）/
    /// ting08 / mekui（书音FM）/ aikeu（书音FM 图床与音频域）/ shuyinfm OSS 五源，
    /// 共 7 条精确域仍留在白名单里，等于给已下架站点保留出站许可。
    /// 保留的只有当前在役三源（听友FM / B站 / 易听书）所需的精确域。
    static let exactDomains: Set<String> = [
        "file.hgeuz.cn",
        "imge.kugou.com",
        // build 50 · 易听书（对齐 PC v1.1.8 音源）：站 / 图床 / 音频 CDN
        "www.yitingshu.com",
        "imagev2.xmcdn.com",
        "aod.cos.tx.xmcdn.com",
    ]

    /// host 是否在白名单内（对等安卓 includeSubdomains 匹配）
    static func isAllowed(_ host: String) -> Bool {
        let h = host.lowercased()
        if exactDomains.contains(h) { return true }
        return suffixDomains.contains { h == $0 || h.hasSuffix(".\($0)") }
    }
}

/// iOS 出站 TLS 校验：URLSession delegate + 内置锚点证书 + 域名白名单。
///
/// 信任模型（请按实际代码理解，勿表述为"严格证书 pinning"）：
/// - 调用 SecTrustSetAnchorCertificates(t, anchors) 注入内置锚点，但随后
///   SecTrustSetAnchorCertificatesOnly(t, false)，即"系统信任库 ∪ 内置锚点"
///   均为可信根。这不是证书固定（pinning）：任何系统信任的 CA 签发的证书，
///   只要域名在白名单内且链校验通过，同样会被放行。
/// - 真正限制出站面的是 PinnedDomainAllowlist 的 fail-closed 白名单：
///   不在清单中的 host 一律 cancelAuthenticationChallenge。
/// - 内置 27 张锚点的作用是补齐部分站点证书链在系统信任库中缺失的信任路径，
///   而非把对端证书锁定到固定公钥/证书。
///
/// 无 trust-all；ATS 全禁明文；域名白名单 fail-closed（与安卓 domain-config 边界对齐）。
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
        // false = 系统信任库与内置锚点取并集；改为 true 才是"仅内置锚点"的严格 pinning。
        // 当前保持 false：部分音源/CDN 依赖系统信任链，收紧会中断播放（见类注释）。
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
            print("TLS trust evaluation failed for \(host): \(chainInfo)")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
