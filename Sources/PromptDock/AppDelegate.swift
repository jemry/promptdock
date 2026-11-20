import AppKit
import PromptDockCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let promptPanelHotkeyID: UInt32 = 1
    private static let actionPanelHotkeyID: UInt32 = 2
    /// 版本号以应用包 Info.plist 为准（构建时由 git tag 写入）。
    private static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? PromptDockCore.version

    private var statusItem: NSStatusItem?
    private var state = LibraryState()
    private var usage: UsageStore?
    private let hotkeys = HotkeyManager()
    private let panel = PromptPanelController()
    private let settingsWindow = SettingsWindowController()
    private let historyWindow = HistoryWindowController()
    /// 调用历史存储（懒加载，打开失败只记日志不影响主流程）。
    private var historyStore: HistoryStore?
    private var watcher: FileWatcher?
    private var hotkeyErrors: [UInt32: String] = [:]
    private var registeredHotkeys: [UInt32: String] = [:]
    /// 设置窗口录制快捷键期间暂停全局快捷键（spec 9.5），否则录不到已注册的组合。
    private var hotkeysPaused = false
    /// 进行中的模型调用；面板关闭时取消。
    private var actionTask: Task<Void, Never>?
    /// 执行动作时的目标应用（替换原文时粘贴回去）。
    private var actionTarget: NSRunningApplication?
    /// 最近一个处于前台的「其他」应用，粘贴目标。
    private var lastExternalApp: NSRunningApplication?

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("启动 PromptDock \(Self.appVersion)")
        MainMenu.install()
        trackFrontmostApp()
        ensureConfigExists()
        openUsageStore()
        setupStatusItem()

        panel.onCommand = { [weak self] command in self?.handlePanelCommand(command) }
        panel.onClose = { [weak self] in self?.cancelAction() }
        panel.onAddPrompt = { [weak self] title, keywords, content in
            guard let self else { return "保存失败" }
            return self.addPromptFromPanel(title: title, keywords: keywords, content: content)
        }
        panel.onUpdatePrompt = { [weak self] original, title, keywords, content in
            guard let self else { return "保存失败" }
            return self.updatePromptFromPanel(original: original, title: title, keywords: keywords, content: content)
        }
        panel.onDeletePrompt = { [weak self] id in
            guard let self else { return "删除失败" }
            return self.deletePromptFromPanel(id: id)
        }
        panel.onBackFromResult = { [weak self] in self?.cancelAction() }
        panel.onRunPrompt = { [weak self] prompt in self?.runPromptFromPanel(prompt) }
        panel.onGenerateKeywords = { [weak self] content, completion in
            self?.generateKeywords(content: content, completion: completion)
        }
        panel.onLookupPhonetic = { [weak self] text, completion in
            self?.lookupPhonetic(text, completion: completion)
        }
        panel.onFavorite = { [weak self] source, explanation, phonetic, completion in
            guard let self else { completion(.failed("收藏失败")); return }
            self.favoriteToVault(source: source, explanation: explanation, phonetic: phonetic, completion: completion)
        }
        settingsWindow.onSave = { [weak self] base, target in self?.saveLibrary(from: base, to: target) }
        settingsWindow.onHotkeyRecording = { [weak self] in self?.setHotkeysPaused($0) }

        reload()
        watcher = FileWatcher(file: Paths.configFile) { [weak self] in
            Log.info("检测到配置文件变化，重新加载")
            self?.reload()
        }

        if !PasteService.isTrusted {
            Log.info("未获得辅助功能权限，弹出系统授权提示")
            PasteService.requestTrust()
        }
    }

    /// promptdock://panel、promptdock://actions —— 便于脚本或其他工具调起面板（也用于截图验证）。
    /// actions 和 ⌥⇧Space 一样会先读取前台应用的选区。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "promptdock" {
            if url.host == "panel" { showPanel() }
            if url.host == "actions" { Task { await showActionPanel() } }
            if url.host == "settings" {
                let tab = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "tab" }?.value.flatMap(SettingsTab.init) ?? .general
                settingsWindow.show(library: state.library, tab: tab)
            }
        }
    }

    // MARK: - 配置

    private func ensureConfigExists() {
        let url = Paths.configFile
        let fm = FileManager.default
        let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
        guard !fm.fileExists(atPath: url.path), !isSymlink else { return }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let example = Bundle.main.url(forResource: "prompts.example", withExtension: "yaml") {
                try fm.copyItem(at: example, to: url)
            } else {
                try "version: 1\nprompts: []\n".write(to: url, atomically: true, encoding: .utf8)
            }
            Log.info("已生成示例配置：\(url.path)")
        } catch {
            Log.error("生成示例配置失败：\(error)")
        }
    }

    private func reload() {
        let result: Result<LoadResult, PromptLibraryError>
        do {
            let text = try String(contentsOf: Paths.configFile, encoding: .utf8)
            result = .success(try PromptLibraryParser.parse(text))
        } catch let error as PromptLibraryError {
            result = .failure(error)
        } catch {
            result = .failure(.unreadable(error.localizedDescription))
        }
        state.apply(result)

        if let summary = state.errorSummary {
            Log.error("配置加载失败，沿用上次结果：\(summary)")
        } else {
            Log.info("配置已加载：\(state.library.prompts.count) 条，警告 \(state.warnings.count) 条")
            state.warnings.forEach { Log.info("配置警告：\($0.message)") }
        }

        registerHotkeysIfChanged()
        panel.update(prompts: state.library.prompts)
        updateStatusIcon()
    }

    /// 把设置窗口或菜单的修改写回 prompts.yaml（spec 9.5）。成功返回 nil，失败返回给用户看的错误信息。
    @discardableResult
    private func saveLibrary(from base: PromptLibrary, to target: PromptLibrary) -> String? {
        // 配置文件是符号链接时写入链接指向的真实文件，不破坏链接
        let url = Paths.configFile.resolvingSymlinksInPath()
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let updated: String
            do {
                updated = try ConfigWriter.update(text, from: base, to: target)
            } catch let error as PromptLibraryError {
                return "配置文件当前有错误，请先修复后再保存：\(error)"
            }
            if updated != text {
                try text.write(to: url.appendingPathExtension("bak"), atomically: true, encoding: .utf8)
                try updated.write(to: url, atomically: true, encoding: .utf8)
                Log.info("已写入配置：默认服务 \(target.settings.llm.provider)，服务 \(target.settings.providers.count) 个，提示词 \(target.prompts.count) 条")
            }
        } catch let error as SettingsWriterError {
            Log.error("写入配置被拒绝：\(error.message)")
            return error.message
        } catch {
            Log.error("写入配置失败：\(error)")
            return "写入失败：\(error)"
        }
        for name in Set(base.settings.providers.keys).subtracting(target.settings.providers.keys).sorted() {
            KeychainStore.deleteAPIKey(provider: name)
            Log.info("服务 \(name) 已删除，同时清除其 API Key")
        }
        reload()
        return nil
    }

    /// 面板内新增提示词（spec 8.1）：追加一条 snippet 后走 saveLibrary 写回，热加载后列表自动刷新。
    /// 成功返回 nil，失败返回给表单显示的错误信息。
    private func addPromptFromPanel(title: String, keywords: [String], content: String) -> String? {
        modifyLibraryFromPanel { current in
            var target = current
            let id = Prompt.uniqueID(title: title, existing: Set(current.prompts.map(\.id)))
            target.prompts.append(Prompt(id: id, title: title, keywords: keywords, content: content))
            Log.info("面板新增提示词：\(id)")
            return .success(target)
        }
    }

    /// 编辑条目（spec 8.1）：只改 title/keywords/content，id 与其余字段不动，改名不影响使用统计。
    /// 磁盘上该条与表单打开时不一致（外部修改过）则拒绝，避免静默覆盖。
    private func updatePromptFromPanel(original: Prompt, title: String, keywords: [String], content: String) -> String? {
        modifyLibraryFromPanel { current in
            guard let index = current.prompts.firstIndex(where: { $0.id == original.id }) else {
                return .failure("该条目已被外部删除，请取消后重试")
            }
            let onDisk = current.prompts[index]
            guard onDisk.title == original.title, onDisk.keywords == original.keywords,
                  onDisk.content == original.content else {
                return .failure("该条目在编辑期间被外部修改，请取消后重新打开编辑")
            }
            var target = current
            target.prompts[index].title = title
            target.prompts[index].keywords = keywords
            target.prompts[index].content = content
            return .success(target)
        }
    }

    /// 删除条目（spec 8.1）：界面上已二次确认，写盘前备份 .bak。
    private func deletePromptFromPanel(id: String) -> String? {
        modifyLibraryFromPanel { current in
            guard current.prompts.contains(where: { $0.id == id }) else {
                return .failure("该条目已被外部删除")
            }
            var target = current
            target.prompts.removeAll { $0.id == id }
            Log.info("面板删除提示词：\(id)")
            return .success(target)
        }
    }

    private enum PanelChange {
        case success(PromptLibrary)
        case failure(String)
    }

    /// 面板表单写盘的公共路径：以磁盘当前解析结果为 base（避免热加载窗口期内存态落后于磁盘被误判冲突），
    /// 修改后交给 saveLibrary 写回（备份、保注释、reload）。
    private func modifyLibraryFromPanel(_ change: (PromptLibrary) -> PanelChange) -> String? {
        let current: PromptLibrary
        do {
            let text = try String(contentsOf: Paths.configFile.resolvingSymlinksInPath(), encoding: .utf8)
            current = try PromptLibraryParser.parse(text).library
        } catch {
            return "配置文件当前有错误，请先修复后再保存：\(error)"
        }
        switch change(current) {
        case .failure(let message): return message
        case .success(let target): return saveLibrary(from: current, to: target)
        }
    }

    /// 表单内「生成关键词」（spec 8.1）：内容文本发给默认模型提炼，风格对齐示例配置（中文短词 + 英文缩写混排）。
    private func generateKeywords(content: String, completion: @escaping ([String]) -> Void) {
        let settings = state.library.settings
        let instruction = """
            从下面的提示词内容中提炼 3-5 个用于搜索的关键词。要求：
            - 每个词 1-5 个字符，中文短词为主，有通用英文缩写就加英文（如 审查 review、性能 perf、周报 weekly）
            - 覆盖核心动作与对象，不重复
            - 只输出关键词本身，用空格分隔；不要编号、不要解释、不要任何标点

            提示词内容：
            \(content)
            """
        Task {
            var words: [String] = []
            do {
                let target = try LLMTargetResolver.resolve(
                    prompt: Prompt(id: "_kw", title: "_kw", content: content), settings: settings)
                let rendered = RenderedAction(system: "", userMessage: instruction, output: .show)
                let request = try LLMRequestBuilder.build(
                    rendered, target: target,
                    apiKey: KeychainStore.readAPIKey(provider: target.provider.name),
                    defaultEffort: settings.llm.effort)
                var text = ""
                let stream = LLMClient.stream(request, protocol: target.provider.protocolType) {
                    LLMClient.sessionConfiguration(proxy: settings.network.proxy)
                }
                for try await event in stream {
                    if case .text(let chunk) = event { text += chunk }
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                words = trimmed
                    .split(whereSeparator: { ",，、;；\n\r\t ".contains($0) })
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "。.#*-")) }
                    .filter { (1...12).contains($0.count) }
                words = Array(words.prefix(6))
                Log.info("关键词已生成：\(words.count) 个")
            } catch {
                Log.error("关键词生成失败：\(error.localizedDescription)")
            }
            completion(words)
        }
    }

    /// 🔊 朗读时的音标查询（spec 9.4）：短英文文本发给默认模型要美式 IPA + 简要中文释义，
    /// 返回经 SpeechPhonetics.normalize 清洗，无效或失败一律回调 nil（不打扰朗读）。
    private func lookupPhonetic(_ text: String, completion: @escaping (PhoneticInfo?) -> Void) {
        guard SpeechPhonetics.shouldLookup(text) else {
            completion(nil)
            return
        }
        let settings = state.library.settings
        let instruction = """
            给出下面英文单词或短语的：1）美式音标；2）简要中文意思（不超过 12 个字）。
            格式：只输出一行，先是 / 包住的音标，空一格接中文意思。缩写词按字母读音标，中文意思给全称。
            示例：GPU → /ˌdʒiː piː ˈjuː/ 图形处理器
            不要编号、不要解释、不要其他任何文字。

            文本：
            \(text)
            """
        Task {
            var info: PhoneticInfo?
            do {
                let target = try LLMTargetResolver.resolve(
                    prompt: Prompt(id: "_ipa", title: "_ipa", content: text), settings: settings)
                let rendered = RenderedAction(system: "", userMessage: instruction, output: .show)
                let request = try LLMRequestBuilder.build(
                    rendered, target: target,
                    apiKey: KeychainStore.readAPIKey(provider: target.provider.name),
                    defaultEffort: settings.llm.effort)
                var output = ""
                let stream = LLMClient.stream(request, protocol: target.provider.protocolType) {
                    LLMClient.sessionConfiguration(proxy: settings.network.proxy)
                }
                for try await event in stream {
                    if case .text(let chunk) = event { output += chunk }
                }
                info = SpeechPhonetics.normalize(output)
                Log.info("音标查询完成：\(info == nil ? "无有效结果" : "已获取")")
            } catch {
                Log.error("音标查询失败：\(error.localizedDescription)")
            }
            completion(info)
        }
    }

    /// ⭐ 收藏到词汇表（spec 9.4、9.8）：先用默认模型把解释提炼成精简要点（失败回退原文解释），
    /// 再写入 VocabularyLocator 解析出的目录，按 settings.vocabulary.split 拆分文件、文件内同标题去重。
    /// 全流程异步，结果经 completion 回报。
    private func favoriteToVault(
        source: String, explanation: String, phonetic: PhoneticInfo?,
        completion: @escaping (FavoriteResult) -> Void
    ) {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExplanation = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, !trimmedExplanation.isEmpty else {
            completion(.failed("原文或解释为空：等生成完成再收藏"))
            return
        }
        let settings = state.library.settings
        let split = settings.vocabulary.split
        let dir = VocabularyLocator.directory(for: settings.vocabulary)
        let title = VocabularyNotebook.title(for: trimmedSource)
        Task { @MainActor in
            // 提炼：解释压缩成「首行核心释义 + 1-4 条要点」；模型不可用则回退原文解释，收藏不中断
            var summary: String?
            do {
                let instruction = """
                    把下面的「原文」和「解释」提炼成一张精简词汇卡。要求：
                    - 第一行：一句话核心释义，不超过 25 个字，不要重复原词本身
                    - 然后 1-4 个要点，每条一行（以「- 」开头），保留最值得记的信息：常见用法、辨析、易混点
                    - 中文为主，保留必要的英文术语；不要标题、不要编号、不要客套话，直接输出内容

                    原文：
                    \(trimmedSource)

                    解释：
                    \(trimmedExplanation)
                    """
                let target = try LLMTargetResolver.resolve(
                    prompt: Prompt(id: "_fav", title: "_fav", content: trimmedSource), settings: settings)
                let rendered = RenderedAction(system: "", userMessage: instruction, output: .show)
                let request = try LLMRequestBuilder.build(
                    rendered, target: target,
                    apiKey: KeychainStore.readAPIKey(provider: target.provider.name),
                    defaultEffort: settings.llm.effort)
                var text = ""
                let stream = LLMClient.stream(request, protocol: target.provider.protocolType) {
                    LLMClient.sessionConfiguration(proxy: settings.network.proxy)
                }
                for try await event in stream {
                    if case .text(let chunk) = event { text += chunk }
                }
                summary = Self.condenseSummary(text)
            } catch {
                Log.error("收藏提炼失败（回退原文解释）：\(error.localizedDescription)")
            }
            do {
                let now = Date()   // 文件名与当天节用同一时刻，跨零点不错位
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let fileName = VocabularyNotebook.fileName(for: now, split: split)
                let file = dir.appendingPathComponent(fileName)
                let existing = try? String(contentsOf: file, encoding: .utf8)
                let content = existing ?? VocabularyNotebook.template(for: now, split: split)
                let entry = VocabularyNotebook.entry(
                    title: title, phonetic: phonetic,
                    summary: summary ?? trimmedExplanation)
                guard let updated = VocabularyNotebook.insert(
                    entry: entry, title: title, into: content, date: now, split: split) else {
                    Log.info("词汇表 \(fileName) 已有同标题词条（\(title.count) 字），跳过重复收藏")   // 标题取自选区，日志不记原文
                    completion(.failed("\(fileName) 里已有「\(title)」，未重复收藏"))
                    return
                }
                try updated.write(to: file, atomically: true, encoding: .utf8)
                let shown = VocabularyLocator.display(file)
                Log.info("已收藏到 \(shown)" + (summary == nil ? "（未提炼）" : ""))
                completion(.saved("已收藏到 \(shown)"))
            } catch {
                Log.error("收藏失败：\(error.localizedDescription)")
                completion(.failed("收藏失败：\(error.localizedDescription)"))
            }
        }
    }

    /// 提炼文本清洗：去空白、去掉模型可能带上的 Markdown 标题行、限制行数（防跑飞）。
    private static func condenseSummary(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                return !line.hasPrefix("#")    // 标题行剔除
            }
        guard !lines.isEmpty else { return nil }
        return Array(lines.prefix(8)).joined(separator: "\n")
    }

    private func setHotkeysPaused(_ paused: Bool) {
        guard paused != hotkeysPaused else { return }
        hotkeysPaused = paused
        if paused {
            hotkeys.unregister(id: Self.promptPanelHotkeyID)
            hotkeys.unregister(id: Self.actionPanelHotkeyID)
            registeredHotkeys = [:]
            Log.info("录制快捷键，全局快捷键已暂停")
        } else {
            registerHotkeysIfChanged()
        }
    }

    private func registerHotkeysIfChanged() {
        guard !hotkeysPaused else { return }
        let config = state.library.settings.hotkeys
        let entries: [(UInt32, String, () -> Void)] = [
            (Self.promptPanelHotkeyID, config.promptPanel, { [weak self] in self?.togglePanel() }),
            (Self.actionPanelHotkeyID, config.actionPanel, { [weak self] in self?.toggleActionPanel() }),
        ]
        for (id, text, action) in entries where registeredHotkeys[id] != text {
            do {
                let spec = try HotkeySpec.parse(text)
                hotkeyErrors[id] = hotkeys.register(id: id, spec: spec, action: action)
            } catch {
                hotkeys.unregister(id: id)
                hotkeyErrors[id] = "快捷键「\(text)」无效：\(error)"
            }
            registeredHotkeys[id] = text
            if let message = hotkeyErrors[id] { Log.error(message) } else { Log.info("已注册快捷键 \(text)") }
        }
    }

    private func openUsageStore() {
        do {
            let store = try UsageStore(path: Paths.usageDatabase.path)
            let removed = try store.purgeExpired()
            if removed > 0 { Log.info("清理过期使用记录 \(removed) 条") }
            usage = store
        } catch {
            Log.error("打开使用统计失败，排序将不考虑使用频率：\(error)")
        }
    }

    // MARK: - 面板

    private func togglePanel() {
        panel.isVisible ? panel.hide() : showPanel()
    }

    private func currentFrecency() -> [String: Double] {
        let now = Date()
        let since = now.addingTimeInterval(-Double(UsageStore.defaultRetentionDays) * 86_400)
        let events = (try? usage?.events(since: since)) ?? []
        return Frecency.scores(events: events, now: now)
    }

    private func showPanel() {
        var notices: [String] = []
        if state.error != nil { notices.append("配置文件有错误，当前使用上次加载成功的版本（详见菜单栏）") }
        if !PasteService.isTrusted { notices.append("未授予辅助功能权限：回车只会复制到剪贴板") }

        panel.show(mode: .prompts, prompts: state.library.prompts, frecency: currentFrecency(),
                   notice: notices.isEmpty ? nil : notices.joined(separator: "\n"))
    }

    private func toggleActionPanel() {
        if panel.isVisible { panel.hide(); return }
        Task { await showActionPanel() }
    }

    /// 先读取选区（此时焦点仍在原应用），再显示动作面板。
    private func showActionPanel() async {
        actionTarget = lastExternalApp
        var notices: [String] = []
        var selection = ""

        if PasteService.isTrusted {
            if let result = await SelectionService.read() {
                selection = result.text
                Log.info("读取选区：\(result.text.count) 字，来源 \(result.source.rawValue)，应用 \(actionTarget?.bundleIdentifier ?? "-")")
            } else {
                // 读不到选区直接进输入回退模式（placeholder 已说明用法），不再提示「去选中文字」
                Log.info("未读取到选区（输入回退模式），应用 \(actionTarget?.bundleIdentifier ?? "-")")
            }
        } else {
            notices.append("需要辅助功能权限才能读取选中文字（菜单栏 → 辅助功能权限）")
        }
        let settings = state.library.settings
        if let provider = settings.providers[settings.llm.provider],
           provider.protocolType == .anthropic, !KeychainStore.hasAPIKey(provider: provider.name) {
            notices.append("默认服务「\(provider.name)」未设置 API Key：菜单栏 → API Key")
        }
        if state.error != nil { notices.append("配置文件有错误，当前使用上次加载成功的版本") }

        panel.show(mode: .actions(selection: selection), prompts: state.library.prompts,
                   frecency: currentFrecency(), notice: notices.isEmpty ? nil : notices.joined(separator: "\n"),
                   selectionSourceApp: selection.isEmpty ? nil : actionTarget?.localizedName)
    }

    private func handlePanelCommand(_ command: PanelCommand) {
        let model = panel.model
        switch (model.mode, model.phase) {
        case (.prompts, .choosing):
            guard let prompt = model.selected?.prompt else { return }
            panel.hide()
            performSnippet(command, prompt)
        case (.prompts, .running):
            break
        case (.prompts, .failed):
            // ✨ 跑模型失败：↩ 重试（重新读取剪贴板）
            if command == .paste, let prompt = model.activePrompt { runPromptFromPanel(prompt) }
        case (.prompts, .done):
            // ✨ 跑模型完成：↩/⌘↩ 复制结果（show 语义）
            applyActionResult(command)
        case (.actions, .choosing):
            guard let prompt = model.selected?.prompt else { return }
            runAction(prompt)
        case (.actions, .running):
            break
        case (.actions, .failed):
            if command == .paste, let prompt = model.activePrompt { runAction(prompt) }
        case (.actions, .done):
            applyActionResult(command)
        }
    }

    private func performSnippet(_ command: PanelCommand, _ prompt: Prompt) {
        let rendered = SnippetTemplate.render(prompt.content)
        if command == .paste && PasteService.isTrusted {
            PasteService.paste(rendered.text, into: lastExternalApp, settings: state.library.settings.paste,
                               cursor: rendered.cursor)
            record(prompt, .paste)
        } else {
            PasteService.copy(rendered.text)
            Log.info("copy：\(prompt.id)")
            record(prompt, .copy)
        }
    }

    private func runAction(_ prompt: Prompt) {
        runAction(prompt, selection: panel.model.selectionText, panelRun: false)
    }

    /// ✨ 面板内直接跑模型（spec 8.1）：输入为剪贴板文本，结果只显示（show），↩ 复制。
    private func runPromptFromPanel(_ prompt: Prompt) {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            panel.model.notice = "剪贴板没有文本：先复制要处理的内容（⌘C），再点 ✨"
            return
        }
        runAction(prompt, selection: text, panelRun: true)
    }

    private func runAction(_ prompt: Prompt, selection: String, panelRun: Bool) {
        let model = panel.model
        guard !selection.isEmpty else {
            model.notice = "没有可处理的内容：选中文字后再按快捷键，或在上方输入内容"
            return
        }

        let settings = state.library.settings
        let rendered = panelRun
            ? PromptRenderer.renderSnippetRun(prompt, input: selection)
            : PromptRenderer.render(prompt, selection: selection)
        let target: LLMTarget
        let request: URLRequest
        do {
            target = try LLMTargetResolver.resolve(prompt: prompt, settings: settings)
            request = try LLMRequestBuilder.build(
                rendered, target: target,
                apiKey: KeychainStore.readAPIKey(provider: target.provider.name),
                defaultEffort: settings.llm.effort)
        } catch {
            // 请求发出前就失败（缺 Key、服务未定义）：切到结果区显示，避免只有一行小字像「没反应」
            let label = prompt.provider ?? settings.llm.provider
            if panelRun {
                model.beginPromptRun(prompt, input: selection, targetLabel: label)
            } else {
                model.beginAction(prompt, input: selection, output: rendered.output, targetLabel: label)
            }
            model.phase = .failed(error.localizedDescription
                + "\n\n可以在菜单栏 → API Key 中设置，或修改 prompts.yaml 中的 settings.llm.provider。")
            Log.error("动作未执行 \(prompt.id)：\(error.localizedDescription)")
            return
        }

        cancelAction()
        model.notice = nil
        let targetLabel = "\(target.provider.name) · \(target.model)"
        if panelRun {
            model.beginPromptRun(prompt, input: selection, targetLabel: targetLabel)
            // 剪贴板预览（spec 8.1）：✨ 是盲发，执行时在提示条亮出剪贴板前 40 字供核对，
            // 复制失败/残留旧内容一眼可辨；notice 保持到返回列表，结果阶段随时可回看当时发的是什么
            let head = selection.prefix(40).replacingOccurrences(of: "\n", with: " ⏎ ")
            model.notice = "剪贴板 \(selection.count) 字：\(head)\(selection.count > 40 ? "…" : "")"
        } else {
            model.beginAction(prompt, input: selection, output: rendered.output, targetLabel: targetLabel)
        }
        record(prompt, .action)

        let started = Date()
        Log.info("执行动作 \(prompt.id)：服务 \(target.provider.name)（\(target.provider.protocolType.rawValue)），模型 \(target.model)，输入 \(selection.count) 字\(panelRun ? "（剪贴板）" : "")")

        let proxy = settings.network.proxy
        let proto = target.provider.protocolType
        actionTask = Task { [weak self] in
            var stopReason: String?
            var firstTokenAt: Date?
            do {
                let stream = LLMClient.stream(request, protocol: proto) { LLMClient.sessionConfiguration(proxy: proxy) }
                for try await event in stream {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .text(let text):
                        if firstTokenAt == nil { firstTokenAt = Date() }
                        self.panel.model.output += text
                    case .thinking:
                        if !self.panel.model.isThinking { self.panel.model.isThinking = true }
                    case .stop(let reason):
                        stopReason = reason
                    case .error(let type, let message):
                        throw LLMError("模型返回错误：\(message.isEmpty ? type : message)")
                    }
                }
                guard let self, !Task.isCancelled else { return }
                let elapsed = Date().timeIntervalSince(started)
                let ttft = firstTokenAt.map { String(format: "%.1fs", $0.timeIntervalSince(started)) } ?? "-"
                Log.info("动作完成 \(prompt.id)：stop_reason \(stopReason ?? "-")，首字 \(ttft)，总耗时 \(String(format: "%.1fs", elapsed))，输出 \(self.panel.model.output.count) 字")

                if stopReason == "refusal" {
                    self.panel.model.phase = .failed("模型拒绝处理该内容（refusal），结果不可用")
                } else if self.panel.model.output.isEmpty {
                    self.panel.model.phase = .failed("模型没有返回内容（stop_reason: \(stopReason ?? "-")）")
                } else {
                    if stopReason == "max_tokens" { self.panel.model.notice = "输出达到长度上限，结果可能不完整" }
                    self.panel.model.phase = .done
                    if rendered.output == .copy { PasteService.copy(self.cleanedOutput()) }
                    self.recordHistory(title: prompt.title, target: targetLabel, input: selection,
                                       output: self.panel.model.output)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                Log.error("动作失败 \(prompt.id)：\(error.localizedDescription)")
                self.panel.model.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func applyActionResult(_ command: PanelCommand) {
        let text = cleanedOutput()
        guard !text.isEmpty else { return }
        let mode = panel.model.activeOutputMode
        if command == .paste && mode == .replace && PasteService.isTrusted {
            panel.hide()
            PasteService.paste(text, into: actionTarget, settings: state.library.settings.paste)
            Log.info("已替换原文：\(text.count) 字")
        } else {
            PasteService.copy(text)
            panel.hide()
            Log.info("已复制结果：\(text.count) 字")
        }
    }

    /// 去掉模型输出首尾的空白与换行。
    private func cleanedOutput() -> String {
        panel.model.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cancelAction() {
        actionTask?.cancel()
        actionTask = nil
    }

    private func record(_ prompt: Prompt, _ kind: UsageKind) {
        do { try usage?.record(promptID: prompt.id, kind: kind) }
        catch { Log.error("记录使用失败：\(error)") }
    }

    private func trackFrontmostApp() {
        let ownID = Bundle.main.bundleIdentifier
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != ownID {
            lastExternalApp = app
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.bundleIdentifier != ownID { self?.lastExternalApp = app }
            }
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let symbol = state.error == nil && hotkeyErrors.isEmpty ? "text.quote" : "exclamationmark.triangle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "PromptDock")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    /// 每次打开菜单时重建，保证权限、开机自启等状态是最新的。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hotkeys = state.library.settings.hotkeys
        let promptKey = (try? HotkeySpec.parse(hotkeys.promptPanel))?.displayString ?? ""
        let actionKey = (try? HotkeySpec.parse(hotkeys.actionPanel))?.displayString ?? ""
        menu.addItem(item("打开 Prompt 面板    \(promptKey)", #selector(menuShowPanel)))
        menu.addItem(disabled("选中文字动作    \(actionKey)"))
        menu.addItem(.separator())

        if let summary = state.errorSummary {
            menu.addItem(disabled("⚠️ 配置错误：\(summary)"))
        }
        for message in hotkeyErrors.values.sorted() {
            menu.addItem(disabled("⚠️ \(message)"))
        }
        if !state.warnings.isEmpty {
            let warningsItem = NSMenuItem(title: "配置警告 \(state.warnings.count) 条", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            state.warnings.forEach { sub.addItem(disabled($0.message)) }
            warningsItem.submenu = sub
            menu.addItem(warningsItem)
        }
        menu.addItem(disabled("已加载 \(state.library.prompts.count) 条提示词"))
        menu.addItem(.separator())

        menu.addItem(item("设置…", #selector(menuSettings)))
        menu.addItem(item("调用历史…", #selector(menuHistory)))
        menu.addItem(item("编辑提示词…", #selector(menuEdit)))
        menu.addItem(item("重新加载", #selector(menuReload)))
        menu.addItem(item("打开数据目录", #selector(menuReveal)))
        menu.addItem(.separator())

        menu.addItem(item(
            PasteService.isTrusted ? "辅助功能权限：已授权" : "辅助功能权限：未授权（点击设置）",
            #selector(menuAccessibility)
        ))
        let settings = state.library.settings
        let defaultItem = NSMenuItem(title: "默认服务：\(settings.llm.provider)", action: nil, keyEquivalent: "")
        let defaultMenu = NSMenu()
        for name in settings.providers.keys.sorted() {
            guard let provider = settings.providers[name] else { continue }
            let entry = item("\(name)（\(provider.model)）", #selector(menuSetDefaultProvider(_:)))
            entry.representedObject = name
            entry.state = name == settings.llm.provider ? .on : .off
            defaultMenu.addItem(entry)
        }
        defaultItem.submenu = defaultMenu
        menu.addItem(defaultItem)
        let keysItem = NSMenuItem(title: "API Key", action: nil, keyEquivalent: "")
        let keysMenu = NSMenu()
        for name in settings.providers.keys.sorted() {
            guard let provider = settings.providers[name] else { continue }
            let hasKey = KeychainStore.hasAPIKey(provider: name)
            let status = hasKey ? "已设置" : (provider.protocolType == .openai ? "未设置（本地服务可不填）" : "未设置")
            let isDefault = name == settings.llm.provider ? " · 默认" : ""
            let entry = item("\(name)（\(provider.protocolType.rawValue) · \(provider.model)\(isDefault)）：\(status)", #selector(menuAPIKey(_:)))
            entry.representedObject = name
            keysMenu.addItem(entry)
        }
        keysItem.submenu = keysMenu
        menu.addItem(keysItem)
        let login = item("开机自启", #selector(menuToggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(disabled("PromptDock \(Self.appVersion)"))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func menuShowPanel() { showPanel() }

    @objc private func menuSettings() { settingsWindow.show(library: state.library) }

    @objc private func menuHistory() {
        historyWindow.show(
            entries: historyStoreIfEnabled()?.recent() ?? [],
            onCopy: { PasteService.copy($0) },
            onClear: { [weak self] in
                self?.historyStoreIfEnabled()?.clear()
                self?.historyWindow.host.rootView = HistoryView(entries: [], onCopy: { _ in }, onClear: {})
            })
    }

    /// 调用历史：settings.keep_history 开启时才有存储；首次调用时打开数据库。
    private func historyStoreIfEnabled() -> HistoryStore? {
        guard state.library.settings.keepHistory else { return nil }
        if let historyStore { return historyStore }
        do {
            historyStore = try HistoryStore(path: Paths.historyDatabase.path)
            Log.info("调用历史已开启：\(Paths.historyDatabase.path)")
            return historyStore
        } catch {
            Log.error("调用历史数据库打开失败：\(error.localizedDescription)")
            return nil   // 失败只影响历史，不影响主流程
        }
    }

    private func recordHistory(title: String, target: String, input: String, output: String) {
        historyStoreIfEnabled()?.add(title: title, target: target, input: input, output: output)
    }

    @objc private func menuSetDefaultProvider(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, name != state.library.settings.llm.provider else { return }
        var target = state.library
        target.settings.llm.provider = name
        if let failure = saveLibrary(from: state.library, to: target) {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "切换默认服务失败"
            alert.informativeText = failure
            alert.runModal()
        }
    }

    @objc private func menuEdit() { NSWorkspace.shared.open(Paths.configFile) }

    @objc private func menuReload() { reload() }

    @objc private func menuReveal() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.configFile])
    }

    @objc private func menuAccessibility() {
        PasteService.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func menuAPIKey(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? String else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "设置「\(provider)」的 API Key"
        alert.informativeText = "Key 保存在系统钥匙串中，不会写入配置文件或日志。留空并保存表示清除。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "粘贴 API Key"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            KeychainStore.deleteAPIKey(provider: provider)
            Log.info("已清除 \(provider) 的 API Key")
        } else {
            let status = KeychainStore.saveAPIKey(key, provider: provider)
            if status == errSecSuccess { Log.info("已保存 \(provider) 的 API Key") }
            else { Log.error("保存 \(provider) 的 API Key 失败：OSStatus \(status)") }
        }
    }

    @objc private func menuToggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                Log.info("已关闭开机自启")
            } else {
                try service.register()
                Log.info("已开启开机自启")
            }
        } catch {
            Log.error("切换开机自启失败：\(error)")
        }
    }
}
