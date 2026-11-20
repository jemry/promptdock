import Foundation

/// 朗读查询结果：IPA 音标（如 `/ræɡ/`）与可选的中文简意。
public struct PhoneticInfo: Equatable {
    public let ipa: String
    public let gloss: String?

    public init(ipa: String, gloss: String?) {
        self.ipa = ipa
        self.gloss = gloss
    }
}

/// 🔊 朗读音标（spec 9.4）：判断哪些文本值得查音标，并把模型返回整理成 IPA + 简要中文释义。
public enum SpeechPhonetics {

    /// 只对短英文文本查音标：中文（要的是拼音，暂不做）与整段长文本不给音标。
    public static func shouldLookup(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return false }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || ",，、;；.。!！?？".contains($0) })
        guard (1...4).contains(words.count) else { return false }
        return words.contains { $0.contains(where: \.isLetter) }
    }

    /// 从模型输出里取出第一段 `/.../` 音标和其后的简要中文释义；没有斜杠、音标过长或含中文都视为无效。
    public static func normalize(_ output: String) -> PhoneticInfo? {
        guard let range = output.range(of: #"/[^/\n]{1,60}/"#, options: .regularExpression) else { return nil }
        let ipa = String(output[range])
        guard !ipa.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return nil }
        return PhoneticInfo(ipa: ipa, gloss: gloss(in: output, ipaRange: range))
    }

    /// 释义取音标之后的第一个非空行：先剥首尾标点再剥「中文意思：」类标签（顺序不能反，
    /// 模型常输出「/ræɡ/，中文意思：xx」这类逗号打头的格式），超长（>24 字符）视为无效。
    private static func gloss(in output: String, ipaRange: Range<String.Index>) -> String? {
        let after = output[ipaRange.upperBound...]
            .components(separatedBy: "\n")
            .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        let punctuation = CharacterSet(charactersIn: " ：:，,；;、-—*#·")
        var gloss = (after.first ?? "")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: punctuation)
        for label in ["中文意思：", "中文意思:", "意思：", "意思:", "含义：", "含义:", "中文：", "中文:", "音标：", "音标:"]
        where gloss.hasPrefix(label) {
            gloss = String(gloss.dropFirst(label.count))
            break
        }
        gloss = gloss.trimmingCharacters(in: punctuation)
        guard !gloss.isEmpty, gloss.count <= 24 else { return nil }
        return gloss
    }
}
