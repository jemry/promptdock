import Foundation
import Testing
@testable import PromptDockCore

/// 词汇表配置（spec 9.8）：解析、写回、设置表单、目录解析、按拆分方式生成文件。
struct VocabularySettingsTests {

    private func parse(_ yaml: String) throws -> (Settings, [LoadWarning]) {
        let r = try PromptLibraryParser.parse("version: 1\nsettings:\n" + yaml + "prompts: []\n")
        return (r.library.settings, r.warnings)
    }

    // MARK: - 解析

    @Test func 默认值() {
        let s = Settings()
        #expect(s.vocabulary.dir == nil)
        #expect(s.vocabulary.split == .month)
    }

    @Test func 解析目录与拆分() throws {
        let (s, w) = try parse("  vocabulary:\n    dir: ~/Notes/词汇表\n    split: day\n")
        #expect(s.vocabulary.dir == "~/Notes/词汇表")
        #expect(s.vocabulary.split == .day)
        #expect(w.isEmpty)
    }

    @Test func 无效拆分给警告并按月() throws {
        let (s, w) = try parse("  vocabulary:\n    split: week\n")
        #expect(s.vocabulary.split == .month)
        #expect(w.contains { $0.message.contains("vocabulary.split") })
    }

    @Test func 空目录视为未配置() throws {
        let (s, _) = try parse("  vocabulary:\n    dir: \"  \"\n")
        #expect(s.vocabulary.dir == nil)
    }

    // MARK: - 写回

    @Test func 默认值不写出() throws {
        let text = try ConfigWriter.serialize(Settings())
        #expect(!text.contains("vocabulary"))
    }

    @Test func 非默认值可以往返() throws {
        var s = Settings()
        s.vocabulary.dir = "~/Notes/词汇表"
        s.vocabulary.split = .none
        let updated = try ConfigWriter.replacingSettings(in: "version: 1\nprompts: []\n", with: s)
        let parsed = try PromptLibraryParser.parse(updated).library.settings
        #expect(parsed.vocabulary == s.vocabulary)
    }

    @Test func 改其他设置时词汇表配置保留() throws {
        let text = "version: 1\nsettings:\n  vocabulary:\n    split: day\nprompts: []\n"
        var s = try PromptLibraryParser.parse(text).library.settings
        s.llm.effort = "high"
        let updated = try ConfigWriter.replacingSettings(in: text, with: s)
        #expect(try PromptLibraryParser.parse(updated).library.settings.vocabulary.split == .day)
    }

    // MARK: - 设置表单

    @Test func 表单往返() throws {
        var s = Settings()
        var f = GeneralForm(s)
        #expect(f.vocabularyDir == "")
        #expect(f.vocabularySplit == .month)
        f.vocabularyDir = "  ~/Notes  "
        f.vocabularySplit = .none
        try f.apply(to: &s)
        #expect(s.vocabulary.dir == "~/Notes")
        #expect(s.vocabulary.split == .none)
        f.vocabularyDir = ""
        try f.apply(to: &s)
        #expect(s.vocabulary.dir == nil)
    }

    // MARK: - 目录解析

    private let home = URL(fileURLWithPath: "/Users/u")
    private var fallback: URL { home.appendingPathComponent("Documents/PromptDock/词汇表") }

    @Test func 配置优先并展开波浪号() {
        let dir = VocabularyLocation.resolve(configured: "~/Notes/词汇表", home: home,
                                             vault: URL(fileURLWithPath: "/v"), fallbackHasNotes: true)
        #expect(dir.path == "/Users/u/Notes/词汇表")
    }

    @Test func 默认目录已有数据时优先于vault() {
        let dir = VocabularyLocation.resolve(configured: nil, home: home,
                                             vault: URL(fileURLWithPath: "/v"), fallbackHasNotes: true)
        #expect(dir.path == fallback.path)
    }

    @Test func 有vault用vault下的词汇表() {
        let dir = VocabularyLocation.resolve(configured: nil, home: home,
                                             vault: URL(fileURLWithPath: "/v"), fallbackHasNotes: false)
        #expect(dir.path == "/v/词汇表")
    }

    @Test func 都没有用默认目录() {
        let dir = VocabularyLocation.resolve(configured: nil, home: home, vault: nil, fallbackHasNotes: false)
        #expect(dir.path == fallback.path)
    }

    @Test func 绝对路径原样使用() {
        let dir = VocabularyLocation.resolve(configured: "/data/词汇", home: home, vault: nil, fallbackHasNotes: false)
        #expect(dir.path == "/data/词汇")
    }

    @Test func 家目录显示缩写() {
        #expect(VocabularyLocation.display(URL(fileURLWithPath: "/Users/u/Notes/a.md"), home: home) == "~/Notes/a.md")
        #expect(VocabularyLocation.display(URL(fileURLWithPath: "/data/a.md"), home: home) == "/data/a.md")
    }

    // MARK: - 按拆分方式生成文件

    private var date: Date {
        Calendar.current.date(from: DateComponents(year: 2077, month: 3, day: 5, hour: 14))!
    }
    private var nextDay: Date { date.addingTimeInterval(86400) }

    @Test func 文件名随拆分方式变化() {
        #expect(VocabularyNotebook.fileName(for: date, split: .none) == "词汇表.md")
        #expect(VocabularyNotebook.fileName(for: date, split: .month) == "2077-03.md")
        #expect(VocabularyNotebook.fileName(for: date, split: .day) == "2077-03-05.md")
    }

    @Test func 模板标题随拆分方式变化() {
        #expect(VocabularyNotebook.template(for: date, split: .none).contains("# 📚 词汇表\n"))
        #expect(VocabularyNotebook.template(for: date, split: .month).contains("# 📚 词汇表 · 2077 年 3 月"))
        #expect(VocabularyNotebook.template(for: date, split: .day).contains("# 📚 词汇表 · 2077-03-05"))
        #expect(!VocabularyNotebook.template(for: date, split: .none).contains("month:"))
    }

    @Test func 不拆分时分节标题带年份() throws {
        var text = VocabularyNotebook.template(for: date, split: .none)
        text = try #require(VocabularyNotebook.insert(entry: "### a\n释义", title: "a", into: text, date: date, split: .none))
        text = try #require(VocabularyNotebook.insert(entry: "### b\n释义", title: "b", into: text, date: nextDay, split: .none))
        #expect(text.contains("## 2077-03-05"))
        let b = try #require(text.range(of: "## 2077-03-06"))
        let a = try #require(text.range(of: "## 2077-03-05"))
        #expect(b.lowerBound < a.lowerBound)   // 新的一天在上
        #expect(!text.contains("\n\n\n"))       // 节与节之间只空一行
    }

    @Test func 按天拆分时不分节且最新在上() throws {
        var text = VocabularyNotebook.template(for: date, split: .day)
        text = try #require(VocabularyNotebook.insert(entry: "### a\n释义", title: "a", into: text, date: date, split: .day))
        text = try #require(VocabularyNotebook.insert(entry: "### b\n释义", title: "b", into: text, date: date, split: .day))
        #expect(!text.contains("\n## "))
        let b = try #require(text.range(of: "### b"))
        let a = try #require(text.range(of: "### a"))
        #expect(b.lowerBound < a.lowerBound)
        #expect(VocabularyNotebook.insert(entry: "### a\n再来", title: "a", into: text, date: date, split: .day) == nil)
    }
}
