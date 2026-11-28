import SwiftUI
import UIKit

struct MineScreen: View {
    @Environment(\.appContainer) private var container
    @State private var showSourceManage = false
    @State private var checkingUpdate = false
    @State private var updateInfo: UpdateInfo?
    @State private var showUpdateDialog = false
    @State private var showDownloadURL = false
    @State private var showingMessage = false
    @State private var updateMessage = ""

    /// 展示版本号：动态读 Bundle 的 CFBundleShortVersionString / CFBundleVersion，
    /// 与 project.yml 构建设置永远同源，杜绝静态字面量漂移。
    static var displayVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("听书数据") {
                    HStack {
                        Label("总时长", systemImage: "headphones")
                        Spacer()
                        Text(formatTime(container?.listeningTimeStore.totalMs ?? 0))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("今日时长", systemImage: "clock")
                        Spacer()
                        Text(formatTime(container?.listeningTimeStore.todayMs ?? 0))
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink("我的书架") {
                        ShelfScreen(onOpenPlayer: {})
                    }
                }

                Section("外观") {
                    NavigationLink("外观模式") {
                        ThemePickerScreen()
                    }
                }

                Section("音源") {
                    NavigationLink("音源管理") {
                        SourceManageScreen()
                    }
                }

                Section("其他") {
                    Button {
                        Task { await checkUpdate() }
                    } label: {
                        HStack {
                            Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if checkingUpdate {
                                ProgressView()
                            } else {
                                Text("当前 v\(UpdateInfo.currentVersion) · 对比 GitHub Release")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.pressable)
                    .disabled(checkingUpdate)
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        // 从 Bundle 动态读版本号，杜绝静态字面量与构建版本漂移
                        Text("\(Self.displayVersion)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("我的")
        }
        .alert("检查更新", isPresented: $showingMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text(updateMessage)
        }
        .overlay {
            if let info = updateInfo, showUpdateDialog {
                updateDialog(info)
            }
        }
    }

    @MainActor
    private func checkUpdate() async {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        defer { checkingUpdate = false }
        do {
            let info = try await AppUpdate.check()
            updateInfo = info
            if info.hasNewer {
                showDownloadURL = false
                showUpdateDialog = true
            } else {
                updateMessage = "已是最新版本"
                showingMessage = true
            }
        } catch {
            updateMessage = error.localizedDescription
            showingMessage = true
        }
    }

    @MainActor
    private func openDownload(for info: UpdateInfo) {
        showUpdateDialog = false
        guard let url = URL(string: info.htmlUrl) else { return }
        UIApplication.shared.open(url)
    }

    private func updateDialog(_ info: UpdateInfo) -> some View {
        ZStack {
            Color.black.opacity(0.38).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text("发现新版本")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(info.versionLine)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                ScrollView {
                    Text(info.changelog.isEmpty ? "暂无更新说明" : info.changelog)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .frame(maxHeight: 220)
                .padding(.top, 14)

                Button {
                    withAnimation { showDownloadURL.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showDownloadURL ? "chevron.down" : "chevron.right")
                        Text("下载地址")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 10)

                if showDownloadURL {
                    Text(info.htmlUrl)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }

                HStack(spacing: 12) {
                    Button {
                        showUpdateDialog = false
                    } label: {
                        Text("稍后")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Button {
                        openDownload(for: info)
                    } label: {
                        Text("前往下载")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.primary)
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.top, 18)
            }
            .padding(22)
            .background(Color(uiColor: .systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 28)
        }
        .zIndex(100)
    }

    func formatTime(_ ms: Int64) -> String {
        let sec = ms / 1000
        let h = sec / 3600
        let m = (sec % 3600) / 60
        if h > 0 { return "\(h)小时\(m)分" }
        return "\(m)分钟"
    }
}

struct ThemePickerScreen: View {
    @Environment(\.appContainer) private var container

    private var themeMode: Int {
        container?.themeStore.themeMode ?? ThemeStore.MODE_FOLLOW_SYSTEM
    }

    var body: some View {
        List {
            themeRow("浅色", mode: ThemeStore.MODE_LIGHT)
            themeRow("深色", mode: ThemeStore.MODE_DARK)
            themeRow("跟随系统", mode: ThemeStore.MODE_FOLLOW_SYSTEM)
        }
        .navigationTitle("外观模式")
    }

    /// 统一选择行：按压反馈（.pressable）+ 选中高亮底色，选中态与按压态可区分
    private func themeRow(_ title: String, mode: Int) -> some View {
        let selected = themeMode == mode
        return Button {
            container?.themeStore.setMode(mode)
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .listRowBackground(
            Group { if selected { Color.accentColor.opacity(0.12) } }
        )
    }
}

extension View {
    func checkmark(_ show: Bool) -> some View {
        HStack {
            self
            Spacer()
            if show { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
    }
}
