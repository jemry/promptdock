import Testing
@testable import PromptDockCore

struct SpeechPhoneticsTests {

    // MARK: - shouldLookup

    @Test func singleEnglishWordLooksUp() {
        #expect(SpeechPhonetics.shouldLookup("hallucination"))
    }

    @Test func acronymLooksUp() {
        #expect(SpeechPhonetics.shouldLookup("RAG"))
    }

    @Test func shortPhraseLooksUp() {
        #expect(SpeechPhonetics.shouldLookup("retrieval augmented generation"))
    }

    @Test func hyphenatedCountsAsOneWord() {
        #expect(SpeechPhonetics.shouldLookup("state-of-the-art"))
    }

    @Test func fourWordsIsTheLimit() {
        #expect(SpeechPhonetics.shouldLookup("a b c d"))
        #expect(!SpeechPhonetics.shouldLookup("a b c d e"))
    }

    @Test func longTextSkipped() {
        #expect(!SpeechPhonetics.shouldLookup("The quick brown fox jumps over the lazy dog"))
    }

    @Test func chineseSkipped() {
        #expect(!SpeechPhonetics.shouldLookup("检索增强生成"))
    }

    @Test func mixedWithChineseSkipped() {
        #expect(!SpeechPhonetics.shouldLookup("RAG 检索增强"))
    }

    @Test func emptyAndWhitespaceSkipped() {
        #expect(!SpeechPhonetics.shouldLookup(""))
        #expect(!SpeechPhonetics.shouldLookup("   \n "))
    }

    @Test func pureNumberSkipped() {
        #expect(!SpeechPhonetics.shouldLookup("42"))
    }

    @Test func wordWithDigitsLooksUp() {
        #expect(SpeechPhonetics.shouldLookup("GPT-4o"))
    }

    // MARK: - normalize（IPA 提取）

    @Test func plainIPAKept() {
        #expect(SpeechPhonetics.normalize("/ræɡ/") == PhoneticInfo(ipa: "/ræɡ/", gloss: nil))
    }

    @Test func prefixProseStripped() {
        #expect(SpeechPhonetics.normalize("音标：/ˌdʒiː piː ˈjuː/\n") == PhoneticInfo(ipa: "/ˌdʒiː piː ˈjuː/", gloss: nil))
    }

    @Test func firstOfMultiplePairsTaken() {
        #expect(SpeechPhonetics.normalize("/ræɡ/ /rɑːɡ/") == PhoneticInfo(ipa: "/ræɡ/", gloss: "/rɑːɡ/"))
    }

    @Test func markdownWrapperStripped() {
        #expect(SpeechPhonetics.normalize("*/ˈtɒkənaɪzə/*") == PhoneticInfo(ipa: "/ˈtɒkənaɪzə/", gloss: nil))
    }

    @Test func noSlashesReturnsNil() {
        #expect(SpeechPhonetics.normalize("ræɡ") == nil)
    }

    @Test func chineseInsideSlashesReturnsNil() {
        #expect(SpeechPhonetics.normalize("/中文/") == nil)
    }

    @Test func overlongRunReturnsNil() {
        #expect(SpeechPhonetics.normalize("/" + String(repeating: "æ", count: 61) + "/") == nil)
    }

    // MARK: - normalize（中文释义提取）

    @Test func glossAfterIpaParsed() {
        #expect(SpeechPhonetics.normalize("/ˈriːkæp/ 扼要重述") == PhoneticInfo(ipa: "/ˈriːkæp/", gloss: "扼要重述"))
    }

    @Test func glossLabelStripped() {
        #expect(SpeechPhonetics.normalize("/ræɡ/，中文意思：检索增强生成") == PhoneticInfo(ipa: "/ræɡ/", gloss: "检索增强生成"))
    }

    @Test func glossOnNextLineParsed() {
        #expect(SpeechPhonetics.normalize("/ræɡ/\n图形处理器") == PhoneticInfo(ipa: "/ræɡ/", gloss: "图形处理器"))
    }

    @Test func glossOnlyBeforeIpaIgnored() {
        #expect(SpeechPhonetics.normalize("音标 /ræɡ/") == PhoneticInfo(ipa: "/ræɡ/", gloss: nil))
    }

    @Test func overlongGlossDropped() {
        #expect(SpeechPhonetics.normalize("/ræɡ/ " + String(repeating: "长", count: 25))?.gloss == nil)
    }
}
