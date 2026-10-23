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
                // CI 返修：StrideTo<Int> 不满足 RandomAccessCollection，包 Array 后再入 ForEach
                ForEach(Array(stride(from: 0, to: 24 * 60, by: 15)), id: \.self) { total in
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

/// build 21 · 反馈 1：播放器设置面板（播放模式）。
/// build 25（对齐安卓 v1.3.0 item 8）：新增片头/片尾跳过两行时长选择器
/// （安卓 PlayerSettingsSheet + SkipSliderRow 等价移植：Slider 0–300 每 5 秒一档、
/// 0 显示「关闭」、底部说明文案），按书持久化（SkipSettingsStore）。
struct PlayerSettingsSheet: View {
    /// 当前书片头跳过秒数（build 25）
    let introSec: Int
    /// 当前书片尾跳过秒数（build 25）
    let outroSec: Int
    /// build 25：拖动结束回调（对齐安卓 onValueChangeFinished）
    let onIntroChange: (Int) -> Void
    let onOutroChange: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // build 27：删除播放模式分区（用户反馈精简设置面板）——
                // 播放模式枚举与 chapterFinishedAction 决策逻辑保留在 PlaybackManager，
                // 仅移除面板入口（PlayMode 相关行为回归不受影响，功能仍可用代码层调用）。
                // build 25（对齐安卓 PlayerSettingsSheet 面板形态）
                Section("片头/片尾跳过") {
                    SkipSliderRow(label: "片头跳过", valueSec: introSec, onValueChangeFinished: onIntroChange)
                    SkipSliderRow(label: "片尾跳过", valueSec: outroSec, onValueChangeFinished: onOutroChange)
                }
                Section {
                    Text("片头跳过：新章自动跳转到指定秒数；片尾跳过：播放到剩余时长时自动切下一章。\n（对本书生效，恢复播放时保留上次进度）")
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

/// build 25（对齐安卓 SkipSliderRow）：时长选择行——Slider 0–300 每 5 秒一档，
/// 右侧实时显示「关闭」或「N 秒」，拖动结束才落值（不逐档写库）。
private struct SkipSliderRow: View {
    let label: String
    let valueSec: Int
    let onValueChangeFinished: (Int) -> Void
    @State private var sliderValue: Double
    /// 对齐安卓：valueRange 0f..300f、steps 59（0, 5, 10, …, 300 共 61 档）
    private static let maxSlider = 300.0

    init(label: String, valueSec: Int, onValueChangeFinished: @escaping (Int) -> Void) {
        self.label = label
        self.valueSec = valueSec
        self.onValueChangeFinished = onValueChangeFinished
        _sliderValue = State(initialValue: Double(valueSec))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(sliderValue == 0 ? "关闭" : "\(Int(sliderValue)) 秒")
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }
            Slider(value: $sliderValue, in: 0...Self.maxSlider, step: 5) { editing in
                if !editing {
                    onValueChangeFinished(Int(sliderValue))
                }
            }
        }
        .padding(.vertical, 2)
    }
}
