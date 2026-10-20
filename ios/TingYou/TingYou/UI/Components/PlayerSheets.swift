import SwiftUI

/// build 21 · 反馈 1：定时关闭弹窗。
/// build 20 只修了 applySleepTimer 的模式逻辑（SleepTimerTests 已覆盖），
/// 本弹窗只做接线：三模式 UI（播完当前章 / 倒计时 / 定点）写入 PlaybackManager.sleepConfig。
struct SleepTimerSheet: View {
    @Binding var config: SleepTimerConfig
    let onApply: (SleepTimerConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var draftMode: SleepTimerMode = .off
    @State private var draftMinutes: Int = 30
    @State private var draftMinuteOfDay: Int = 23 * 60

    private let minutePresets = [5, 10, 15, 30, 45, 60, 90]

    var body: some View {
        NavigationStack {
            List {
                modeSection
                if draftMode == .countdown { countdownSection }
                if draftMode == .scheduledTime { scheduledSection }
            }
            .navigationTitle("定时关闭")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", action: applyDraft)
                }
            }
        }
        .onAppear(perform: loadDraftFromConfig)
    }

    /// build 21 CI 返修：原 List 单表达式过大导致类型检查超时——拆为三个小节属性 + 两个动作方法。
    private var modeSection: some View {
        Section("模式") {
            modeRow(.off, title: "关闭", detail: "不启用定时")
            modeRow(.endOfChapter, title: "播完当前章", detail: "本章播放结束后停止")
            modeRow(.countdown, title: "倒计时", detail: "分钟后停止")
            modeRow(.scheduledTime, title: "定点", detail: "到指定时刻停止")
        }
    }

    private var countdownSection: some View {
        Section("倒计时时长（分钟）") {
            ForEach(minutePresets, id: \.self) { m in
                minuteRow(m)
            }
        }
    }

    private func minuteRow(_ m: Int) -> some View {
        let selected = draftMinutes == m
        return Button("\(m) 分钟") {
            draftMinutes = m
        }
        .checkmark(selected)
        .buttonStyle(.pressable)
        .listRowBackground(Group { if selected { Color.accentColor.opacity(0.12) } })
    }

    private var scheduledSection: some View {
        Section("定点时刻") {
            Picker("时刻", selection: $draftMinuteOfDay) {
                ForEach(stride(from: 0, to: 24 * 60, by: 15), id: \.self) { total in
                    Text(String(format: "%02d:%02d", total / 60, total % 60)).tag(total)
                }
            }
            .pickerStyle(.wheel)
        }
    }

    private func applyDraft() {
        var c = config
        c.mode = draftMode
        c.minutes = draftMinutes
        c.minuteOfDay = draftMinuteOfDay
        config = c
        onApply(c)
        dismiss()
    }

    private func loadDraftFromConfig() {
        draftMode = config.mode
        if config.minutes > 0 { draftMinutes = config.minutes }
        if config.minuteOfDay > 0 { draftMinuteOfDay = config.minuteOfDay }
    }

    private func modeRow(_ mode: SleepTimerMode, title: String, detail: String) -> some View {
        let selected = draftMode == mode
        return Button {
            draftMode = mode
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .checkmark(selected)
        .buttonStyle(.pressable)
        .listRowBackground(Group { if selected { Color.accentColor.opacity(0.12) } })
    }
}

/// build 21 · 反馈 1：播放器设置面板（最小集：播放模式）。
/// 播放模式逻辑在 PlaybackManager（chapterFinishedAction 纯函数），
/// 本面板只做选择 UI + setPlayMode 持久化接线。
struct PlayerSettingsSheet: View {
    @Binding var playMode: PlayMode
    let onSelect: (PlayMode) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("播放模式") {
                    ForEach(PlayMode.allCases) { mode in
                        let selected = playMode == mode
                        Button {
                            onSelect(mode)
                            playMode = mode
                        } label: {
                            HStack {
                                Label(mode.displayName, systemImage: mode.symbolName)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .checkmark(selected)
                        .buttonStyle(.pressable)
                        .listRowBackground(Group { if selected { Color.accentColor.opacity(0.12) } })
                    }
                }
                Section {
                    Text("顺序播放：播完最后一章后停止\n单曲循环：当前章播完后重播本章\n列表循环：最后一章播完后回到第一章")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("播放器设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
