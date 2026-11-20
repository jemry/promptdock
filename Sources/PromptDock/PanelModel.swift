import Combine
import Foundation
import PromptDockCore

enum PanelMode: Equatable {
    /// ⌥Space：检索并粘贴 snippet。
    case prompts
    /// ⌥⇧Space：对选中文字执行 action。
    case actions(selection: String)
}

enum ActionPhase: Equatable {
    case choosing
    case running
    case done
    case failed(String)
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var query = "" { didSet { recompute() } }
    @Published private(set) var results: [RankedPrompt] = []
    @Published var selection = 0
    @Published var notice: String?
    /// 每次面板显示时递增，触发搜索框重新获得焦点。
    @Published private(set) var focusRequest = 0
    /// 面板内嵌「新增提示词」表单（spec 8.1）：true 时主区域切换为表单。
    @Published var addingPrompt = false
    /// 面板内嵌「编辑提示词」表单（spec 8.1）：非 nil 时主区域切换为表单并回填该条目。
    @Published var editingPrompt: Prompt?

    /// 右键「删除」后等待确认的条目（spec 8.1）：非 nil 时面板顶部显示确认条。
    /// 不用 NSAlert / SwiftUI alert：弹窗会让面板失去焦点而自动关闭。
    @Published var pendingDelete: Prompt?

    /// 新增或编辑表单任一激活时为 true：按键路由按表单模式处理。
    var isFormActive: Bool { addingPrompt || editingPrompt != nil }

    /// 关闭表单回到列表（Esc / 取消按钮共用）。
    func dismissForm() {
        addingPrompt = false
        editingPrompt = nil
    }

    @Published private(set) var mode: PanelMode = .prompts
    @Published var phase: ActionPhase = .choosing
    @Published var output = ""
    @Published private(set) var activePrompt: Prompt?
    /// 本次执行发给模型的输入文本（选区或剪贴板），收藏词汇表时取它做原文。
    @Published private(set) var activeInput = ""
    @Published private(set) var activeOutputMode: OutputMode = .replace
    /// 当前调用的「服务 · 模型」，显示在结果面板标题栏。
    @Published private(set) var activeTargetLabel = ""
    /// 模型正在思考、尚未输出正文。
    @Published var isThinking = false
    /// ⌥Space 面板内通过 ✨ 直接跑模型的条目（spec 8.1）：非 nil 时面板处于结果阶段。
    @Published private(set) var runningPrompt: Prompt?
    /// 系统语音合成状态（spec 8.1）：🔊 按钮据此切换为 ⏹。
    @Published var isSpeaking = false
    /// 当前朗读文本的音标与释义（spec 9.4）：模型异步返回，标在 🔊 左侧；换朗读/返回/重开面板时清空。
    @Published var phonetic: PhoneticInfo?
    /// 本次结果是否已收藏到词汇表（spec 9.4）：⭐ 据此变实心。
    @Published var favorited = false
    /// 收藏进行中（模型提炼词条正文）：⭐ 转进度圈，防连点。
    @Published var favoriting = false
    /// 剪贴板是否可 ✨ 直接跑模型：面板打开时读取一次；空剪贴板下 ✨ 禁用（点错不弹警告）。
    @Published var clipboardHasText = false

    private var allPrompts: [Prompt] = []
    private var frecency: [String: Double] = [:]

    var selected: RankedPrompt? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    var selectionText: String {
        if case .actions(let text) = mode {
            // 无选区输入回退（spec 8.1）：读取不到选区时，搜索框输入的内容就是待处理文本
            return text.isEmpty ? query : text
        }
        return ""
    }

    /// 动作面板无选区（未选中/读取失败）时的输入回退模式：输入框输入待处理内容，
    /// 列表不过滤保持全量（输入的是问题不是搜索词），回车把输入文本当选区执行。
    var isInputFallbackMode: Bool {
        if case .actions(let text) = mode { return text.isEmpty }
        return false
    }

    func prepare(mode: PanelMode, prompts: [Prompt], frecency: [String: Double], notice: String?) {
        self.mode = mode
        self.allPrompts = prompts
        self.frecency = frecency
        self.notice = notice
        phase = .choosing
        output = ""
        activePrompt = nil
        runningPrompt = nil
        phonetic = nil
        favorited = false
        favoriting = false
        activeInput = ""
        addingPrompt = false
        editingPrompt = nil
        pendingDelete = nil
        query = ""          // 触发 recompute
        recompute()
        focusRequest += 1
    }

    func update(prompts: [Prompt]) {
        allPrompts = prompts
        recompute()
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    func beginAction(_ prompt: Prompt, input: String, output mode: OutputMode, targetLabel: String) {
        activePrompt = prompt
        activeInput = input
        activeOutputMode = mode
        activeTargetLabel = targetLabel
        isThinking = false
        output = ""
        phonetic = nil
        favorited = false
        favoriting = false
        phase = .running
    }

    /// ⌥Space 面板内 ✨ 直接跑模型（spec 8.1）：输入为剪贴板文本，结果只显示不覆盖，↩ 复制。
    func beginPromptRun(_ prompt: Prompt, input: String, targetLabel: String) {
        runningPrompt = prompt
        beginAction(prompt, input: input, output: .show, targetLabel: targetLabel)
    }

    /// 结果页返回动作列表（spec 9.4）：不关面板，清空本次结果，焦点回搜索框，选区保留可重跑。
    func backToChoosing() {
        phase = .choosing
        output = ""
        isThinking = false
        activePrompt = nil
        runningPrompt = nil
        phonetic = nil
        favorited = false
        favoriting = false
        activeInput = ""
        notice = nil
        query = ""          // 触发 recompute，列表回到完整动作列表
        focusRequest += 1
    }

    private func recompute() {
        let wanted: PromptType = mode == .prompts ? .snippet : .action
        let visible = allPrompts.filter { $0.type == wanted }
        // 输入回退模式不过滤：输入框承载待处理内容，动作列表始终全量可选
        results = isInputFallbackMode
            ? Matcher.rank(prompts: visible, frecency: frecency, query: "")
            : Matcher.rank(prompts: visible, frecency: frecency, query: query)
        selection = 0
    }
}
