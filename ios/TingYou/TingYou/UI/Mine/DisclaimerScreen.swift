import SwiftUI

/// v2.0.0：免责声明独立页面，5 条文案与 Android 端逐字一致。
struct DisclaimerScreen: View {
    private static let items: [String] = [
        "1.应用内所有音频、封面、文字等内容均来自第三方平台的公开链接，版权归原作者及相关权利人所有。本应用不存储、不修改、不二次分发任何内容。",
        "2.内容仅供个人学习、研究与试听交流使用，请勿用于任何商业用途;请勿下载、录制或传播相关内容",
        "3.请在试听后支持正版:如喜欢某部作品，建议前往官方平台购买、订阅或支持作者。",
        "4.若权利人认为本应用侵犯其合法权益，请告知开发者，我们将在核实后及时处理(包括但不限于移除相关入口)。",
        "5.因使用本应用产生的任何直接或间接后果，由使用者自行承担。",
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.items, id: \.self) { item in
                    Text(item)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 2)
                }
            } header: {
                Text("免责声明")
            }
        }
        .navigationTitle("免责声明")
        .navigationBarTitleDisplayMode(.inline)
    }
}
