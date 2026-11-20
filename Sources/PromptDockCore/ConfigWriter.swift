import Foundation
import Yams

public struct SettingsWriterError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// 设置窗口与菜单把修改写回 prompts.yaml（spec 9.5）。
///
/// 只重写有变化的顶层段（`settings:` / `prompts:`），其余文本逐字保留；被重写的段内手写注释会丢失。
/// 写入前重新解析新文本，结果与预期不一致就拒绝写入。
public enum ConfigWriter {

    /// - Parameters:
    ///   - base: 编辑开始时的配置（窗口打开时加载的内容）。
    ///   - target: 编辑后的配置。
    /// - Throws: 文件当前有语法错误时抛 PromptLibraryError；冲突或写后自检失败抛 SettingsWriterError。
    public static func update(_ text: String, from base: PromptLibrary, to target: PromptLibrary) throws -> String {
        let current = try PromptLibraryParser.parse(text).library
        let settingsChanged = target.settings != base.settings
        let promptsChanged = target.prompts != base.prompts
        if (settingsChanged && current.settings != base.settings) || (promptsChanged && current.prompts != base.prompts) {
            throw SettingsWriterError("配置文件在编辑期间被外部修改过，为避免覆盖已放弃保存。请关闭窗口后重新打开再改")
        }

        var lines = text.components(separatedBy: "\n")
        if settingsChanged {
            try replaceSection("settings", with: serialize(target.settings), in: &lines, insertAfter: "version")
        }
        if promptsChanged {
            try replaceSection("prompts", with: serialize(target.prompts), in: &lines, insertAfter: nil)
        }
        let updated = lines.joined(separator: "\n")

        let after: PromptLibrary
        do {
            after = try PromptLibraryParser.parse(updated).library
        } catch {
            throw SettingsWriterError("写入后的配置无法解析（\(error)），已放弃写入")
        }
        let expectedSettings = settingsChanged ? target.settings : current.settings
        let expectedPrompts = promptsChanged ? target.prompts : current.prompts
        guard after.settings == expectedSettings, after.prompts == expectedPrompts, after.version == current.version else {
            throw SettingsWriterError("写入后的配置与预期不一致，已放弃写入，请手动编辑")
        }
        return updated
    }

    /// 只改 settings 的便捷方法（菜单切换默认服务）。
    public static func replacingSettings(in text: String, with settings: Settings) throws -> String {
        let current = try PromptLibraryParser.parse(text).library
        var target = current
        target.settings = settings
        return try update(text, from: current, to: target)
    }

    private static func replaceSection(_ key: String, with block: String, in lines: inout [String], insertAfter anchor: String?) throws {
        if let start = lines.firstIndex(where: { isTopLevelKey($0, key) }) {
            var end = start + 1
            while end < lines.count, !isTopLevelLine(lines[end]) { end += 1 }
            // 下一个顶层字段前面的空行和顶格注释归属下一段，保留
            var keep = end
            while keep > start + 1, isBlankOrTopComment(lines[keep - 1]) { keep -= 1 }
            var replacement = blockLines(block, trailingBlank: keep == end && end < lines.count)
            // 改写的段在文件末尾时保留结尾换行，否则末尾的 | 块会丢掉最后一个换行
            if end == lines.count, keep == end { replacement.append("") }
            lines.replaceSubrange(start..<keep, with: replacement)
        } else if let anchor {
            guard let at = lines.firstIndex(where: { isTopLevelKey($0, anchor) }) else {
                throw SettingsWriterError("配置文件中找不到顶格的 \(key): 或 \(anchor): 行，无法自动写入，请手动编辑")
            }
            lines.insert(contentsOf: blockLines(block, trailingBlank: false), at: at + 1)
        } else {
            // 追加到末尾
            while lines.last == "" { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines.append(contentsOf: blockLines(block, trailingBlank: false))
            lines.append("")
        }
    }

    // MARK: - 定位

    private static func isTopLevelLine(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        // 顶格的 "- " 是紧凑写法的列表项，属于上一段
        return first != " " && first != "\t" && first != "#" && first != "-"
    }

    private static func isTopLevelKey(_ line: String, _ key: String) -> Bool {
        line.hasPrefix(key + ":")
    }

    private static func isBlankOrTopComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#")
    }

    private static func blockLines(_ block: String, trailingBlank: Bool) -> [String] {
        var result = block.components(separatedBy: "\n")
        while result.last == "" { result.removeLast() }
        if trailingBlank { result.append("") }
        return result
    }

    // MARK: - 序列化

