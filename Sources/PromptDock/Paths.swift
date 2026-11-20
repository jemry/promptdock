import Foundation

/// 数据文件位置（spec 6.1）。
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let configFile = home.appendingPathComponent(".config/promptdock/prompts.yaml")
    static let usageDatabase = home.appendingPathComponent("Library/Application Support/PromptDock/usage.sqlite")
    static let historyDatabase = home.appendingPathComponent("Library/Application Support/PromptDock/history.sqlite")
    static let logFile = home.appendingPathComponent("Library/Logs/PromptDock/app.log")
}
