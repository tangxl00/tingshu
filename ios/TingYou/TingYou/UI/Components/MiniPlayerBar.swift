import SwiftUI

/**
 * 吸底迷你播放条（对应 Android MiniPlayerBar）。
 * - 无播放会话时整体隐藏、不占位
 * - 封面 + 书名 + 章节名 + 播放/暂停按钮
 * - 点击条身进入播放器页（同队列续播）
 * - 播放/暂停按钮只切换播放、不跳转
 */
struct MiniPlayerBar: View {
    @Environment(\.appContainer) private var container
    let onTap: () -> Void

    private var pm: PlaybackManager? { container?.playbackManager }
    private var hasMedia: Bool {
        guard let pm = pm else { return false }
        return !pm.currentAlbumTitle.isEmpty
    }

    var body: some View {
        Group {
            if hasMedia {
                HStack(spacing: 10) {
                    // Cover (tap -> player)
                    Button(action: onTap) {
                        CoverImage(url: pm?.coverUrl, size: 40, source: pm?.currentAlbum?.source)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    // Title + chapter (tap -> player)
                    Button(action: onTap) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pm?.currentAlbumTitle.isEmpty == false ? pm!.currentAlbumTitle : "正在播放")
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(pm?.currentChapterTitle.isEmpty == false ? pm!.currentChapterTitle : "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Play/Pause button
                    Button(action: {
                        pm?.togglePlayPause()
                    }) {
                        Image(systemName: (pm?.isPlaying ?? false) ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.accentColor)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    // build 45.2 · CI 第二轮（反馈 2 修复）：mini 播放/暂停按钮
                    // 补无障碍锚（与 PlayerScreen 同口径）——此前纯 SF Symbol
                    // 无文本，XCUITest「暂停」判据看不见 mini 栏的播放态
                    //（用例 H 的判据锚错面：点集后 App 停在详情页 + MiniPlayerBar）。
                    // 顺带是 VoiceOver 正确行为。
                    .accessibilityLabel((pm?.isPlaying ?? false) ? "暂停" : "播放")
                    .accessibilityIdentifier("mini_play_pause")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 4)
                .padding(.horizontal, 12)
            }
        }
    }
}
