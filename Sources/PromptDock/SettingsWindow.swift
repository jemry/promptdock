import AppKit
import PromptDockCore
import SwiftUI

/// 设置窗口（spec 9.5）：通用、模型服务、提示词三页，保存时只重写 prompts.yaml 中有变化的段。
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    /// 返回 nil 表示成功，否则为错误信息。
    var onSave: ((PromptLibrary, PromptLibrary) -> String?)?
    /// 快捷键录制开始 / 结束，用于暂停和恢复全局快捷键。
    var onHotkeyRecording: ((Bool) -> Void)?

    func show(library: PromptLibrary, tab: SettingsTab = .general) {
        let model = SettingsModel(library: library)
        model.tab = tab
        model.onSave = { [weak self] base, target in self?.onSave?(base, target) }
        model.onHotkeyRecording = { [weak self] in self?.onHotkeyRecording?($0) }
        let host = NSHostingController(rootView: SettingsView(model: model))
        if let window {
            window.contentViewController = host
        } else {
            let w = NSWindow(contentViewController: host)
            w.title = "PromptDock 设置"
            w.styleMask = NSWindow.StyleMask(arrayLiteral: .titled, .closable, .miniaturizable, .resizable)
            w.setContentSize(NSSize(width: 860, height: 620))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsTab: String { case general, providers, prompts }

struct ProviderRow: Identifiable, Equatable {
    let id = UUID()
    var form: ProviderForm
    /// 新增且未保存的服务可以改名；已有服务改名会让引用它的条目和钥匙串记录失效，不允许。
    var isNew: Bool
}

struct PromptRow: Identifiable, Equatable {
    let id = UUID()
    var form: PromptForm
    /// id 关联使用记录（frecency），已保存的条目不允许改 id。
    var isNew: Bool
}

@MainActor @Observable
final class SettingsModel {
    var general: GeneralForm
    var rows: [ProviderRow]
    var defaultProvider: String
    var tab = SettingsTab.general
    var selection: ProviderRow.ID?
    var keyStatus: [String: Bool] = [:]
    var keyInput = ""
    var message: String?
    var isError = false
    /// 快捷键录制被拒绝的原因（按提示词面板 / 动作面板分别显示）。
    var hotkeyHint: [String: String] = [:]
    var onHotkeyRecording: ((Bool) -> Void)?
    var prompts: [PromptRow]
    var promptSelection: PromptRow.ID?
    var promptQuery = ""
    private var base: PromptLibrary
    var onSave: ((PromptLibrary, PromptLibrary) -> String?)?

    init(library: PromptLibrary) {
        base = library
        let settings = library.settings
        let promptRows = library.prompts.map { PromptRow(form: PromptForm($0), isNew: false) }
        prompts = promptRows
        promptSelection = promptRows.first?.id
        general = GeneralForm(settings)
        rows = settings.providers.keys.sorted().compactMap { settings.providers[$0] }
            .map { ProviderRow(form: ProviderForm($0), isNew: false) }
        defaultProvider = settings.llm.provider
        selection = rows.first(where: { $0.form.name == settings.llm.provider })?.id ?? rows.first?.id
        refreshKeyStatus()
    }

    var selectedIndex: Int? { rows.firstIndex { $0.id == selection } }

    func refreshKeyStatus() {
        // 只查是否存在，不读取内容（不会触发钥匙串授权框）
        keyStatus = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.form.name, KeychainStore.hasAPIKey(provider: $0.form.name))
        })
    }

    func addProvider() {
        var name = "new"
        var n = 2
        while rows.contains(where: { $0.form.name == name }) { name = "new\(n)"; n += 1 }
        let row = ProviderRow(form: ProviderForm(name: name, baseURL: "https://", model: ""), isNew: true)
        rows.append(row)
        selection = row.id
    }

    func removeSelected() {
        guard let i = selectedIndex else { return }
        rows.remove(at: i)
        selection = rows.indices.contains(i) ? rows[i].id : rows.last?.id
    }

    func saveKey() {
        guard let i = selectedIndex else { return }
        let name = rows[i].form.name
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProviderForm.isValidName(name), !key.isEmpty else { return }
        let status = KeychainStore.saveAPIKey(key, provider: name)
        keyInput = ""
        if status == errSecSuccess {
            Log.info("已保存 \(name) 的 API Key")
            show("已保存「\(name)」的 API Key", error: false)
        } else {
            Log.error("保存 \(name) 的 API Key 失败：OSStatus \(status)")
            show("保存 API Key 失败：OSStatus \(status)", error: true)
        }
        refreshKeyStatus()
    }

    func clearKey() {
        guard let i = selectedIndex else { return }
        let name = rows[i].form.name
        KeychainStore.deleteAPIKey(provider: name)
        Log.info("已清除 \(name) 的 API Key")
        show("已清除「\(name)」的 API Key", error: false)
        refreshKeyStatus()
    }

    // MARK: 提示词

    var promptIndex: Int? { prompts.firstIndex { $0.id == promptSelection } }

    var filteredPrompts: [PromptRow] {
        let q = promptQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return prompts }
        return prompts.filter {
            [$0.form.title, $0.form.id, $0.form.keywords, $0.form.tags].contains { $0.lowercased().contains(q) }
        }
    }

    var providerNames: [String] { rows.map(\.form.name) }

    func addPrompt(type: PromptType) {
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)", timeZone: .current, calendar: .current))
        var id = "\(type == .action ? "action" : "prompt")-\(stamp)"
        var n = 2
        while prompts.contains(where: { $0.form.id == id }) { id = "\(id)-\(n)"; n += 1 }
        let content = type == .action ? "（在这里写指令）\n\n{selection}\n" : ""
        let row = PromptRow(form: PromptForm(id: id, title: type == .action ? "新动作" : "新提示词", type: type, content: content), isNew: true)
        prompts.append(row)
        promptQuery = ""
        promptSelection = row.id
    }

    func removeSelectedPrompt() {
        guard let i = promptIndex else { return }
        prompts.remove(at: i)
        let visible = filteredPrompts
        promptSelection = visible.indices.contains(i) ? visible[i].id : visible.last?.id
    }

    // MARK: 保存

    func save() {
        var target = base
        do {
            try general.apply(to: &target.settings)
            try ProviderListValidator.apply(rows.map(\.form), defaultProvider: defaultProvider, to: &target.settings)
            target.prompts = try PromptListValidator.validate(prompts.map(\.form), providers: Set(target.settings.providers.keys))
        } catch {
            show("\(error)", error: true)
            return
        }
        guard target != base else {
            show("没有改动", error: false)
            return
        }
        if let failure = onSave?(base, target) {
            show(failure, error: true)
            return
        }
        base = target
        for i in rows.indices { rows[i].isNew = false }
        for i in prompts.indices { prompts[i].isNew = false }
        refreshKeyStatus()
        show("已保存并生效", error: false)
    }

    private func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $model.tab) {
                GeneralTab(model: model).tabItem { Text("通用") }.tag(SettingsTab.general)
                ProvidersTab(model: model).tabItem { Text("模型服务") }.tag(SettingsTab.providers)
                PromptsTab(model: model).tabItem { Text("提示词") }.tag(SettingsTab.prompts)
            }
            .padding([.top, .horizontal], 12)

            HStack {
                if let message = model.message {
                    Text(message)
                        .foregroundStyle(model.isError ? Color.red : Color.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                Text("保存后写入 prompts.yaml（原文件备份为 prompts.yaml.bak）")
                    .font(.caption).foregroundStyle(.secondary)
                Button("保存") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(minWidth: 780, minHeight: 560)
        .tint(Color.dockAccent)
    }
}

private struct GeneralTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("快捷键") {
                hotkeyRow("提示词面板", key: "prompt", text: $model.general.promptPanel)
                hotkeyRow("动作面板", key: "action", text: $model.general.actionPanel)
                Text("点击后按下组合键录制，至少包含一个修饰键（⌃⌥⇧⌘）；Esc 取消。录制期间全局快捷键暂停")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("粘贴") {
                Toggle("粘贴后恢复原剪贴板", isOn: $model.general.restoreClipboard)
                Stepper(value: $model.general.restoreDelayMs, in: 0...5000, step: 100) {
                    Text("恢复延迟：\(model.general.restoreDelayMs) 毫秒")
                }
                .disabled(!model.general.restoreClipboard)
            }
            Section("模型") {
                Picker("Anthropic 默认 effort", selection: $model.general.effort) {
                    ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0).tag($0) }
                }
                Text("仅对 Anthropic 官方接口生效；单个服务可在「模型服务」页覆盖")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("网络") {
                TextField("HTTP 代理", text: $model.general.proxy, prompt: Text("留空跟随系统代理，例如 http://127.0.0.1:7890"))
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func hotkeyRow(_ title: String, key: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            HotkeyRecorder(
                text: text,
                onRecordingChange: { model.onHotkeyRecording?($0) },
                onHint: { model.hotkeyHint[key] = $0 }
            )
            .frame(width: 180, height: 24)
        }
        if let hint = model.hotkeyHint[key] {
            Text(hint).font(.caption).foregroundStyle(.red)
        }
    }
}

