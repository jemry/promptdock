import Testing
@testable import PromptDockCore

/// 选区误判过滤（spec 9.2）。
struct SelectionFilterTests {

    @Test func 正常文本原样保留() {
        #expect(SelectionFilter.accept("hello world") == "hello world")
    }

    @Test func 只有空白视为无选区() {
        #expect(SelectionFilter.accept("\n") == nil)
        #expect(SelectionFilter.accept("  \t\r\n ") == nil)
        #expect(SelectionFilter.accept("") == nil)
    }

    @Test func 有内容时保留首尾空白() {
        // 选区原样替换回原文，首尾空白是原文的一部分，不能被裁掉
        #expect(SelectionFilter.accept("  code\n") == "  code\n")
    }
}
