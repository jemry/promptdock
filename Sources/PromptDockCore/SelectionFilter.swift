import Foundation

/// 选区误判过滤（spec 9.2）：有些应用没有选区时按 ⌘C 也会往剪贴板放内容，
/// 降级读取会把它当成选区。命中规则时返回 nil（按无选区处理，面板进入输入模式）。
public enum SelectionFilter {

    /// - Returns: 可用的选区文本（原样，不裁首尾空白——替换回原文时空白是原文的一部分）；不可用为 nil。
    public static func accept(_ text: String) -> String? {
        // VS Code 在空行上「复制整行」只得到换行符
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
