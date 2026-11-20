import AppKit
import ApplicationServices
import PromptDockCore

/// 读取当前前台应用中选中的文本（spec 9.1）。依赖辅助功能权限。
@MainActor
enum SelectionService {

    enum Source: String { case accessibility, copy }

    /// 读取结果经 SelectionFilter 过滤：命中误判规则（如只有空白）按无选区处理（spec 9.2）。
    static func read() async -> (text: String, source: Source)? {
        if let raw = readViaAccessibility(), let text = SelectionFilter.accept(raw) { return (text, .accessibility) }
        if let raw = await readViaCopy() {
            guard let text = SelectionFilter.accept(raw) else {
                Log.info("降级读取到 \(raw.count) 字但判定为误判（空白），按无选区处理")
                return nil
            }
            return (text, .copy)
        }
        return nil
    }

    /// 优先：辅助功能接口直接读取焦点元素的选区。
    private static func readViaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, "AXFocusedUIElement" as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, "AXSelectedText" as CFString, &selected) == .success,
              let text = selected as? String, !text.isEmpty else { return nil }
        return text
    }

    /// 降级：模拟 ⌘C，最多等 300ms，读取后恢复原剪贴板。
    /// 部分 Electron 应用（VS Code、飞书等）辅助功能接口取不到选区，需要走这条路径。
    private static func readViaCopy() async -> String? {
        let pb = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(pb)
        let before = pb.changeCount

        KeyboardEvents.postCommand(key: 8)   // kVK_ANSI_C

        var text: String?
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(20))
            if pb.changeCount != before {
                text = pb.string(forType: .string)
                break
            }
        }
        if pb.changeCount != before { snapshot.restore(to: pb) }
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

enum KeyboardEvents {
    /// 发送 ⌘ + 指定虚拟键码。
    /// 按下并松开一个键，可带修饰键。
    static func post(key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func postCommand(key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
