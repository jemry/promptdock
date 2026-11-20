import Testing
import Foundation
@testable import PromptDockCore

struct HistoryStoreTests {

    private func makeStore() throws -> HistoryStore {
        try HistoryStore(path: ":memory:")
    }

    @Test func addAndRecentNewestFirst() throws {
        let store = try makeStore()
        store.add(title: "A", target: "t1", input: "i1", output: "o1", at: Date(timeIntervalSince1970: 100))
        store.add(title: "B", target: "t2", input: "i2", output: "o2", at: Date(timeIntervalSince1970: 200))
        let entries = store.recent()
        #expect(entries.count == 2)
        #expect(entries.first?.title == "B")   // 新的在前
        #expect(entries.last?.title == "A")
        #expect(entries.first?.createdAt == Date(timeIntervalSince1970: 200))
    }

    @Test func trimsToCapacity() throws {
        let store = try makeStore()
        for i in 0..<(HistoryStore.capacity + 20) {
            store.add(title: "t\(i)", target: "x", input: "i", output: "o")
        }
        let entries = store.recent()
        #expect(entries.count == HistoryStore.capacity)
        #expect(entries.first?.title == "t\(HistoryStore.capacity + 19)")   // 最新的保留
        #expect(entries.last?.title == "t20")                              // 最旧的删除
    }

    @Test func clearRemovesAll() throws {
        let store = try makeStore()
        store.add(title: "A", target: "t", input: "i", output: "o")
        store.clear()
        #expect(store.recent().isEmpty)
    }

    @Test func recentLimit() throws {
        let store = try makeStore()
        for i in 0..<5 { store.add(title: "t\(i)", target: "x", input: "i", output: "o") }
        #expect(store.recent(limit: 3).count == 3)
        #expect(store.recent(limit: 3).first?.title == "t4")
    }

    @Test func multilineTextRoundTrips() throws {
        let store = try makeStore()
        let text = "第一行\n第二行 \"引号\" '单引号'"
        store.add(title: "T", target: "x", input: text, output: text)
        #expect(store.recent().first?.input == text)
        #expect(store.recent().first?.output == text)
    }
}
