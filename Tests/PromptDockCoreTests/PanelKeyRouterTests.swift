import Testing
@testable import PromptDockCore

@Suite struct PanelKeyRouterTests {

    @Test func mapsNavigationAndActions() {
        #expect(PanelKeyRouter.command(keyCode: 126, commandKey: false, hasMarkedText: false) == .moveUp)
        #expect(PanelKeyRouter.command(keyCode: 125, commandKey: false, hasMarkedText: false) == .moveDown)
        #expect(PanelKeyRouter.command(keyCode: 36, commandKey: false, hasMarkedText: false) == .paste)
        #expect(PanelKeyRouter.command(keyCode: 76, commandKey: false, hasMarkedText: false) == .paste)
        #expect(PanelKeyRouter.command(keyCode: 36, commandKey: true, hasMarkedText: false) == .copy)
        #expect(PanelKeyRouter.command(keyCode: 53, commandKey: false, hasMarkedText: false) == .close)
        // ← 键映射为返回命令（结果页返回动作列表；是否适用由 Controller 按模式判断）
        #expect(PanelKeyRouter.command(keyCode: 123, commandKey: false, hasMarkedText: false) == .back)
    }

    @Test func ignoresOtherKeys() {
        #expect(PanelKeyRouter.command(keyCode: 0, commandKey: false, hasMarkedText: false) == nil)
        // → 和 ↑↑ 之外的方向键不映射，避免误触
        #expect(PanelKeyRouter.command(keyCode: 124, commandKey: false, hasMarkedText: false) == nil)
    }

    @Test func digitKeysMapToSelect() {
        // 苹果键盘数字键物理布局乱序：1=18、5=23、9=25
        #expect(PanelKeyRouter.command(keyCode: 18, commandKey: false, hasMarkedText: false) == .select(1))
        #expect(PanelKeyRouter.command(keyCode: 23, commandKey: false, hasMarkedText: false) == .select(5))
        #expect(PanelKeyRouter.command(keyCode: 25, commandKey: false, hasMarkedText: false) == .select(9))
        // 0 映射第 10 条；带修饰键不映射
        #expect(PanelKeyRouter.command(keyCode: 29, commandKey: false, hasMarkedText: false) == .select(10))
        #expect(PanelKeyRouter.command(keyCode: 18, commandKey: true, hasMarkedText: false) == nil)
    }

    @Test func commaWithControlOrCommandOpensSettings() {
        // 逗号 keyCode 43：⌃, 与 macOS 惯例 ⌘, 都打开设置；单按逗号是输入内容，放行
        #expect(PanelKeyRouter.command(keyCode: 43, commandKey: false, controlKey: true, hasMarkedText: false) == .openSettings)
        #expect(PanelKeyRouter.command(keyCode: 43, commandKey: true, hasMarkedText: false) == .openSettings)
        #expect(PanelKeyRouter.command(keyCode: 43, commandKey: false, hasMarkedText: false) == nil)
        #expect(PanelKeyRouter.command(keyCode: 43, commandKey: false, controlKey: true, hasMarkedText: true) == nil)
    }

    @Test func passesThroughWhileInputMethodIsComposing() {
        // 中文输入法组字时，回车/方向键/Esc 交给输入法，不能触发粘贴
        for code: UInt16 in [36, 76, 125, 126, 53, 123] {
            #expect(PanelKeyRouter.command(keyCode: code, commandKey: false, hasMarkedText: true) == nil)
        }
    }
}