private struct ProvidersTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $model.selection) {
                    ForEach(model.rows) { row in
                        HStack {
                            Text(row.form.name.isEmpty ? "（未命名）" : row.form.name)
                            Spacer()
                            if row.form.name == model.defaultProvider {
                                Text("默认").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(row.id)
                    }
                }
                HStack(spacing: 4) {
                    Button { model.addProvider() } label: { Image(systemName: "plus") }
                    Button { model.removeSelected() } label: { Image(systemName: "minus") }
                        .disabled(model.selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 170)

            Divider()

            if let i = model.selectedIndex {
                ProviderDetail(model: model, index: i)
            } else {
                Text("点击 + 添加模型服务").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ProviderDetail: View {
    @Bindable var model: SettingsModel
    let index: Int

    private var form: Binding<ProviderForm> { $model.rows[index].form }

    var body: some View {
        let row = model.rows[index]
        Form {
            Section("服务") {
                if row.isNew {
                    TextField("名称", text: form.name, prompt: Text("字母、数字、- 和 _"))
                } else {
                    LabeledContent("名称", value: row.form.name)
                }
                Picker("协议", selection: form.protocolType) {
                    Text("OpenAI 兼容").tag(LLMProtocol.openai)
                    Text("Anthropic").tag(LLMProtocol.anthropic)
                }
                .pickerStyle(.segmented)
                TextField("地址", text: form.baseURL, prompt: Text(row.form.protocolType == .anthropic
                    ? "https://api.anthropic.com（不带 /v1）" : "https://api.deepseek.com 或 http://localhost:11434/v1"))
                TextField("模型", text: form.model)
                Toggle("设为默认服务", isOn: Binding(
                    get: { model.defaultProvider == row.form.name },
                    set: { if $0 { model.defaultProvider = row.form.name } }
                ))
            }
            Section("API Key") {
                let hasKey = model.keyStatus[row.form.name] ?? false
                LabeledContent("状态", value: hasKey ? "已设置（保存在系统钥匙串）"
                    : (row.form.protocolType == .openai ? "未设置（本地服务可不填）" : "未设置"))
                HStack {
                    SecureField("API Key", text: $model.keyInput, prompt: Text("粘贴新的 Key"))
                    Button("保存 Key") { model.saveKey() }
                        .disabled(model.keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("清除") { model.clearKey() }.disabled(!hasKey)
                }
            }
            Section("高级（可选）") {
                TextField("max_tokens", text: form.maxTokens, prompt: Text("留空使用默认值"))
                Picker("effort", selection: form.effort) {
                    Text("跟随通用设置").tag("")
                    ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0).tag($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("附加请求参数（JSON 对象，合并进请求体）")
                    TextEditor(text: form.extraBody)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 70)
                    Text("例如 DeepSeek 关闭思考 {\"thinking\": {\"type\": \"disabled\"}}；Ollama 关闭思考 {\"reasoning_effort\": \"none\"}")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.selection) { model.keyInput = "" }
    }
}

private struct PromptsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("搜索", text: $model.promptQuery, prompt: Text("搜索标题、id、关键词"))
                    .textFieldStyle(.roundedBorder)
                    .padding(6)
                List(selection: $model.promptSelection) {
                    ForEach(model.filteredPrompts) { row in
                        HStack {
                            Text(row.form.title.isEmpty ? "（无标题）" : row.form.title).lineLimit(1)
                            Spacer()
                            if row.form.type != .snippet {
                                Text(row.form.type == .action ? "动作" : "脚本")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(row.id)
                    }
                }
                HStack(spacing: 4) {
                    Menu {
                        Button("提示词（粘贴）") { model.addPrompt(type: .snippet) }
                        Button("动作（选中文字调用模型）") { model.addPrompt(type: .action) }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button { model.removeSelectedPrompt() } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(model.promptSelection == nil)
                    Spacer()
                    Text("\(model.prompts.count) 条").font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }
            .frame(width: 220)

            Divider()

            if let i = model.promptIndex {
                PromptDetail(model: model, index: i)
            } else {
                Text("选择左侧条目，或点击 + 新增").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct PromptDetail: View {
    @Bindable var model: SettingsModel
    let index: Int

    private var form: Binding<PromptForm> { $model.prompts[index].form }

    var body: some View {
        let row = model.prompts[index]
        Form {
            Section {
                TextField("标题", text: form.title)
                if row.isNew {
                    TextField("id", text: form.id, prompt: Text("唯一标识，保存后不可改"))
                } else {
                    LabeledContent("id", value: row.form.id)
                }
                if row.form.type == .script {
                    LabeledContent("类型", value: "脚本（暂不支持在此编辑类型）")
                } else {
                    Picker("类型", selection: form.type) {
                        Text("提示词（⌥Space 粘贴）").tag(PromptType.snippet)
                        Text("动作（⌥⇧Space 处理选中文字）").tag(PromptType.action)
                    }
                }
                TextField("关键词", text: form.keywords, prompt: Text("逗号分隔，用于快速搜索，如 fy, 翻译"))
                TextField("标签", text: form.tags, prompt: Text("逗号分隔，可选"))
            }
            Section(row.form.type == .action ? "指令（用 {selection} 表示选中的文字）"
                    : "内容（{{说明}} 是占位符：粘贴后光标停在第一个占位符并选中它）") {
                TextEditor(text: form.content)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
            }
            if row.form.type == .action {
                Section("模型与结果") {
                    Picker("服务", selection: form.provider) {
                        Text("默认服务（\(model.defaultProvider)）").tag("")
                        ForEach(model.providerNames, id: \.self) { Text($0).tag($0) }
                        if !row.form.provider.isEmpty, !model.providerNames.contains(row.form.provider) {
                            Text("\(row.form.provider)（不存在）").tag(row.form.provider)
                        }
                    }
                    TextField("模型", text: form.model, prompt: Text("留空使用该服务的默认模型"))
                    Picker("结果", selection: form.output) {
                        Text("默认（替换原文）").tag(OutputMode?.none)
                        Text("替换原文").tag(OutputMode?.some(.replace))
                        Text("复制到剪贴板").tag(OutputMode?.some(.copy))
                        Text("只显示").tag(OutputMode?.some(.show))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("系统提示词（可选）")
                        TextEditor(text: form.system)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 50)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
