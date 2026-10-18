import Foundation
import Security

/// iOS 27张锚点证书体系：URLSession delegate 实现证书校验/pinning。
/// 无 trust-all；ATS 全禁明文；system ∪ 锚点加法配置。
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

        var trust: SecTrust?
        var policy = SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString)
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
            print("TLS pinning failed for \(challenge.protectionSpace.host): \(chainInfo)")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
