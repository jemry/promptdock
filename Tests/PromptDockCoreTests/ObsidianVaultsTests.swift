import Foundation
import Testing
@testable import PromptDockCore

struct ObsidianVaultsTests {

    private func json(_ s: String) -> Data { Data(s.utf8) }
    private let allExist: (String) -> Bool = { _ in true }

    @Test func 优先取打开中的vault() {
        let data = json(#"{"vaults":{"a":{"path":"/v/new","ts":200},"b":{"path":"/v/opened","ts":100,"open":true}}}"#)
        #expect(ObsidianVaults.preferred(configJSON: data, exists: allExist) == "/v/opened")
    }

    @Test func 没有打开中的取最近使用() {
        let data = json(#"{"vaults":{"a":{"path":"/v/old","ts":100},"b":{"path":"/v/recent","ts":300}}}"#)
        #expect(ObsidianVaults.preferred(configJSON: data, exists: allExist) == "/v/recent")
    }

    @Test func 跳过已不存在的目录() {
        let data = json(#"{"vaults":{"a":{"path":"/v/gone","ts":300,"open":true},"b":{"path":"/v/here","ts":100}}}"#)
        #expect(ObsidianVaults.preferred(configJSON: data, exists: { $0 == "/v/here" }) == "/v/here")
    }

    @Test func 格式不对或为空返回nil() {
        #expect(ObsidianVaults.preferred(configJSON: json("not json"), exists: allExist) == nil)
        #expect(ObsidianVaults.preferred(configJSON: json(#"{"vaults":{}}"#), exists: allExist) == nil)
        #expect(ObsidianVaults.preferred(configJSON: json(#"{"cli":true}"#), exists: allExist) == nil)
    }
}
