import Foundation
import PromptDockCore

/// 定位本机 Obsidian 仓库（vault）。
/// 1. 读 Obsidian 自己的 vault 列表，取当前打开 / 最近使用的（`ObsidianVaults.preferred`）；
/// 2. 读不到时兜底扫描常见位置：先看目录本身是不是 vault，再看一级子目录。
///    子目录里可能残留以前单独打开过的 `.obsidian`，所以目录本身优先，且只作兜底。
enum ObsidianVaultLocator {

    static func locate() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let config = home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        if let data = try? Data(contentsOf: config),
           let path = ObsidianVaults.preferred(configJSON: data, exists: { isVault(URL(fileURLWithPath: $0)) }) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let bases = [
            home.appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents"),
            home.appendingPathComponent("Documents"),
        ]
        for base in bases {
            if isVault(base) { return base }
            let children = (try? fm.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            if let dir = children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first(where: isVault) {
                return dir
            }
        }
        return nil
    }

    private static func isVault(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(".obsidian").path)
    }
}
