import Foundation
import PromptDockCore

/// ⭐ 收藏的结果：saved 携带提示文案（含写入路径），failed 携带错误/重复说明。
enum FavoriteResult {
    case saved(String)
    case failed(String)
}

/// 词汇表目录（spec 9.8）：探测 vault 与默认目录现状，交给 Core 的 VocabularyLocation 决定。
enum VocabularyLocator {

    static func directory(for settings: VocabularySettings) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let dir = settings.dir, !dir.isEmpty {
            return VocabularyLocation.resolve(configured: dir, home: home, vault: nil, fallbackHasNotes: false)
        }
        return VocabularyLocation.resolve(
            configured: nil, home: home,
            vault: ObsidianVaultLocator.locate(),
            fallbackHasNotes: hasNotes(VocabularyLocation.fallback(home: home)))
    }

    static func display(_ url: URL) -> String {
        VocabularyLocation.display(url, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    private static func hasNotes(_ dir: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { $0.hasSuffix(".md") }
    }
}
