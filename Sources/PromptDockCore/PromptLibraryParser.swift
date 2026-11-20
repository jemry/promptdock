import Foundation
import Yams

/// 解析过程中的非致命问题：对应条目被跳过或字段被忽略，其余内容照常加载。
public struct LoadWarning: Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// 致命错误：整个文件无法使用，调用方应保留上一次加载成功的数据。
public enum PromptLibraryError: Error, Equatable {
    /// YAML 语法错误；line 从 1 开始，无法定位时为 nil。
    case syntax(line: Int?, message: String)
    case unsupportedVersion(Int)
    /// 结构不符合预期（例如根节点不是映射、prompts 不是列表）。
    case invalidStructure(String)
    /// 文件不存在或无法读取。
    case unreadable(String)
}

public struct LoadResult: Sendable, Equatable {
    public var library: PromptLibrary
    public var warnings: [LoadWarning]
}

/// 解析 prompts.yaml。规则见 docs/spec.md 第 6.2 节。
public enum PromptLibraryParser {

    private static let rootKeys: Set<String> = ["version", "settings", "prompts"]
    private static let promptKeys: Set<String> = [
        "id", "title", "type", "keywords", "tags", "content", "provider", "model", "system", "output",
    ]
    private static let providerKeys: Set<String> = [
        "protocol", "base_url", "model", "max_tokens", "effort", "extra_body",
    ]

    public static func parse(_ yaml: String) throws -> LoadResult {
        let raw: Any?
        do {
            raw = try Yams.load(yaml: yaml)
        } catch let error as YamlError {
            throw syntaxError(from: error)
        } catch {
            throw PromptLibraryError.syntax(line: nil, message: "\(error)")
        }

        var warnings: [LoadWarning] = []

        guard let raw else {
            return LoadResult(library: PromptLibrary(), warnings: [])
        }
        guard let root = raw as? [String: Any] else {
            throw PromptLibraryError.invalidStructure("根节点必须是映射（key: value 形式）")
        }

        for key in root.keys.sorted() where !rootKeys.contains(key) {
            warnings.append(LoadWarning("忽略未知的顶层字段：\(key)"))
        }

        let version = try parseVersion(root["version"])
        let settings = parseSettings(root["settings"], warnings: &warnings)
        let prompts = try parsePrompts(root["prompts"], warnings: &warnings)

        return LoadResult(
            library: PromptLibrary(version: version, settings: settings, prompts: prompts),
            warnings: warnings
        )
    }

    // MARK: - 各部分

    private static func parseVersion(_ value: Any?) throws -> Int {
        guard let value else { return PromptLibrary.supportedVersion }
        guard let version = value as? Int else {
            throw PromptLibraryError.invalidStructure("version 必须是整数")
        }
        guard version == PromptLibrary.supportedVersion else {
            throw PromptLibraryError.unsupportedVersion(version)
        }
        return version
    }

    private static func parseSettings(_ value: Any?, warnings: inout [LoadWarning]) -> Settings {
        var settings = Settings()
        guard let value else { return settings }
        guard let dict = value as? [String: Any] else {
            warnings.append(LoadWarning("settings 必须是映射，已使用默认设置"))
            return settings
        }

        if let hotkeys = dict["hotkeys"] as? [String: Any] {
            if let v = string(hotkeys["prompt_panel"]) { settings.hotkeys.promptPanel = v }
            if let v = string(hotkeys["action_panel"]) { settings.hotkeys.actionPanel = v }
        }
        if let paste = dict["paste"] as? [String: Any] {
            if let v = paste["restore_clipboard"] as? Bool { settings.paste.restoreClipboard = v }
            if let v = paste["restore_delay_ms"] as? Int, v >= 0 { settings.paste.restoreDelayMs = v }
        }
        if let llm = dict["llm"] as? [String: Any] {
            if llm["model"] != nil {
                warnings.append(LoadWarning("settings.llm.model 已废弃并被忽略：请在 settings.providers 中为每个服务配置 model"))
            }
            if let v = string(llm["provider"]), !v.isEmpty { settings.llm.provider = v }
            if let v = string(llm["effort"]) {
                if LLMSettings.allowedEfforts.contains(v) {
                    settings.llm.effort = v
                } else {
                    warnings.append(LoadWarning("settings.llm.effort「\(v)」无效（可选 low/medium/high/xhigh/max），已使用默认值 medium"))
                }
            }
        }
        if let raw = dict["providers"] {
            if let providers = raw as? [String: Any] {
                settings.providers = parseProviders(providers, warnings: &warnings)
            } else {
                warnings.append(LoadWarning("settings.providers 必须是映射（服务名: 配置），已使用内置的 Anthropic 服务"))
            }
        }
        if settings.providers[settings.llm.provider] == nil {
            warnings.append(LoadWarning("默认服务「\(settings.llm.provider)」未在 settings.providers 中定义，未指定 provider 的动作将无法执行"))
        }
        if let network = dict["network"] as? [String: Any], let v = string(network["proxy"]) {
            if let proxy = ProxySetting.parse(v) {
                settings.network.proxy = proxy
            } else {
                warnings.append(LoadWarning("settings.network.proxy「\(v)」无效（格式如 http://127.0.0.1:7890），已改为跟随系统代理"))
            }
        }
        if let v = dict["keep_history"] as? Bool {
            settings.keepHistory = v
        }
        if let vocabulary = dict["vocabulary"] as? [String: Any] {
            if let v = string(vocabulary["dir"]) {
                let trimmed = v.trimmingCharacters(in: .whitespaces)
                settings.vocabulary.dir = trimmed.isEmpty ? nil : trimmed
            }
            if let v = string(vocabulary["split"]) {
                if let split = VocabularySplit(rawValue: v) {
                    settings.vocabulary.split = split
                } else {
                    warnings.append(LoadWarning("settings.vocabulary.split「\(v)」无效（可选 none/month/day），已按 month 处理"))
                }
            }
        }
        return settings
    }

