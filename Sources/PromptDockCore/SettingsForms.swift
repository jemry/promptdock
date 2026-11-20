import Foundation

/// 设置窗口「模型服务」页的可编辑表单。所有字段都是文本，保存时统一校验。
public struct ProviderForm: Sendable, Equatable {
    public var name: String
    public var protocolType: LLMProtocol
    public var baseURL: String
    public var model: String
    /// 空串表示不设置。
    public var maxTokens: String
    /// 空串表示不设置。
    public var effort: String
    /// JSON 对象文本；空串表示不设置。
    public var extraBody: String

    public init(name: String = "", protocolType: LLMProtocol = .openai, baseURL: String = "",
                model: String = "", maxTokens: String = "", effort: String = "", extraBody: String = "") {
        self.name = name
        self.protocolType = protocolType
        self.baseURL = baseURL
        self.model = model
        self.maxTokens = maxTokens
        self.effort = effort
        self.extraBody = extraBody
    }

    public init(_ p: ProviderConfig) {
        var body = ""
        if let data = p.extraBody, let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            body = String(decoding: pretty, as: UTF8.self)
        }
        self.init(name: p.name, protocolType: p.protocolType, baseURL: p.baseURL.absoluteString, model: p.model,
                  maxTokens: p.maxTokens.map(String.init) ?? "", effort: p.effort ?? "", extraBody: body)
    }

    /// 服务名同时用作 YAML 键和钥匙串账户名，只允许字母、数字、- 和 _。
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public func validated() throws -> ProviderConfig {
        let name = self.name.trimmingCharacters(in: .whitespaces)
        guard Self.isValidName(name) else {
            throw SettingsWriterError("服务名只能包含字母、数字、- 和 _")
        }
        let rawURL = baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            throw SettingsWriterError("「\(name)」的地址需以 http:// 或 https:// 开头")
        }
        let model = self.model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw SettingsWriterError("「\(name)」缺少模型名") }

        var config = ProviderConfig(name: name, protocolType: protocolType, baseURL: url, model: model)
        let tokens = maxTokens.trimmingCharacters(in: .whitespaces)
        if !tokens.isEmpty {
            guard let n = Int(tokens), n > 0 else { throw SettingsWriterError("「\(name)」的 max_tokens 必须是正整数") }
            config.maxTokens = n
        }
        if !effort.isEmpty {
            guard LLMSettings.allowedEfforts.contains(effort) else { throw SettingsWriterError("「\(name)」的 effort 无效") }
            config.effort = effort
        }
        let body = extraBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)), object is [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                throw SettingsWriterError("「\(name)」的附加参数必须是 JSON 对象，例如 {\"thinking\": {\"type\": \"disabled\"}}")
            }
            config.extraBody = data
        }
        return config
    }
}

/// 设置窗口「通用」页的可编辑表单。
public struct GeneralForm: Sendable, Equatable {
    public var promptPanel: String
    public var actionPanel: String
    public var restoreClipboard: Bool
    public var restoreDelayMs: Int
    public var effort: String
    /// 空串表示跟随系统代理。
    public var proxy: String
    /// 词汇表目录（spec 9.8）：空串表示自动。
    public var vocabularyDir: String
    public var vocabularySplit: VocabularySplit

    public init(_ s: Settings) {
        promptPanel = s.hotkeys.promptPanel
        actionPanel = s.hotkeys.actionPanel
        restoreClipboard = s.paste.restoreClipboard
        restoreDelayMs = s.paste.restoreDelayMs
        effort = s.llm.effort
        proxy = s.network.proxy.map { "http://\($0.host):\($0.port)" } ?? ""
        vocabularyDir = s.vocabulary.dir ?? ""
        vocabularySplit = s.vocabulary.split
    }

