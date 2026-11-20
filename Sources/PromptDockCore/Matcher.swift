import Foundation

public struct RankedPrompt: Sendable, Equatable {
    public var prompt: Prompt
    /// 综合分：匹配分 + frecency 加成。
    public var score: Double
    public var matchScore: Double
    public var frecency: Double
}

/// 模糊匹配与综合排序。算法见 docs/spec.md 第 7.2、7.3 节。纯函数，无副作用。
public enum Matcher {

    static let titleWeight = 1.0
    static let keywordWeight = 0.9
    static let tagWeight = 0.6
    static let contentWeight = 0.3
    /// 拼音档权重：低于关键词、高于内容——直接打中文/关键词的命中应排在前。
    static let pinyinFullWeight = 0.85
    static let pinyinInitialsWeight = 0.8
    /// frecency 加成上限（结果集内最大 frecency 拿满加成）。
    static let frecencyBonus = 0.3

    // MARK: - 排序

    public static func rank(prompts: [Prompt], frecency: [String: Double], query: String) -> [RankedPrompt] {
        let q = normalize(query)

        if q.isEmpty {
            return prompts
                .map { RankedPrompt(prompt: $0, score: frecency[$0.id] ?? 0, matchScore: 0, frecency: frecency[$0.id] ?? 0) }
                .sorted(by: ordered)
        }

        let matched: [(Prompt, Double)] = prompts.compactMap { prompt in
            let score = matchScore(normalizedQuery: q, prompt: prompt)
            return score > 0 ? (prompt, score) : nil
        }
        let maxFrecency = matched.map { frecency[$0.0.id] ?? 0 }.max() ?? 0

        return matched
            .map { prompt, match in
                let f = frecency[prompt.id] ?? 0
                let bonus = maxFrecency > 0 ? frecencyBonus * (f / maxFrecency) : 0
                return RankedPrompt(prompt: prompt, score: match + bonus, matchScore: match, frecency: f)
            }
            .sorted(by: ordered)
    }

    /// 排序规则：综合分降序 → frecency 降序 → title 升序 → id 升序，保证结果稳定。
    private static func ordered(_ a: RankedPrompt, _ b: RankedPrompt) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.frecency != b.frecency { return a.frecency > b.frecency }
        let byTitle = a.prompt.title.localizedStandardCompare(b.prompt.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return a.prompt.id < b.prompt.id
    }

    // MARK: - 匹配

    /// 条目匹配分：各字段得分 × 权重，取最大值（0~1）。
    public static func matchScore(query: String, prompt: Prompt) -> Double {
        matchScore(normalizedQuery: normalize(query), prompt: prompt)
    }

    private static func matchScore(normalizedQuery q: String, prompt: Prompt) -> Double {
        guard !q.isEmpty else { return 0 }
        let candidates: [(Double, [String])] = [
            (titleWeight, [prompt.title]),
            (keywordWeight, prompt.keywords),
            (tagWeight, prompt.tags),
            (contentWeight, [prompt.content]),
        ]
        var best = 0.0
        // 中文标题的拼音索引（spec 7.2）：pcwt / paichawenti 都能命中「排查问题」。
        // 只认相等/前缀/连续子串，不走子序列：拼音串只有字母，ui、ai 这类短查询按子序列几乎处处命中
        if let pinyin = Pinyin.index(for: prompt.title) {
            for (weight, text) in [(pinyinFullWeight, pinyin.full), (pinyinInitialsWeight, pinyin.initials)] {
                let s = score(normalizedQuery: q, text: text)
                if s >= 0.75 { best = max(best, weight * s) }
            }
        }
        for (weight, texts) in candidates where weight > best {
            for text in texts {
                best = max(best, weight * score(normalizedQuery: q, text: normalize(text)))
                if best == weight { break }
            }
        }
        return best
    }

    /// 单字段得分（0~1）：完全相等 1.0；前缀 0.9；连续子串 0.75；子序列 0.5 × 紧凑度；不匹配 0。
    public static func fieldScore(query: String, text: String) -> Double {
        score(normalizedQuery: normalize(query), text: normalize(text))
    }

    private static func score(normalizedQuery q: String, text t: String) -> Double {
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        if t == q { return 1.0 }
        if t.hasPrefix(q) { return 0.9 }
        if t.contains(q) { return 0.75 }
        guard let span = tightestSubsequenceSpan(Array(q), in: Array(t)) else { return 0 }
        return 0.5 * Double(q.count) / Double(span)
    }

    /// 查询串作为子序列出现在文本中的最短跨度（字符数）；不出现返回 nil。
    ///
    /// 前向-后向收缩：从 i 起向前贪心找到最早的结束位置 end，再从 end 向后贪心
    /// 找到最晚的起点 start，得到以 end 结尾的最短窗口；然后从 start + 1 继续。
    /// 比「每个起点都向后扫到底」快得多（实测 500 条 × 2000 字极端数据从 2.5s 降到毫秒级）。
    private static func tightestSubsequenceSpan(_ q: [Character], in t: [Character]) -> Int? {
        guard !q.isEmpty, q.count <= t.count else { return nil }
        var best: Int?
        var i = 0
        while i < t.count {
            // 向前：找到能匹配完整查询串的最早结束位置
            var qi = 0
            var ti = i
            while ti < t.count, qi < q.count {
                if t[ti] == q[qi] { qi += 1 }
                ti += 1
            }
            guard qi == q.count else { break }
            let end = ti - 1

            // 向后：从 end 往回贪心匹配，得到最晚的起点
            var qj = q.count - 1
            var start = end
            while true {
                if t[start] == q[qj] {
                    if qj == 0 { break }
                    qj -= 1
                }
                start -= 1
            }

            let span = end - start + 1
            if best == nil || span < best! { best = span }
            if span == q.count { break }
            i = start + 1
        }
        return best
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
