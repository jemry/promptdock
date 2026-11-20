public enum PanelCommand: Sendable, Equatable {
    case moveUp, moveDown, paste, copy, close, back
    /// 数字键 1-9 直选列表第 N 条并触发（仅选择阶段且未在搜索时生效）。
    case select(Int)
}

/// 面板内按键到命令的映射（spec 8.1）。
public enum PanelKeyRouter {
    /// 数字键 1-9、0 的 keyCode（苹果键盘物理布局乱序：5 在 23、6 在 22 等）；0 映射第 10 条。
    public static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]

    /// - Parameter hasMarkedText: 输入法是否正在组字。组字时所有按键交给输入法处理。
    public static func command(keyCode: UInt16, commandKey: Bool, hasMarkedText: Bool) -> PanelCommand? {
        guard !hasMarkedText else { return nil }
        if !commandKey, let digit = Self.digitKeyCodes.firstIndex(of: keyCode) {
            return .select(digit + 1)   // 数字直选（10 = 0 键）；是否生效由面板按场景判断（搜索中放行给输入框）
        }
        switch keyCode {
        case 126: return .moveUp
        case 125: return .moveDown
        case 36, 76: return commandKey ? .copy : .paste   // Return / 小键盘 Enter
        case 53: return .close
        case 123: return .back                             // ←：动作结果页返回列表，其余场景放行
        default: return nil
        }
    }
}
