import Testing
import Foundation
@testable import PromptDockCore

struct VocabularyNotebookTests {

    /// 固定日期（本地时区 2077-03-05），测试不依赖运行当天。
    private var date: Date {
        Calendar.current.date(from: DateComponents(year: 2077, month: 3, day: 5, hour: 14, minute: 30))!
    }

    // MARK: - 文件名与模板

    @Test func monthlyFileName() {
        #expect(VocabularyNotebook.fileName(for: date) == "2077-03.md")
    }

    @Test func templateIsCompact() {
        let text = VocabularyNotebook.template(for: date)
        #expect(text.contains("type: vocabulary"))
        #expect(text.contains("# 📚 词汇表 · 2077 年 3 月"))
        #expect(text.contains("<!-- promptdock:insert -->"))
        #expect(!text.contains("[!"))   // 不用 callout
    }

    // MARK: - 词条标题

    @Test func titleUsesFirstNonEmptyLine() {
        #expect(VocabularyNotebook.title(for: "\n  \nrecap is short\nsecond line") == "recap is short")
    }

    @Test func titleTruncatedToForty() {
        let long = String(repeating: "a", count: 50)
        #expect(VocabularyNotebook.title(for: long) == String(repeating: "a", count: 40) + "…")
    }

    @Test func titleFallsBackWhenEmpty() {
        #expect(VocabularyNotebook.title(for: " \n ") == "未命名")
    }

    // MARK: - 词条内容

    @Test func entryIsCompactCard() {
        let info = PhoneticInfo(ipa: "/ˈriːkæp/", gloss: "概括；简要回顾")
        let text = VocabularyNotebook.entry(
            title: "recap", phonetic: info, summary: "回顾重述要点。\n- 比 summary 口语化")
        #expect(text.hasPrefix("### recap `/ˈriːkæp/` 概括；简要回顾\n"))
        #expect(text.contains("回顾重述要点。"))
        #expect(!text.contains("[!"))       // 无 callout
        #expect(!text.contains("🕐"))       // 无时间戳
    }

    @Test func entryWithoutPhoneticOmitsBackticks() {
        let text = VocabularyNotebook.entry(title: "回顾", phonetic: nil, summary: "解释")
        #expect(text.hasPrefix("### 回顾\n"))
        #expect(!text.contains("`"))
    }

    // MARK: - 插入与去重

    @Test func firstEntryCreatesDaySectionAfterAnchor() {
        let file = VocabularyNotebook.template(for: date)
        let updated = VocabularyNotebook.insert(entry: "ENTRY", title: "recap", into: file, date: date)
        #expect(updated != nil)
        #expect(updated!.contains("## 03-05"))
        let anchor = updated!.range(of: "<!-- promptdock:insert -->")!.upperBound
        #expect(updated![anchor...].contains("ENTRY"))
    }

    @Test func secondEntrySameDayInsertedAtTopOfSection() {
        var file = VocabularyNotebook.template(for: date)
        file = VocabularyNotebook.insert(entry: "FIRST", title: "a", into: file, date: date)!
        let updated = VocabularyNotebook.insert(entry: "SECOND", title: "b", into: file, date: date)
        #expect(updated != nil)
        let first = updated!.range(of: "FIRST")!.lowerBound
        let second = updated!.range(of: "SECOND")!.lowerBound
        #expect(second < first)   // 最新在最上
    }

    @Test func newDaySectionStaysAboveOldDays() {
        let older = Calendar.current.date(from: DateComponents(year: 2077, month: 3, day: 1))!
        var file = VocabularyNotebook.template(for: date)
        file = VocabularyNotebook.insert(entry: "OLD", title: "a", into: file, date: older)!
        file = VocabularyNotebook.insert(entry: "NEW", title: "b", into: file, date: date)!
        let old = file.range(of: "## 03-01")!.lowerBound
        let new = file.range(of: "## 03-05")!.lowerBound
        #expect(new < old)   // 月内倒序：晚的一天靠上
    }

    @Test func duplicateTitleRejected() {
        var file = VocabularyNotebook.template(for: date)
        file = VocabularyNotebook.insert(entry: "### recap\n要点", title: "recap", into: file, date: date)!
        // 同标题再插入：返回 nil，内容不变
        let again = VocabularyNotebook.insert(entry: "### recap\n另一版", title: "recap", into: file, date: date)
        #expect(again == nil)
    }

    @Test func duplicateMatchesWholeTitleOnly() {
        var file = VocabularyNotebook.template(for: date)
        file = VocabularyNotebook.insert(entry: "### recap\n要点", title: "recap", into: file, date: date)!
        // recapture 是另一个词，不算重复
        let other = VocabularyNotebook.insert(entry: "### recapture\nx", title: "recapture", into: file, date: date)
        #expect(other != nil)
    }

    @Test func duplicateDetectedAcrossDaysInSameMonth() {
        let day1 = Calendar.current.date(from: DateComponents(year: 2077, month: 3, day: 1))!
        var file = VocabularyNotebook.template(for: date)
        file = VocabularyNotebook.insert(entry: "### recap\nx", title: "recap", into: file, date: day1)!
        let later = VocabularyNotebook.insert(entry: "### recap\ny", title: "recap", into: file, date: date)
        #expect(later == nil)   // 同月跨天也去重
    }

    @Test func missingAnchorAppendsToEnd() {
        let updated = VocabularyNotebook.insert(entry: "ENTRY", title: "x", into: "# 只有标题", date: date)
        #expect(updated != nil)
        #expect(updated!.hasSuffix("ENTRY"))
        #expect(updated!.contains("## 03-05"))
    }
}
