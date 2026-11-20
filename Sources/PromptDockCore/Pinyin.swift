import Foundation
import Synchronization

/// 汉字转拼音索引（spec 10 拼音检索）：系统 Latin 转换生成全拼与首字母，零依赖零数据表。
/// 「排查问题」→ 全拼 `paichawenti`、首字母 `pcwt`；不含汉字的文本返回 nil（不参与拼音档）。
public enum Pinyin {

    /// 文本的全拼（无声调、无分隔）与首字母串；文本不含汉字时返回 nil。
    /// 英文/数字按片段混入（「GPT-4o 测试」→ `gpt4oceshi` / `g4cs`）。
    public static func index(for text: String) -> (full: String, initials: String)? {
        // ICU 转换每条约 0.15ms，搜索时每次按键对每条标题都要算一遍，按标题缓存
        if let cached = cache.withLock({ $0[text] }) { return cached.value }
        let value = compute(text)
        cache.withLock { $0[text] = Entry(value: value) }
        return value
    }

    private struct Entry: Sendable {
        let value: (full: String, initials: String)?
    }

    private static let cache = Mutex<[String: Entry]>([:])

    private static func compute(_ text: String) -> (full: String, initials: String)? {
        guard text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return nil }
        // toLatin：汉字→带调拼音（空格/标点分隔），非汉字原样；stripCombiningMarks 去声调
        guard let toned = text.applyingTransform(.toLatin, reverse: false),
              let plain = toned.applyingTransform(.stripCombiningMarks, reverse: false) else { return nil }
        let syllables = plain.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !syllables.isEmpty else { return nil }
        return (syllables.joined(), syllables.compactMap(\.first).map(String.init).joined())
    }
}
