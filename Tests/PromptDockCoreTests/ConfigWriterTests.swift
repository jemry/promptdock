import Foundation
import Testing
@testable import PromptDockCore

@Suite struct ConfigWriterTests {

    private static let original = """
    # 头部注释
    version: 1

    settings:
      llm:
        provider: deepseek   # 行尾注释
      providers:
        deepseek:
          protocol: openai
          base_url: https://api.deepseek.com
          model: deepseek-flash
          extra_body:
            thinking:
              type: disabled

    # prompts 前的注释
    prompts:
      - id: a
        title: 甲
        keywords: [x, y]
        content: |
          第一行
          第二行  # 不是注释
    """

    private func settings(of text: String) throws -> Settings {
        try PromptLibraryParser.parse(text).library.settings
    }

    @Test func 修改默认服务后其余内容不变() throws {
        var s = try settings(of: Self.original)
        s.providers["ollama"] = ProviderConfig(
            name: "ollama", protocolType: .openai,
            baseURL: URL(string: "http://localhost:11434/v1")!, model: "qwen")
        s.llm.provider = "ollama"

        let updated = try ConfigWriter.replacingSettings(in: Self.original, with: s)
        let result = try PromptLibraryParser.parse(updated)
        #expect(result.library.settings == s)
        #expect(result.warnings.isEmpty)
        // prompts 段及其前面的注释原样保留
        let tail = Self.original.range(of: "# prompts 前的注释")!
        #expect(updated.hasSuffix(String(Self.original[tail.lowerBound...])))
        #expect(updated.hasPrefix("# 头部注释\nversion: 1\n\nsettings:\n"))
    }

    @Test func 全部字段可以往返() throws {
        var s = Settings()
        s.hotkeys.promptPanel = "control+option+p"
        s.hotkeys.actionPanel = "option+shift+a"
        s.paste.restoreClipboard = false
        s.paste.restoreDelayMs = 800
        s.llm.provider = "claude"
        s.llm.effort = "high"
        s.network.proxy = ProxySetting(host: "127.0.0.1", port: 7890)
        s.keepHistory = true
        let body = try JSONSerialization.data(
            withJSONObject: ["reasoning_effort": "none", "flag": true, "n": 3, "s": "true",
                             "list": [1, "a"], "nested": ["k": false]],
            options: [.sortedKeys])
        s.providers = [
            "claude": ProviderConfig(name: "claude", protocolType: .anthropic,
                                     baseURL: URL(string: "https://api.anthropic.com")!, model: "claude-opus-5-5",
                                     maxTokens: 32000, effort: "low"),
            "local": ProviderConfig(name: "local", protocolType: .openai,
                                    baseURL: URL(string: "http://localhost:11434/v1")!, model: "qwen3.8:27b-mlx",
                                    extraBody: body),
        ]
        let updated = try ConfigWriter.replacingSettings(in: "version: 1\nprompts: []\n", with: s)
        let parsed = try settings(of: updated)
        #expect(parsed == s)
    }

    @Test func 改其他设置时keep_history保留() throws {
        let text = "version: 1\nsettings:\n  keep_history: true\nprompts: []\n"
        var s = try settings(of: text)
        #expect(s.keepHistory)
        s.llm.effort = "high"
        let updated = try ConfigWriter.replacingSettings(in: text, with: s)
        #expect(try settings(of: updated).keepHistory)
    }

    @Test func 没有settings段时插到version后面() throws {
        var s = Settings()
        s.llm.effort = "high"
        let text = "version: 1\nprompts:\n  - id: a\n    title: 甲\n    content: c\n"
        let updated = try ConfigWriter.replacingSettings(in: text, with: s)
        #expect(updated.hasPrefix("version: 1\nsettings:\n"))
        #expect(updated.hasSuffix("prompts:\n  - id: a\n    title: 甲\n    content: c\n"))
        #expect(try settings(of: updated) == s)
    }

    @Test func settings在最后时也能替换() throws {
        let text = "version: 1\nprompts: []\nsettings:\n  llm:\n    provider: x\n"
        var s = Settings()
        s.llm.provider = "anthropic"
        let updated = try ConfigWriter.replacingSettings(in: text, with: s)
        #expect(updated.hasPrefix("version: 1\nprompts: []\nsettings:\n"))
        #expect(try settings(of: updated) == s)
    }