    static func serialize(_ s: Settings) throws -> String {
        var pairs: [(Node, Node)] = [
            ("hotkeys", map([
                ("prompt_panel", str(s.hotkeys.promptPanel)),
                ("action_panel", str(s.hotkeys.actionPanel)),
            ])),
            ("paste", map([
                ("restore_clipboard", Node(s.paste.restoreClipboard ? "true" : "false")),
                ("restore_delay_ms", Node(String(s.paste.restoreDelayMs))),
            ])),
            ("llm", map([
                ("provider", str(s.llm.provider)),
                ("effort", str(s.llm.effort)),
            ])),
        ]
        var providers: [(Node, Node)] = []
        for name in s.providers.keys.sorted() {
            guard let p = s.providers[name] else { continue }
            var fields: [(Node, Node)] = [
                ("protocol", str(p.protocolType.rawValue)),
                ("base_url", str(p.baseURL.absoluteString)),
                ("model", str(p.model)),
            ]
            if let v = p.maxTokens { fields.append(("max_tokens", Node(String(v)))) }
            if let v = p.effort { fields.append(("effort", str(v))) }
            if let data = p.extraBody {
                let object = try JSONSerialization.jsonObject(with: data)
                fields.append(("extra_body", try node(fromJSON: object)))
            }
            providers.append((str(name), map(fields)))
        }
        pairs.append(("providers", .mapping(Node.Mapping(providers, .implicit, providers.isEmpty ? .flow : .any))))
        if let proxy = s.network.proxy {
            pairs.append(("network", map([("proxy", str("http://\(proxy.host):\(proxy.port)"))])))
        }
        // 默认关闭，只在开启时写出；漏写会让设置窗口/菜单切换服务时把它静默关掉
        if s.keepHistory {
            pairs.append(("keep_history", Node("true")))
        }
        // 词汇表配置同理：只写非默认值
        var vocabulary: [(Node, Node)] = []
        if let dir = s.vocabulary.dir { vocabulary.append(("dir", str(dir))) }
        if s.vocabulary.split != .month { vocabulary.append(("split", str(s.vocabulary.split.rawValue))) }
        if !vocabulary.isEmpty { pairs.append(("vocabulary", map(vocabulary))) }
        return try Yams.serialize(node: map([("settings", map(pairs))]), indent: 2, width: -1, allowUnicode: true)
    }

    static func serialize(_ prompts: [Prompt]) throws -> String {
        let items: [Node] = prompts.map { p in
            var fields: [(Node, Node)] = [("id", str(p.id)), ("title", str(p.title))]
            if p.type != .snippet { fields.append(("type", str(p.type.rawValue))) }
            if !p.keywords.isEmpty { fields.append(("keywords", flowList(p.keywords))) }
            if !p.tags.isEmpty { fields.append(("tags", flowList(p.tags))) }
            if let v = p.provider { fields.append(("provider", str(v))) }
            if let v = p.model { fields.append(("model", str(v))) }
            if let v = p.output { fields.append(("output", str(v.rawValue))) }
            if let v = p.system { fields.append(("system", text(v))) }
            fields.append(("content", text(p.content)))
            return map(fields)
        }
        let list: Node = .sequence(Node.Sequence(items, .implicit, items.isEmpty ? .flow : .any))
        // 条目之间空一行，便于手工阅读
        let raw = try Yams.serialize(node: list, indent: 2, width: -1, allowUnicode: true)
        // libyaml 输出的列表项顶格；整体缩进两格放到 prompts: 下（空行不加空格，不影响块写法）
        var rawLines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        // 去掉 libyaml 可能附加的文档结束标记
        while let last = rawLines.last, last.isEmpty || last == "..." { rawLines.removeLast() }
        let body = rawLines
            .map { $0.isEmpty ? "" : "  " + $0 }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n  - id:", with: "\n\n  - id:")
        return items.isEmpty ? "prompts: []\n" : "prompts:\n" + body + "\n"
    }

    private static func flowList(_ items: [String]) -> Node {
        .sequence(Node.Sequence(items.map(str), .implicit, .flow))
    }

    /// 多行文本用 | 块写法，保持可读；无法用块写法表示时由 Yams 自动退回引号写法。
    private static func text(_ s: String) -> Node {
        // 末尾多个换行要用 |+，会把段与段之间的空行也吞进内容，改用引号写法
        guard s.contains("\n"), !s.hasSuffix("\n\n") else { return str(s) }
        return .scalar(Node.Scalar(s, .implicit, .literal))
    }

    private static func map(_ pairs: [(Node, Node)]) -> Node {
        .mapping(Node.Mapping(pairs))
    }

    /// 字符串标量：会被 YAML 误读成数字/布尔值的自动加引号。
    private static func str(_ s: String) -> Node {
        .scalar(s.represented())
    }

    private static func node(fromJSON value: Any) throws -> Node {
        switch value {
        case let dict as [String: Any]:
            return map(try dict.keys.sorted().map { (str($0), try node(fromJSON: dict[$0]!)) })
        case let list as [Any]:
            return .sequence(Node.Sequence(try list.map { try node(fromJSON: $0) }, .implicit, .flow))
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return Node(n.boolValue ? "true" : "false") }
            return Node(n.stringValue)
        case let s as String:
            return str(s)
        case is NSNull:
            return Node("null")
        default:
            throw SettingsWriterError("extra_body 含有无法写入的值：\(value)")
        }
    }
}
