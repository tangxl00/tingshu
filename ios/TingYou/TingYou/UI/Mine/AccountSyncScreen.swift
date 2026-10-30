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
        // build 52 · 条件 2（#140 P1）：进页自动同步 + 按 accessExpireAtMs 提前续期。
        // 原实现本页既无 syncNow 调用也无任何定时器，叠加「续期失败无重试」，
        // 真机待补传 1 条恒挂 3.5h 不自愈。验收口径：token 过期 + outbox 有待传
        // 条目时，不点任何按钮，待补传数自动清零。
        .task {
            guard let engine = container?.syncEngine else { return }
            await engine.onSyncPageEnter()
        }
        .onDisappear {
            // 离开页面停掉退避定时器（后台空转无意义；回前台由 didBecomeActive 兜底）
            container?.syncEngine.stopRetry()
        }
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
                    // build 52 · 条件 3（#140）：push 部分失败时 lastSyncAtMs 已不再刷新，
                    // 但界面上还要能看出「未完成」——否则「上次同步 昨天 20:13」会被误读成成功。
                    Text(syncStatusText(engine))
                        .foregroundStyle(syncStatusColor(engine))
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
                // build 52 · 条件 1（#140 P1）：续期状态必须可区分——
                // 瞬态（正在续期 / 稍后自动重试）用次要色 + 进度条，
                // 终局（需重新登录）用红色 + 明确动作，不再用一句「正在自动续期」混淆两者。
                renewalRow(engine)
                Button {
                    Task { await engine.syncNow() }
                } label: {
                    Text("立即同步")
                }
                .disabled(engine.syncing)
            } header: {
                Text("同步")
            } footer: {
                Text("断网时的变更自动在本机排队，联网后自动补传；同步失败会按 30 秒 / 2 分钟 / 10 分钟自动重试。")
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

    // MARK: - 同步状态呈现（build 52 · 条件 1 / 条件 3）

    /// 同步状态文案。**只有在真正全部成功之后才显示时间**；
    /// 一旦续期未完成或仍有未确认变更，优先显示「未完成」，避免「上次同步」被误读成成功。
    private func syncStatusText(_ engine: SyncEngine) -> String {
        if engine.renewalState.isTerminal { return "未完成 · 需重新登录" }
        if engine.renewalState.isRetrying { return "未完成 · 等待重试" }
        if engine.syncing { return "同步中…" }
        guard engine.lastSyncAtMs > 0 else { return "尚未同步" }
        return Self.timeText(engine.lastSyncAtMs)
    }

    private func syncStatusColor(_ engine: SyncEngine) -> Color {
        if engine.renewalState.isTerminal { return .red }
        if engine.renewalState.isRetrying { return .orange }
        return engine.lastSyncAtMs > 0 ? Color.secondary : Color.orange
    }

    /// 续期状态行。瞬态（进行中 / 稍后重试）与终局（需重新登录）必须视觉可分：
    /// - `.refreshing`     → 次要色 + 进度条 +「正在自动续期…」（真的在进行中）
    /// - `.retryScheduled` → 橙色 +「同步未完成，稍后自动重试」（可自动恢复，但不是成功态）
    /// - `.terminal`       → **红色** +「续期失败，请重新登录」（终局，点「立即同步」也不会自愈）
    /// - `.idle`           → 不显示
    @ViewBuilder
    private func renewalRow(_ engine: SyncEngine) -> some View {
        switch engine.renewalState {
        case .idle:
            EmptyView()
        case .refreshing:
            HStack(alignment: .top) {
                Text(SyncEngine.refreshingHeadline)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
        case .retryScheduled(let text):
            VStack(alignment: .leading, spacing: 2) {
                Text(SyncEngine.retryHeadline)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                if !text.isEmpty {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .terminal(let text):
            VStack(alignment: .leading, spacing: 2) {
                Text(SyncEngine.terminalHeadline)
                    .font(.footnote)
                    .foregroundStyle(.red)
                if !text.isEmpty {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                }
            }
        }
    }

    private func sendCode() {
        guard let engine = container?.syncEngine else { return }
        working = true
        message = nil
        Task {
            do {
                let resend = try await engine.requestCode(email: email.trimmingCharacters(in: .whitespaces))
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
