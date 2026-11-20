import Foundation

/// 词汇表目录解析（spec 9.8）。纯逻辑：vault 定位与「默认目录是否已有词条」由调用方探测后传入。
public enum VocabularyLocation {

    /// 没装 Obsidian、也没配置时的默认目录（相对家目录）。
    public static let fallbackRelativePath = "Documents/PromptDock/词汇表"

    public static func fallback(home: URL) -> URL {
        home.appendingPathComponent(fallbackRelativePath, isDirectory: true)
    }

    /// 顺序：配置 → 默认目录已有词条（已有数据优先，避免后装 Obsidian 后新旧分家）→ vault/词汇表 → 默认目录。
    public static func resolve(configured: String?, home: URL, vault: URL?, fallbackHasNotes: Bool) -> URL {
        if let configured, !configured.isEmpty {
            return URL(fileURLWithPath: expandTilde(configured, home: home), isDirectory: true)
        }
        if fallbackHasNotes { return fallback(home: home) }
        if let vault { return vault.appendingPathComponent(VocabularyNotebook.folderName, isDirectory: true) }
        return fallback(home: home)
    }

    /// 展示用路径：家目录缩写为 ~。
    public static func display(_ url: URL, home: URL) -> String {
        let path = url.path
        let homePath = home.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    static func expandTilde(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + path.dropFirst(1) }
        return path
    }
}
