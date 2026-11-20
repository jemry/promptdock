import Foundation

/// 收藏到 Obsidian 词汇表（spec 9.4）：每月一个 Markdown 文件，按日期倒序追加词条。
/// 词条为精简卡：标题行（词 + 音标 + 释义）+ 提炼后的要点正文，不用 callout 与时间戳。
/// 纯文本拼装与插入逻辑，文件读写由调用方（App 层）完成。
public enum VocabularyNotebook {

    /// 词汇表在 vault 中的目录名。
    public static let folderName = "词汇表"

    /// 月度文件名，如 `2026-11.md`。
    public static func fileName(for date: Date = Date(), calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d.md", comps.year ?? 0, comps.month ?? 0)
    }

    /// 月度文件初始模板：frontmatter + 标题 + 插入锚点。锚点之后是词条区（最新在最上）。
    public static func template(for date: Date = Date(), calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return """
            ---
            type: vocabulary
            month: \(String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0))
            tags: [词汇表]
            ---

            # 📚 词汇表 · \(comps.year ?? 0) 年 \(comps.month ?? 0) 月

            <!-- promptdock:insert -->
            """
    }

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

    /// 插入词条，返回新文件内容；月文件内已有同标题词条时返回 nil（去重，不改内容）。规则：
    /// 1. 有当天日期节 → 词条插到该节标题块之后（当天最新在最上）；
    /// 2. 没有当天节 → 在插入锚点后新建当天节（保证月内倒序）；
    /// 3. 锚点也找不到（用户手工清过模板）→ 追加到文件末尾。
    public static func insert(entry: String, title: String, into content: String, date: Date = Date()) -> String? {
        guard !contains(titled: title, in: content) else { return nil }
        var lines = content.components(separatedBy: "\n")
        let dayHeading = "## \(Self.dayFormatter.string(from: date))"

        if let index = lines.firstIndex(where: { $0.hasPrefix(dayHeading) }) {
            // 当天节存在：跳过标题行及其后的空行，插到第一个词条前
            var insertAt = index + 1
            while insertAt < lines.count, lines[insertAt].isEmpty { insertAt += 1 }
            lines.insert(contentsOf: entry.components(separatedBy: "\n") + [""], at: insertAt)
        } else if let anchor = lines.firstIndex(where: { $0.contains("<!-- promptdock:insert -->") }) {
            // 新的一天：锚点后空一行接当天节，节与后续旧内容之间也留空行
            let block = ["", dayHeading, ""] + entry.components(separatedBy: "\n") + [""]
            lines.insert(contentsOf: block, at: anchor + 1)
        } else {
            // 兜底：追加末尾
            lines.append("")
            lines.append(dayHeading)
            lines.append("")
            lines.append(contentsOf: entry.components(separatedBy: "\n"))
        }
        return lines.joined(separator: "\n")
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

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()
}
