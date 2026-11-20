import AppKit
import PromptDockCore
import SwiftUI

/// 不抢占前台应用激活状态、但能接收键盘输入的浮动面板（spec 8.2 第 2 步）。
final class FloatingPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { standardWindowButton($0)?.isHidden = true }
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class PromptPanelController: NSObject, NSWindowDelegate {
    let model = PanelModel()
    /// 回车 / ⌘回车：由调用方根据当前模式与阶段决定行为。
    var onCommand: (PanelCommand) -> Void = { _ in }
    /// 面板关闭（Esc、点击外部、被隐藏）时调用，用于取消进行中的请求。
    var onClose: () -> Void = {}
    /// 面板内新增表单保存：转发给 AppDelegate，返回 nil 成功。
    var onAddPrompt: (String, [String], String) -> String? = { _, _, _ in nil }
    /// 编辑表单保存：（打开表单时的原条目、名称、关键词、内容）→ 返回 nil 成功。
    var onUpdatePrompt: (Prompt, String, [String], String) -> String? = { _, _, _, _ in nil }
    /// 删除条目：id → 返回 nil 成功。
    var onDeletePrompt: (String) -> String? = { _ in nil }
    /// 结果页/生成中返回时，若有进行中的模型请求则取消（AppDelegate 接线）。
    var onBackFromResult: () -> Void = {}
    /// ✨ 直接跑模型（剪贴板输入），由 AppDelegate 实现。
    var onRunPrompt: (Prompt) -> Void = { _ in }
    /// 表单内「生成关键词」：内容文本 → 关键词（回调，空=失败）。
    var onGenerateKeywords: (String, @escaping ([String]) -> Void) -> Void = { _, _ in }
    /// 🔊 朗读时查音标：文本 → 音标与释义（回调，nil=无结果或不适用），由 AppDelegate 实现。
    var onLookupPhonetic: (String, @escaping (PhoneticInfo?) -> Void) -> Void = { _, _ in }
    /// ⭐ 收藏到词汇表：（原文、模型解释、音标释义，回调 nil=成功），由 AppDelegate 实现。
    var onFavorite: (String, String, PhoneticInfo?, @escaping (FavoriteResult) -> Void) -> Void = { _, _, _, _ in }
    /// 🔊 朗读开关（选中原文 / 模型输出），由内部 SpeechService 实现。
    private let speech = SpeechService()

    private let panel = FloatingPanel()
    private var keyMonitor: Any?
    /// 音标查询令牌：新朗读开始时递增，迟到的查询结果按令牌丢弃（对齐关键词生成的迟到处理）。
    private var phoneticToken = 0

    var isVisible: Bool { panel.isVisible }

    override init() {
        super.init()
        panel.delegate = self
        // 朗读状态同步到面板模型，两个 🔊 按钮据此切换形态（任意一处朗读中，两处都显示 ⏹）
        speech.onStateChanged = { [weak self] speaking in
            self?.model.isSpeaking = speaking
        }
        let host = PanelHostingView(rootView: PromptPanelView(
            model: model,
            onActivate: { [weak self] command in _ = self?.handle(command) },
            onAddPrompt: { [weak self] title, keywords, content in
                // 不能写 `self?.onAddPrompt(...) ?? "保存失败"`：optional chaining 会把结果包成
                // String??，?? 只解一层，成功(nil) 会被错翻成 "保存失败"（实测踩坑）
                guard let self else { return "保存失败" }
                return self.onAddPrompt(title, keywords, content)
            },
            onUpdatePrompt: { [weak self] original, title, keywords, content in
                guard let self else { return "保存失败" }
                return self.onUpdatePrompt(original, title, keywords, content)
            },
            onDeletePrompt: { [weak self] id in
                guard let self else { return "删除失败" }
                return self.onDeletePrompt(id)
            },
            onRunPrompt: { [weak self] prompt in self?.onRunPrompt(prompt) },
            onGenerateKeywords: { [weak self] content, completion in
                self?.onGenerateKeywords(content, completion) ?? completion([])
            },
            onBack: { [weak self] in self?.handleBackFromResult() },
            onToggleSpeech: { [weak self] text in self?.toggleSpeech(text) },
            onFavorite: { [weak self] source, explanation, phonetic, completion in
                guard let self else { completion(.failed("收藏失败")); return }
                self.onFavorite(source, explanation, phonetic, completion)
            }
        ))
        // 透明标题栏区域默认算作安全区，内容会让出这一条，露出白色窗口底色；让内容铺满整个窗口
        host.safeAreaRegions = []
        // 面板固定浅色外观：毛玻璃与文字语义色都按浅色解析。
        // 深色壁纸下 behindWindow 混合会把 popover 材质拖成灰紫，主题绿叠上去发闷（用户反馈）
        host.appearance = NSAppearance(named: .vibrantLight)
        panel.contentView = host
    }

    func show(mode: PanelMode, prompts: [Prompt], frecency: [String: Double], notice: String?) {
        // 打开时读一次剪贴板可跑性：空剪贴板 ✨ 直接禁用，误触不再弹橙色警告（引导进 tooltip）
        model.clipboardHasText = (NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        model.prepare(mode: mode, prompts: prompts, frecency: frecency, notice: notice)
        position()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeKeyMonitor()
        speech.stop()   // 面板关闭即停读
        phoneticToken += 1   // 在途音标查询作废
        onClose()
    }

    func update(prompts: [Prompt]) {
        model.update(prompts: prompts)
    }

    // 失去焦点（点到别处）时关闭
    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { hide() }
    }

    /// 返回 true 表示命令已处理（事件吞掉），false 表示当前场景不适用（放行给输入控件）。
    @discardableResult
    private func handle(_ command: PanelCommand) -> Bool {
        // 表单模式（新增/编辑）：Esc 关闭表单回到列表；其余按键（回车、↑↓、←）交给表单控件
        if model.isFormActive {
            if command == .close {
                model.dismissForm()
                return true
            }
            return false
        }
        switch command {
        case .moveUp:
            if model.phase == .choosing { model.move(-1) }
            return true
        case .moveDown:
            if model.phase == .choosing { model.move(1) }
            return true
        case .close:
            hide()
            return true
        case .paste, .copy:
            onCommand(command)
            return true
        case .select(let index):
            // 数字直选：仅选择阶段且搜索框为空时生效（正在输入时数字是内容，放行给输入框）。
            // 输入回退模式下输入框是待处理内容，首字符可能就是数字（如「1+1 等于几」），一律放行
            guard model.phase == .choosing, model.query.isEmpty, !model.isInputFallbackMode,
                  model.results.indices.contains(index - 1) else { return false }
            model.selection = index - 1
            onCommand(.paste)
            return true
        case .back:
            // ← 只在结果/生成中阶段有意义（动作面板或 ✨ 跑模型）；列表与搜索框里放行（光标移动）
            guard model.phase != .choosing, model.mode != .prompts || model.runningPrompt != nil else { return false }
            handleBackFromResult()
            return true
        }
    }

    /// 结果页/生成中返回动作列表：生成中先取消请求，朗读同步停止，再清状态回列表，选区保留可重跑。
    private func handleBackFromResult() {
        speech.stop()   // 返回列表后没有可停止的按钮，不能让声音悬空继续读
        phoneticToken += 1
        if model.phase == .running { onBackFromResult() }
        model.backToChoosing()
    }

    /// 🔊 点击：停止当前朗读；或开始朗读并异步查音标，结果标在按钮右边。
    private func toggleSpeech(_ text: String) {
        if speech.isSpeaking {
            speech.stop()
            return
        }
        model.phonetic = nil
        speech.speak(text)
        phoneticToken += 1
        let token = phoneticToken
        onLookupPhonetic(text) { [weak self] info in
            guard let self, token == self.phoneticToken, let info else { return }
            self.model.phonetic = info
        }
    }

    /// 在鼠标所在屏幕水平居中、偏上显示。
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + frame.height * 0.72 - size.height / 2
        ))
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let composing = (self.panel.firstResponder as? NSTextView)?.hasMarkedText() ?? false
            guard let command = PanelKeyRouter.command(
                keyCode: event.keyCode,
                commandKey: event.modifierFlags.contains(.command),
                hasMarkedText: composing
            ) else { return event }
            // handle 返回 false 表示该命令在当前场景不适用（如 ← 在搜索框里），事件放行给输入控件
            return self.handle(command) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