    public func apply(to s: inout Settings) throws {
        let prompt = promptPanel.trimmingCharacters(in: .whitespaces)
        let action = actionPanel.trimmingCharacters(in: .whitespaces)
        let promptSpec: HotkeySpec
        let actionSpec: HotkeySpec
        do { promptSpec = try HotkeySpec.parse(prompt) } catch {
            throw SettingsWriterError("提示词面板快捷键「\(prompt)」无效：\(error)")
        }
        do { actionSpec = try HotkeySpec.parse(action) } catch {
            throw SettingsWriterError("动作面板快捷键「\(action)」无效：\(error)")
        }
        guard promptSpec != actionSpec else { throw SettingsWriterError("两个快捷键不能相同") }
        guard restoreDelayMs >= 0 else { throw SettingsWriterError("恢复剪贴板延迟不能为负数") }
        guard LLMSettings.allowedEfforts.contains(effort) else { throw SettingsWriterError("effort 无效") }

        var proxySetting: ProxySetting?
        let rawProxy = proxy.trimmingCharacters(in: .whitespaces)
        if !rawProxy.isEmpty {
            guard let p = ProxySetting.parse(rawProxy) else {
                throw SettingsWriterError("代理格式应为 http://127.0.0.1:7890，留空表示跟随系统代理")
            }
            proxySetting = p
        }

        s.hotkeys.promptPanel = prompt
        s.hotkeys.actionPanel = action
        s.paste.restoreClipboard = restoreClipboard
        s.paste.restoreDelayMs = restoreDelayMs
        s.llm.effort = effort
        s.network.proxy = proxySetting
        let dir = vocabularyDir.trimmingCharacters(in: .whitespaces)
        s.vocabulary.dir = dir.isEmpty ? nil : dir
        s.vocabulary.split = vocabularySplit
    }
}

/// 把服务表单列表合并进设置。
public enum ProviderListValidator {
    public static func apply(_ forms: [ProviderForm], defaultProvider: String, to s: inout Settings) throws {
        var result: [String: ProviderConfig] = [:]
        for form in forms {
            let config = try form.validated()
            guard result[config.name] == nil else { throw SettingsWriterError("服务名「\(config.name)」重复") }
            result[config.name] = config
        }
        guard result[defaultProvider] != nil else {
            throw SettingsWriterError("请选择一个默认服务")
        }
        s.providers = result
        s.llm.provider = defaultProvider
    }
}

/// 设置窗口「提示词」页的可编辑表单。未改动的条目转回 Prompt 必须与原值完全相同，避免无谓重写。
public struct PromptForm: Sendable, Equatable {
    public var id: String
    public var title: String
    public var type: PromptType
    /// 逗号分隔（中英文逗号均可）。
    public var keywords: String
    public var tags: String
    public var content: String
    /// 空串表示使用默认服务。
    public var provider: String
    /// 空串表示使用服务的默认模型。
    public var model: String
    /// nil 表示默认（replace）。
    public var output: OutputMode?
    /// 空串表示不设置。
    public var system: String

    public init(id: String, title: String = "", type: PromptType = .snippet, keywords: String = "", tags: String = "",
                content: String = "", provider: String = "", model: String = "", output: OutputMode? = nil, system: String = "") {
        self.id = id
        self.title = title
        self.type = type
        self.keywords = keywords
        self.tags = tags
        self.content = content
        self.provider = provider
        self.model = model
        self.output = output
        self.system = system
    }

    public init(_ p: Prompt) {
        self.init(id: p.id, title: p.title, type: p.type,
                  keywords: p.keywords.joined(separator: ", "), tags: p.tags.joined(separator: ", "),
                  content: p.content, provider: p.provider ?? "", model: p.model ?? "",
                  output: p.output, system: p.system ?? "")
    }

    public static func splitList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public func validated(providers: Set<String>) throws -> Prompt {
        let id = self.id.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { throw SettingsWriterError("提示词 id 不能为空") }
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SettingsWriterError("提示词「\(id)」缺少标题")
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsWriterError("提示词「\(title)」缺少内容")
        }
        if !provider.isEmpty, !providers.contains(provider) {
            throw SettingsWriterError("提示词「\(title)」使用的服务「\(provider)」不存在，请改选其他服务")
        }
        let model = self.model.trimmingCharacters(in: .whitespaces)
        return Prompt(id: id, title: title, type: type,
                      keywords: Self.splitList(keywords), tags: Self.splitList(tags), content: content,
                      provider: provider.isEmpty ? nil : provider, model: model.isEmpty ? nil : model,
                      system: system.isEmpty ? nil : system, output: output)
    }
}

public enum PromptListValidator {
    public static func validate(_ forms: [PromptForm], providers: Set<String>) throws -> [Prompt] {
        var seen = Set<String>()
        return try forms.map { form in
            let prompt = try form.validated(providers: providers)
            guard seen.insert(prompt.id).inserted else { throw SettingsWriterError("提示词 id「\(prompt.id)」重复") }
            return prompt
        }
    }
}
