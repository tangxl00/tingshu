import SwiftUI

/// build 50 · 账号与同步（对齐 PC 端「账号与同步」区块交互）：
/// - 未登录：邮箱 + 验证码登录（发送验证码 60s 倒计时）
/// - 已登录：当前账号 / 同步状态（上次同步时间、待补传条数）/ 立即同步 / 退出登录
/// - 错误文案按契约口径：40002/40003/50001（首次登录云端建表可能超 3 秒 → 提示重试）
struct AccountSyncScreen: View {
    @Environment(\.appContainer) private var container

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var resendIn = 0
    @State private var working = false
    @State private var message: String?
    @State private var isError = false
    @State private var countdownTask: Task<Void, Never>?

    var body: some View {
        List {
            if let engine = container?.syncEngine, engine.phase == .loggedIn {
                loggedInSection(engine)
            } else {
                loginSection
            }
        }
        .navigationTitle("账号与同步")
    }

    // MARK: - 登录区

    private var loginSection: some View {
        Section {
            TextField("邮箱", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("验证码", text: $code)
                .keyboardType(.numberPad)
            HStack {
                Button {
                    sendCode()
                } label: {
                    Text(resendIn > 0 ? "重新发送(\(resendIn)s)" : (codeSent ? "重新发送验证码" : "发送验证码"))
                }
                .disabled(working || resendIn > 0 || !email.contains("@"))
                Spacer()
                Button("登录") {
                    doLogin()
                }
                .bold()
                .disabled(working || code.count < 4 || !email.contains("@"))
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(isError ? Color.red : Color.green)
            }
        } header: {
            Text("邮箱验证码登录")
        } footer: {
            Text("验证码 10 分钟内有效，60 秒内只能发送一次。收藏与播放进度将同步到云端，多端保持一致。")
        }
    }

    // MARK: - 已登录区

    private func loggedInSection(_ engine: SyncEngine) -> some View {
        Group {
            Section {
                HStack {
                    Label("当前账号", systemImage: "person.crop.circle")
                    Spacer()
                    Text(engine.email ?? "—")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } header: {
                Text("账号")
            }
            Section {
                HStack {
                    Text("上次同步")
                    Spacer()
                    Text(engine.lastSyncAtMs > 0 ? Self.timeText(engine.lastSyncAtMs) : "尚未同步")
                        .foregroundStyle(.secondary)
                }
                if engine.pendingOps > 0 {
                    HStack {
                        Text("待补传变更")
                        Spacer()
                        Text("\(engine.pendingOps) 条")
                            .foregroundStyle(.orange)
                    }
                }
                if engine.syncing {
                    HStack {
                        Text("正在同步…")
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let msg = engine.lastMessage {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button {
                    Task { await engine.syncNow() }
                } label: {
                    Text("立即同步")
                }
                .disabled(engine.syncing)
            } header: {
                Text("同步")
            } footer: {
                Text("断网时的变更自动在本机排队，联网后自动补传。")
            }
            Section {
                Button(role: .destructive) {
                    Task {
                        working = true
                        await engine.logout()
                        working = false
                    }
                } label: {
                    Text("退出登录")
                }
                .disabled(engine.syncing)
            }
        }
    }

    // MARK: - 动作

    private func sendCode() {
        guard let engine = container?.syncEngine else { return }
        working = true
        message = nil
        Task {
            do {
                let resend = await engine.requestCode(email: email.trimmingCharacters(in: .whitespaces))
                codeSent = true
                isError = false
                message = "验证码已发送到邮箱，请注意查收"
                startCountdown(max(30, resend))
            } catch {
                isError = true
                message = friendly(error)
            }
            working = false
        }
    }

    private func doLogin() {
        guard let engine = container?.syncEngine else { return }
        working = true
        message = nil
        Task {
            do {
                try await engine.login(email: email.trimmingCharacters(in: .whitespaces),
                                       code: code.trimmingCharacters(in: .whitespaces))
            } catch {
                isError = true
                message = friendly(error)
            }
            working = false
        }
    }

    private func startCountdown(_ secs: Int) {
        countdownTask?.cancel()
        resendIn = secs
        countdownTask = Task {
            while resendIn > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                resendIn -= 1
            }
        }
    }

    private func friendly(_ error: Error) -> String {
        if let e = error as? SyncCloudError { return e.errorDescription ?? e.message }
        if let e = error as? URLError, e.code == .timedOut {
            return "云端响应超时：免费版云函数单次限 3 秒，首次登录时云端初始化建表可能超时，请稍等后重试"
        }
        return "请求失败：\(error.localizedDescription)"
    }

    private static func timeText(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