    @Test func 配置文件本身有错时拒绝写入() {
        #expect(throws: PromptLibraryError.self) {
            try ConfigWriter.replacingSettings(in: "version: 1\nprompts: [\n", with: Settings())
        }
    }

    @Test func 无法定位settings段时拒绝写入() {
        // 流式写法的根节点没有独立的 settings: 行
        #expect(throws: SettingsWriterError.self) {
            var s = Settings()
            s.llm.effort = "high"
            return try ConfigWriter.replacingSettings(in: "{version: 1, settings: {}, prompts: []}", with: s)
        }
    }

    @Test func 示例配置可以改写() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/prompts.example.yaml")
        let text = try String(contentsOf: url, encoding: .utf8)
        let before = try PromptLibraryParser.parse(text).library
        var s = before.settings
        s.llm.provider = s.providers.keys.sorted().last!
        let updated = try ConfigWriter.replacingSettings(in: text, with: s)
        let after = try PromptLibraryParser.parse(updated).library
        #expect(after.settings == s)
        #expect(after.prompts == before.prompts)
    }

    // MARK: - prompts 段

    private func library(_ text: String) throws -> PromptLibrary {
        try PromptLibraryParser.parse(text).library
    }

    @Test func 修改提示词时settings段原样保留() throws {
        let base = try library(Self.original)
        var target = base
        target.prompts.append(Prompt(id: "b", title: "乙", type: .action, keywords: ["k"], tags: ["t1", "t2"],
                                     content: "改写：\n{selection}\n", provider: "deepseek", model: "m",
                                     system: "系统", output: .copy))
        target.prompts[0].title = "甲2"
        let updated = try ConfigWriter.update(Self.original, from: base, to: target)
        #expect(try library(updated) == target)
        let head = Self.original.range(of: "# prompts 前的注释")!
        #expect(updated.hasPrefix(String(Self.original[..<head.upperBound])))
        #expect(updated.contains("content: |\n      改写：\n      {selection}\n"))
        #expect(updated.contains("\n\n  - id: b"))
    }

    @Test(arguments: [
        "单行",
        "多行\n末尾无换行",
        "末尾多个换行\n\n\n",
        "  开头有空格\n第二行",
        "行尾空格  \n第二行\n",
        "含 # 号: 冒号 - 横线\n'引号' \"双引号\"\n",
        "\t制表符\n",
        "true",
        "123",
        "- 列表样子\n",
    ])
    func 各种内容可以往返(content: String) throws {
        let base = try library("version: 1\nprompts: []\n")
        var target = base
        target.prompts = [Prompt(id: "x", title: "标题", content: content, system: content)]
        let updated = try ConfigWriter.update("version: 1\nprompts: []\n", from: base, to: target)
        #expect(try library(updated).prompts == target.prompts)
    }

    @Test func 紧凑列表写法也能定位() throws {
        let text = "version: 1\nprompts:\n- id: a\n  title: 甲\n  content: c\nsettings:\n  llm:\n    provider: x\n"
        let base = try library(text)
        var target = base
        target.prompts[0].title = "乙"
        let updated = try ConfigWriter.update(text, from: base, to: target)
        #expect(try library(updated) == target)
        #expect(updated.hasSuffix("settings:\n  llm:\n    provider: x\n"))
    }

    @Test func 没有prompts段时追加到末尾() throws {
        let text = "version: 1\n"
        let base = try library(text)
        var target = base
        target.prompts = [Prompt(id: "a", title: "甲", content: "c")]
        let updated = try ConfigWriter.update(text, from: base, to: target)
        #expect(try library(updated).prompts == target.prompts)
    }

    @Test func 删光提示词() throws {
        let base = try library(Self.original)
        var target = base
        target.prompts = []
        let updated = try ConfigWriter.update(Self.original, from: base, to: target)
        #expect(try library(updated) == target)
    }

    @Test func 外部修改了同一段时拒绝覆盖() throws {
        let base = try library(Self.original)
        let external = Self.original.replacingOccurrences(of: "title: 甲", with: "title: 外部改的")
        var target = base
        target.prompts[0].content = "窗口里改的"
        #expect(throws: SettingsWriterError.self) {
            try ConfigWriter.update(external, from: base, to: target)
        }
    }

    @Test func 外部修改了另一段时保留外部修改() throws {
        let base = try library(Self.original)
        let external = Self.original.replacingOccurrences(of: "title: 甲", with: "title: 外部改的")
        var target = base
        target.settings.llm.effort = "high"
        let updated = try ConfigWriter.update(external, from: base, to: target)
        let after = try library(updated)
        #expect(after.settings == target.settings)
        #expect(after.prompts[0].title == "外部改的")
    }

    @Test func 没有变化时原文不动() throws {
        let base = try library(Self.original)
        #expect(try ConfigWriter.update(Self.original, from: base, to: base) == Self.original)
    }

    @Test func 连续保存两次文本稳定() throws {
        for text in [Self.original, Self.original + "\n", "version: 1\nprompts:\n  - id: a\n    title: 甲\n    content: c\n\n\n"] {
            let base = try library(text)
            var target = base
            target.prompts[0].title = "改1"
            let once = try ConfigWriter.update(text, from: base, to: target)
            var target2 = target
            target2.prompts[0].title = "改2"
            let twice = try ConfigWriter.update(once, from: target, to: target2)
            target2.prompts[0].title = "改1"
            let back = try ConfigWriter.update(twice, from: try library(twice), to: target2)
            #expect(back == once)
        }
    }
}
