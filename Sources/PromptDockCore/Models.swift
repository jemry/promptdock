import Foundation

/// 提示词条目类型。
public enum PromptType: String, Sendable, Equatable, CaseIterable {
    /// 直接粘贴内容。
    case snippet
    /// 与选中文本组合后调用模型（P1）。
    case action
    /// 交给外部脚本处理（P2）。
    case script
}

/// action 类条目的结果处理方式（P1）。
public enum OutputMode: String, Sendable, Equatable {
    case replace, copy, show
}

public struct Prompt: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var type: PromptType
    public var keywords: [String]
    public var tags: [String]
    public var content: String
    public var provider: String?
    public var model: String?
    public var system: String?
    public var output: OutputMode?

    public init(
        id: String, title: String, type: PromptType = .snippet,
        keywords: [String] = [], tags: [String] = [], content: String,
        provider: String? = nil, model: String? = nil, system: String? = nil, output: OutputMode? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.keywords = keywords
        self.tags = tags
        self.content = content
        self.provider = provider
        self.model = model
        self.system = system
        self.output = output
    }

    /// 面板内新增条目时生成稳定 id：取 title 中的英文字母与数字作 kebab-case，
    /// 中文等其余字符作分隔符；没有可用字符时用 "prompt"，与现有 id 冲突时追加 -2、-3 …
    public static func uniqueID(title: String, existing: Set<String>) -> String {
        let allowed = "abcdefghijklmnopqrstuvwxyz0123456789"
        let base = title.lowercased().map { char -> String in allowed.contains(char) ? String(char) : "-" }.joined()
        let slug = base.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        var candidate = slug.isEmpty ? "prompt" : slug
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(slug.isEmpty ? "prompt" : slug)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}

public struct HotkeySettings: Sendable, Equatable {
    public var promptPanel = "option+space"
    public var actionPanel = "option+shift+space"
    public init() {}
}

public struct PasteSettings: Sendable, Equatable {
    public var restoreClipboard = true
    public var restoreDelayMs = 500
    public init() {}
}

public struct LLMSettings: Sendable, Equatable {
    public static let allowedEfforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]
    /// 默认使用的服务（providers 中的名字）。
    public var provider = ProviderConfig.defaultAnthropic.name
    /// Anthropic 官方接口的默认 effort。
    public var effort = "medium"
    public init() {}
}

public enum LLMProtocol: String, Sendable, Equatable {
    case anthropic, openai
}

/// 一个模型服务（spec 9.3）。
public struct ProviderConfig: Sendable, Equatable {
    public var name: String
    public var protocolType: LLMProtocol
    /// anthropic 协议不带 /v1（如 https://api.anthropic.com）；openai 协议按服务商文档（如 https://api.deepseek.com）。
    public var baseURL: URL
    public var model: String
    public var maxTokens: Int?
    public var effort: String?
    /// 合并进请求体的额外字段（JSON 对象），例如 {"thinking": {"type": "disabled"}}。
    public var extraBody: Data?

    public init(name: String, protocolType: LLMProtocol, baseURL: URL, model: String,
                maxTokens: Int? = nil, effort: String? = nil, extraBody: Data? = nil) {
        self.name = name
        self.protocolType = protocolType
        self.baseURL = baseURL
        self.model = model
        self.maxTokens = maxTokens
        self.effort = effort
        self.extraBody = extraBody
    }

    /// 明文 http 且不是本机回环地址：此时不允许发送 API Key。
    public var isInsecureRemote: Bool {
        guard baseURL.scheme?.lowercased() == "http" else { return false }
        let host = (baseURL.host ?? "").lowercased()
        let loopback = host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.")
        return !loopback
    }

    /// Anthropic 官方地址才发送 fallbacks、effort 等专属参数，第三方兼容接口可能不认。
    public var isOfficialAnthropic: Bool {
        protocolType == .anthropic && baseURL.host?.lowercased() == "api.anthropic.com"
    }

    public static let defaultAnthropic = ProviderConfig(
        name: "anthropic", protocolType: .anthropic,
        baseURL: URL(string: "https://api.anthropic.com")!, model: "claude-opus-5-5"
    )
}

/// 显式指定的 HTTP 代理；为 nil 时跟随系统代理。
public struct ProxySetting: Sendable, Equatable {
    public var host: String
    public var port: Int
    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// 解析 "http://127.0.0.1:7890" 形式；只支持 http 代理。
    public static func parse(_ text: String) -> ProxySetting? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "http",
              let host = url.host, !host.isEmpty, let port = url.port else { return nil }
        return ProxySetting(host: host, port: port)
    }
}

public struct NetworkSettings: Sendable, Equatable {
    public var proxy: ProxySetting?
    public init() {}
}

/// 词汇表文件拆分方式（spec 9.8）。
public enum VocabularySplit: String, Sendable, Equatable, CaseIterable {
    case none, month, day
}

/// 词汇表配置（spec 9.8）：dir 为 nil 时按 VocabularyLocation 自动解析。
public struct VocabularySettings: Sendable, Equatable {
    public var dir: String?
    public var split: VocabularySplit = .month
    public init() {}
}

public struct Settings: Sendable, Equatable {
    public var hotkeys = HotkeySettings()
    public var paste = PasteSettings()
    public var llm = LLMSettings()
    /// 未配置 providers 时内置一个 Anthropic 官方服务。
    public var providers: [String: ProviderConfig] = [ProviderConfig.defaultAnthropic.name: .defaultAnthropic]
    public var network = NetworkSettings()
    /// 调用历史（spec 10）：记录成功动作的输入与输出到本地 SQLite。默认关闭（隐私）。
    public var keepHistory = false
    public var vocabulary = VocabularySettings()
    public init() {}
}

public struct PromptLibrary: Sendable, Equatable {
    public static let supportedVersion = 1

    public var version: Int
    public var settings: Settings
    public var prompts: [Prompt]

    public init(version: Int = PromptLibrary.supportedVersion, settings: Settings = Settings(), prompts: [Prompt] = []) {
        self.version = version
        self.settings = settings
        self.prompts = prompts
    }
}
