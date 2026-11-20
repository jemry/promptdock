import Foundation

/// 从 Obsidian 自己的 vault 列表（`~/Library/Application Support/obsidian/obsidian.json`）
/// 选出用户实际在用的 vault（spec 9.4）。纯解析，文件读取与目录存在性检查由调用方注入。
public enum ObsidianVaults {

    /// 规则：只看仍存在的目录；优先当前打开（`open: true`）的，其次最近使用（`ts` 最大）的。
    /// JSON 无法解析或没有可用 vault 时返回 nil。
    public static func preferred(configJSON: Data, exists: (String) -> Bool) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: configJSON) as? [String: Any],
              let vaults = root["vaults"] as? [String: Any] else { return nil }
        let candidates: [(path: String, open: Bool, ts: Double)] = vaults.values.compactMap { value in
            guard let v = value as? [String: Any], let path = v["path"] as? String, exists(path) else { return nil }
            return (path, (v["open"] as? Bool) ?? false, (v["ts"] as? NSNumber)?.doubleValue ?? 0)
        }
        return candidates.max { a, b in
            a.open != b.open ? !a.open : a.ts < b.ts
        }?.path
    }
}