    private static func parseProviders(_ dict: [String: Any], warnings: inout [LoadWarning]) -> [String: ProviderConfig] {
        var result: [String: ProviderConfig] = [:]
        for name in dict.keys.sorted() {
            let label = "服务「\(name)」"
            guard let entry = dict[name] as? [String: Any] else {
                warnings.append(LoadWarning("\(label)不是映射，已跳过"))
                continue
            }
            for key in entry.keys.sorted() where !providerKeys.contains(key) {
                warnings.append(LoadWarning("\(label)忽略未知字段：\(key)"))
            }
            guard let rawProtocol = string(entry["protocol"]), let proto = LLMProtocol(rawValue: rawProtocol) else {
                warnings.append(LoadWarning("\(label)的 protocol 必须是 anthropic 或 openai，已跳过"))
                continue
            }
            guard let rawURL = string(entry["base_url"]), let url = URL(string: rawURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                warnings.append(LoadWarning("\(label)的 base_url 无效（需以 http:// 或 https:// 开头），已跳过"))
                continue
            }
            guard let model = string(entry["model"]), !model.isEmpty else {
                warnings.append(LoadWarning("\(label)缺少 model，已跳过"))
                continue
            }

            var provider = ProviderConfig(name: name, protocolType: proto, baseURL: url, model: model)
            if let v = entry["max_tokens"] {
                if let n = v as? Int, n > 0 { provider.maxTokens = n }
                else { warnings.append(LoadWarning("\(label)的 max_tokens 必须是正整数，已忽略")) }
            }
            if let v = string(entry["effort"]) {
                if LLMSettings.allowedEfforts.contains(v) { provider.effort = v }
                else { warnings.append(LoadWarning("\(label)的 effort「\(v)」无效，已忽略")) }
            }
            if let v = entry["extra_body"] {
                if let body = v as? [String: Any], JSONSerialization.isValidJSONObject(body),
                   let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) {
                    provider.extraBody = data
                } else {
                    warnings.append(LoadWarning("\(label)的 extra_body 必须是映射，已忽略"))
                }
            }
            result[name] = provider
        }
        return result
    }

    private static func parsePrompts(_ value: Any?, warnings: inout [LoadWarning]) throws -> [Prompt] {
        guard let value else { return [] }
        guard let list = value as? [Any] else {
            throw PromptLibraryError.invalidStructure("prompts 必须是列表")
        }

        var result: [Prompt] = []
        var seenIDs = Set<String>()

        for (index, item) in list.enumerated() {
            let position = "第 \(index + 1) 条"
            guard let dict = item as? [String: Any] else {
                warnings.append(LoadWarning("\(position)不是映射，已跳过"))
                continue
            }
            guard let id = string(dict["id"]), !id.isEmpty else {
                warnings.append(LoadWarning("\(position)缺少 id，已跳过"))
                continue
            }
            let label = "\(position)（id: \(id)）"
            guard let title = string(dict["title"]), !title.isEmpty else {
                warnings.append(LoadWarning("\(label)缺少 title，已跳过"))
                continue
            }

            var type = PromptType.snippet
            if let rawType = string(dict["type"]) {
                guard let parsed = PromptType(rawValue: rawType) else {
                    warnings.append(LoadWarning("\(label)的 type「\(rawType)」不受支持，已跳过"))
                    continue
                }
                type = parsed
            }

            guard let content = string(dict["content"]), !content.isEmpty else {
                warnings.append(LoadWarning("\(label)缺少 content，已跳过"))
                continue
            }
            guard !seenIDs.contains(id) else {
                warnings.append(LoadWarning("\(label)的 id 与前面的条目重复：\(id)，已跳过"))
                continue
            }

            for key in dict.keys.sorted() where !promptKeys.contains(key) {
                warnings.append(LoadWarning("\(label)忽略未知字段：\(key)"))
            }

            var output: OutputMode?
            if let rawOutput = string(dict["output"]) {
                output = OutputMode(rawValue: rawOutput)
                if output == nil {
                    warnings.append(LoadWarning("\(label)的 output「\(rawOutput)」无效，已忽略"))
                }
            }

            seenIDs.insert(id)
            result.append(Prompt(
                id: id, title: title, type: type,
                keywords: stringList(dict["keywords"]), tags: stringList(dict["tags"]),
                content: content,
                provider: string(dict["provider"]), model: string(dict["model"]),
                system: string(dict["system"]), output: output
            ))
        }
        return result
    }

    // MARK: - 工具

    /// 把 YAML 标量统一转成字符串（YAML 会把 42、true 解析成数字和布尔值）。
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        default: return nil
        }
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let list = value as? [Any] { return list.compactMap { string($0) } }
        if let single = string(value) { return [single] }
        return []
    }

    private static func syntaxError(from error: YamlError) -> PromptLibraryError {
        switch error {
        case let .scanner(_, problem, mark, _),
             let .parser(_, problem, mark, _),
             let .composer(_, problem, mark, _):
            return .syntax(line: mark.line, message: problem)
        default:
            return .syntax(line: nil, message: "\(error)")
        }
    }
}
