import AppKit
import Carbon.HIToolbox
import PromptDockCore
import SwiftUI

/// 设置窗口里的快捷键录制框（spec 9.5）：点击后按下组合键即录入，Esc / 再次点击 / 失去焦点取消。
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var text: String
    /// 录制开始 / 结束时回调，用于暂停和恢复全局快捷键。
    var onRecordingChange: (Bool) -> Void
    /// 录制被拒绝时的原因；开始新的录制或录制成功时清空（传 nil）。
    var onHint: (String?) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderView {
        let view = HotkeyRecorderView()
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        update(view)
        return view
    }

    func updateNSView(_ view: HotkeyRecorderView, context: Context) { update(view) }

    static func dismantleNSView(_ view: HotkeyRecorderView, coordinator: ()) { view.cancelRecording() }

    private func update(_ view: HotkeyRecorderView) {
        view.value = text
        view.onRecorded = { text = $0 }
        view.onRecordingChange = onRecordingChange
        view.onHint = onHint
    }
}

final class HotkeyRecorderView: NSView {
    var value = "" { didSet { if value != oldValue { needsDisplay = true } } }
    var onRecorded: ((String) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var onHint: ((String?) -> Void)?

    private(set) var isRecording = false
    /// 录制中当前按住的修饰键，实时显示。
    private var liveModifiers: HotkeySpec.Modifiers = []
    private var resignObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 24) }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            cancelRecording()
        } else {
            window?.makeFirstResponder(self)
            startRecording()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            // 键盘导航聚焦后，按空格或回车开始录制
            if event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Return) {
                startRecording()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        let modifiers = Self.modifiers(event.modifierFlags)
        if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            cancelRecording()
            return
        }
        do {
            let spec = try HotkeySpec.recorded(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            onHint?(nil)
            stopRecording()
            onRecorded?(spec.configString)
        } catch {
            onHint?("\(error)")
        }
    }

    /// ⌘ 组合键先走 performKeyEquivalent（会被「保存」按钮、编辑菜单截走），录制中在这里拦下。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        liveModifiers = Self.modifiers(event.modifierFlags)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard let window else {
            cancelRecording()
            return
        }
        // 窗口失去焦点（切到别的应用、关闭窗口）时取消录制，避免全局快捷键一直处于暂停状态
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording() }
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        stopRecording()
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        liveModifiers = []
        onHint?(nil)
        onRecordingChange?(true)
        needsDisplay = true
    }

    private func stopRecording() {
        isRecording = false
        liveModifiers = []
        onRecordingChange?(false)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (isRecording ? NSColor.dockAccent : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let label: String
        let color: NSColor
        if isRecording {
            label = liveModifiers.isEmpty ? "请按下快捷键…" : HotkeySpec.symbols(liveModifiers)
            color = .secondaryLabelColor
        } else {
            label = (try? HotkeySpec.parse(value))?.displayString ?? (value.isEmpty ? "点击录制" : value)
            color = .labelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: color,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> HotkeySpec.Modifiers {
        var m: HotkeySpec.Modifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }
}
