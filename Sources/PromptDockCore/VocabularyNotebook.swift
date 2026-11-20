import Foundation

/// 收藏到 Obsidian 词汇表（spec 9.4）：每月一个 Markdown 文件，按日期倒序追加词条。
/// 词条为精简卡：标题行（词 + 音标 + 释义）+ 提炼后的要点正文，不用 callout 与时间戳。
/// 纯文本拼装与插入逻辑，文件读写由调用方（App 层）完成。
public enum VocabularyNotebook {

    /// 词汇表在 vault 中的目录名。
    public static let folderName = "词汇表"

    /// 文件名（spec 9.8）：不拆分 `词汇表.md`，按月 `2026-11.md`，按天 `2026-11-20.md`。
    public static func fileName(for date: Date = Date(), split: VocabularySplit = .month,
                                calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        switch split {
        case .none: return "\(folderName).md"
        case .month: return String(format: "%04d-%02d.md", c.year ?? 0, c.month ?? 0)
        case .day: return String(format: "%04d-%02d-%02d.md", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
    }

    /// 文件初始模板：frontmatter + 标题 + 插入锚点。锚点之后是词条区（最新在最上）。
    public static func template(for date: Date = Date(), split: VocabularySplit = .month,
                                calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let month = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        let day = String(format: "%@-%02d", month, c.day ?? 0)
        let (meta, heading): (String, String) = switch split {
        case .none: ("", "📚 词汇表")
        case .month: ("month: \(month)\n", "📚 词汇表 · \(c.year ?? 0) 年 \(c.month ?? 0) 月")
        case .day: ("date: \(day)\n", "📚 词汇表 · \(day)")
        }
        return "---\ntype: vocabulary\n\(meta)tags: [词汇表]\n---\n\n# \(heading)\n\n\(anchor)"
    }

    private static let anchor = "<!-- promptdock:insert -->"

    /// 单个词条的 Markdown：三级标题行（词 + 音标 + 释义）+ 提炼正文（首行核心释义，其后要点行）。
    public static func entry(title: String, phonetic: PhoneticInfo?, summary: String) -> String {
        var head = title
        if let phonetic {
            head += " `\(phonetic.ipa)`"
            if let gloss = phonetic.gloss { head += " " + gloss }
        }
        return """
            ### \(head)
            \(summary.trimmingCharacters(in: .whitespacesAndNewlines))
            """
    }

    /// 插入词条，返回新文件内容；文件内已有同标题词条时返回 nil（去重，不改内容）。
    /// 按天拆分时文件本身就是一天，词条直接插到锚点后；其余按天分节（不拆分时节标题带年份防跨年撞名）：
    /// 1. 有当天节 → 插到该节标题之后（当天最新在最上）；
    /// 2. 没有当天节 → 在插入锚点后新建当天节（保证倒序）；
    /// 3. 锚点也找不到（用户手工清过模板）→ 追加到文件末尾。
    public static func insert(entry: String, title: String, into content: String, date: Date = Date(),
                              split: VocabularySplit = .month, calendar: Calendar = .current) -> String? {
        guard !contains(titled: title, in: content) else { return nil }
        var lines = content.components(separatedBy: "\n")
        let entryLines = entry.components(separatedBy: "\n")
        let anchorIndex = lines.firstIndex(where: { $0.contains(anchor) })

        guard let dayHeading = dayHeading(for: date, split: split, calendar: calendar) else {
            if let anchorIndex {
                lines.insert(contentsOf: [""] + entryLines, at: anchorIndex + 1)
            } else {
                lines.append("")
                lines.append(contentsOf: entryLines)
            }
            return lines.joined(separator: "\n")
        }

        if let index = lines.firstIndex(where: { $0 == dayHeading || $0.hasPrefix(dayHeading + " ") }) {
            var insertAt = index + 1
            while insertAt < lines.count, lines[insertAt].isEmpty { insertAt += 1 }
            lines.insert(contentsOf: entryLines + [""], at: insertAt)
        } else if let anchorIndex {
            // 锚点后已有旧内容时，旧内容自带前导空行，这里不再补尾部空行（否则节间空两行）
            let next = anchorIndex + 1
            let tail = next < lines.count && !lines[next].isEmpty ? [""] : []
            lines.insert(contentsOf: ["", dayHeading, ""] + entryLines + tail, at: next)
        } else {
            lines.append("")
            lines.append(dayHeading)
            lines.append("")
            lines.append(contentsOf: entryLines)
        }
        return lines.joined(separator: "\n")
    }

    /// 当天节标题：按月 `## 03-05`，不拆分 `## 2077-03-05`，按天不分节（nil）。
    static func dayHeading(for date: Date, split: VocabularySplit, calendar: Calendar) -> String? {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        switch split {
        case .day: return nil
        case .month: return String(format: "## %02d-%02d", c.month ?? 0, c.day ?? 0)
        case .none: return String(format: "## %04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
    }

    /// 月文件里是否已有该标题的词条：标题行是 `### {title}`（独行或后接空格/音标反引号）。
    /// 边界精确匹配，避免 recap 误命中 recapture。
    public static func contains(titled title: String, in content: String) -> Bool {
        let prefix = "### \(title)"
        return content.components(separatedBy: "\n").contains { line in
            guard line.hasPrefix(prefix) else { return false }
            let rest = line.dropFirst(prefix.count)
            return rest.isEmpty || rest.hasPrefix(" ") || rest.hasPrefix("`")
        }
    }

    /// 原文首行（去掉空白）截断作词条标题；空原文回退"未命名"。
    public static func title(for source: String) -> String {
        let firstLine = source
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !firstLine.isEmpty else { return "未命名" }
        return firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
    }
}
