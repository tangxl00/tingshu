import SwiftUI
import WebKit

/// 悦听有声书人工验证 WebView（P0-4，安卓 YtysxsVerifyWebView 对等）。
///
/// 完整反爬闭环：
/// 1. 搜索/详情命中 AntibotException（搜索驗證 / cf-turnstile / be_captcha_token 页特征）；
/// 2. UI 弹出本 sheet，加载悦听搜索页，用户人工完成验证（不自动破解验证码）；
/// 3. 每次导航结束经 WKWebsiteDataStore.httpCookieStore 捕获 be_captcha_token；
/// 4. token 写入 KeychainTokenStore（Keychain 主体 + 24h Max-Age 元数据）；
/// 5. 有效期内原生请求（YtysxsAdapter.fetchHtml）自动携带 Cookie 放行。
struct YtysxsVerifyWebView: UIViewRepresentable {
    let keyword: String
    let cookieStore: KeychainTokenStore
    let onResult: (Bool) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = kw.isEmpty
            ? "https://www.ytysxs.com"
            : "https://www.ytysxs.com/?s=\(MsrcHtml.encodeUriComponent(kw))"
        guard let url = URL(string: urlString), context.coordinator.loadedURL != urlString else { return }
        context.coordinator.loadedURL = urlString
        uiView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(cookieStore: cookieStore, onResult: onResult)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let cookieStore: KeychainTokenStore
        let onResult: (Bool) -> Void
        var loadedURL: String?

        init(cookieStore: KeychainTokenStore, onResult: @escaping (Bool) -> Void) {
            self.cookieStore = cookieStore
            self.onResult = onResult
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 验证完成后从 httpCookieStore 捕获 be_captcha_token（24h 有效）
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self else { return }
                if let token = cookies.first(where: { $0.name == "be_captcha_token" })?.value,
                   !token.isEmpty {
                    self.cookieStore.save(token: token)
                    DispatchQueue.main.async { self.onResult(true) }
                }
            }
        }
    }
}

/// 验证流程 sheet：标题 + 完成验证 / 取消按钮 + WebView 主体。
struct YtysxsVerifySheet: View {
    let keyword: String
    let cookieStore: KeychainTokenStore
    let onDone: (Bool) -> Void

    var body: some View {
        NavigationStack {
            YtysxsVerifyWebView(keyword: keyword, cookieStore: cookieStore) { captured in
                if captured { onDone(true) }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("完成安全验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onDone(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("我已完成验证") { onDone(cookieStore.hasValidToken()) }
                }
            }
        }
    }
}
