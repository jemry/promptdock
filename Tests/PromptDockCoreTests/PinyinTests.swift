import Testing
@testable import PromptDockCore

struct PinyinTests {

    @Test func fullAndInitials() {
        let index = Pinyin.index(for: "排查问题")
        #expect(index?.full == "paichawenti")
        #expect(index?.initials == "pcwt")
    }

    @Test func punctuationSplit() {
        let index = Pinyin.index(for: "复盘/沉淀")
        #expect(index?.full == "fupanchendian")
        #expect(index?.initials == "fpcd")
    }

    @Test func mixedWithEnglishAndDigits() {
        let index = Pinyin.index(for: "GPT-4o 测试")
        #expect(index?.full == "gpt4oceshi")
        #expect(index?.initials == "g4cs")
    }

    @Test func pureEnglishReturnsNil() {
        #expect(Pinyin.index(for: "recap") == nil)
        #expect(Pinyin.index(for: "") == nil)
        #expect(Pinyin.index(for: "123") == nil)
    }
}

struct PinyinSearchTests {

    private func prompt(_ title: String, id: String = "p1") -> Prompt {
        Prompt(id: id, title: title, keywords: [], content: "")
    }

    @Test func initialsMatchChineseTitle() {
        #expect(Matcher.matchScore(query: "pcwt", prompt: prompt("排查问题")) > 0)
    }

    @Test func fullPinyinMatchChineseTitle() {
        #expect(Matcher.matchScore(query: "paicha", prompt: prompt("排查问题")) > 0)
    }

    @Test func initialsRankBelowDirectTitleMatch() {
        let prompts = [prompt("排查问题", id: "a"), prompt("排除法", id: "b")]
        let ranked = Matcher.rank(prompts: prompts, frecency: [:], query: "paicha")
        // 全拼前缀命中「排查问题」，「排除法」全拼 paichufa 也含 paicha 子串，前缀分应更高
        #expect(ranked.first?.prompt.id == "a")
    }

    @Test func englishQueryStillMatchesEnglishTitle() {
        #expect(Matcher.matchScore(query: "recap", prompt: prompt("recap")) > 0)
    }

    @Test func scatteredLettersDoNotHitPinyin() {
        // shujufenxi 里 u…i 是子序列，但拼音档只认连续命中，否则短英文查询会误中大量中文标题
        #expect(Matcher.matchScore(query: "ui", prompt: prompt("数据分析")) == 0)
        #expect(Matcher.matchScore(query: "fenxi", prompt: prompt("数据分析")) > 0)
    }

    @Test func chineseQueryUnaffected() {
        #expect(Matcher.matchScore(query: "排查", prompt: prompt("排查问题")) > 0)
    }
}
