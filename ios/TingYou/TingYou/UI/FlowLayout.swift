import SwiftUI

/// build 49 · 问题 2（历史搜索词条重叠）修复：流式布局（flow layout）。
///
/// 取代 b36 起历史词条的 `LazyVGrid(columns: [.adaptive(minimum: 44)])`
/// 等宽列形态——adaptive 列宽按「可用宽度 ÷ (minimum + spacing)」等宽切列，
/// 而 chip 带 `.fixedSize()` 报告完整固有宽度，超出列宽即以列锚点溢出渲染，
/// **相邻列 chip 横向叠压**（真机 b49 取证：《水泫》《凡人修仙传》两颗 chip
/// 被叠进同一胶囊、只露出一个删除按钮——「历史搜索记录还是有重叠」）。
///
/// Layout 协议（iOS 16+，本项目 deploymentTarget 17.0）逐子视图按固有宽度
/// 累进排布：当前行放不下即折行，行高取该行最高子视图，子视图永远按实测
/// 尺寸、实测位置放置——排布由累进坐标唯一决定，数学上不存在两条 chip
/// 重叠的路径。一行放不下自动折行、任意条数自然铺开的「全量换行显示」
/// 语义（b48 需求 1）不变。
///
/// 已知边界：单颗 chip 固有宽度超过可用宽度（超长搜索词）时独占一行并
/// 向右溢出裁剪——与 b45 起的既有行为一致（fixedSize 横排形态的固有边界，
/// 非本次回归），历史词条来自用户搜索框输入，实际不会超出屏宽。
struct FlowLayout: Layout {
    /// 同一行内相邻 chip 的水平间距。
    var horizontalSpacing: CGFloat = 8
    /// 行与行之间的垂直间距。
    var verticalSpacing: CGFloat = 6

    /// 单遍累进排布：返回每颗 chip 的 topLeading 偏移与整体尺寸。
    /// maxWidth 非 finite（提案无宽）时不折行，单行铺开。
    private func flowPositions(maxWidth: CGFloat, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        positions.reserveCapacity(subviews.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0
        for subview in subviews {
            // chip 自带 .fixedSize()：.unspecified 提案下报告完整固有尺寸
            let size = subview.sizeThatFits(.unspecified)
            // 折行判定：当前行已有内容且这颗放不下（首颗不折行——超宽独占一行）
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
            contentWidth = max(contentWidth, x - horizontalSpacing)
        }
        let height = subviews.isEmpty ? 0 : y + rowHeight
        return (positions, CGSize(width: contentWidth, height: height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        return flowPositions(maxWidth: maxWidth, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // 与 sizeThatFits 同一提案口径计算折行（Layout 协议保证 placeSubviews
        // 收到的 proposal 与驱动 sizeThatFits 的提案一致），杜绝「量宽与放宽
        // 口径不一致导致的位置漂移」。
        let maxWidth = proposal.width ?? .infinity
        let positions = flowPositions(maxWidth: maxWidth, subviews: subviews).positions
        for (subview, position) in zip(subviews, positions) {
            subview.place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                          anchor: .topLeading,
                          proposal: .unspecified)
        }
    }
}
