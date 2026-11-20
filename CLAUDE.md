# PromptDock

macOS 菜单栏提示词管理器（Swift 6 / SwiftPM，macOS 15+）。⌥Space 搜索并粘贴提示词，⌥⇧Space 对选中文字调用模型。完整设计见 `docs/spec.md`，改动行为前先读对应章节，改完同步更新 spec。

## 命令

| 命令 | 作用 |
|---|---|
| `make test` | 单元测试（Swift Testing，只覆盖 PromptDockCore） |
| `make install` | 编译 → 打包 → 自签名 → 装到 `~/Applications` 并重启应用 |
| `swift scripts/make-icon.swift <out.icns>` | 生成应用图标（`make app` 自动调用）。图标用代码绘制，仓库不存图片，改设计就改这个脚本 |
| `make dmg` | 发布用 dmg：通用二进制 + 临时签名（未公证，Gatekeeper 会拦，README 写了放行步骤）。版本号取最近的 git tag。推送 `v*` 标签时 `.github/workflows/release.yml` 自动打包并发 Release |
| `make lint` | 泄露检查（`scripts/check-leaks.sh`）：gitleaks 查密钥 + `.git/info/leak-denylist` 个人信息黑名单 + 禁止的文件类型。`make hooks` 后每次提交自动执行；CI 只查密钥 |
| `PROMPTDOCK_LIVE_OLLAMA_MODEL=<模型> swift test --filter LiveOllama` | 真实调用本机 Ollama 的集成测试（默认跳过） |

## 结构

| 目标 | 职责 |
|---|---|
| `PromptDockCore` | 纯逻辑：YAML 解析与写回、匹配排序、frecency、请求构造、SSE 解析、占位符。**新逻辑优先放这里并先写测试** |
| `PromptDock` | AppKit/SwiftUI 外壳：菜单栏、快捷键、面板、设置窗口、粘贴、钥匙串。没有单元测试，靠真实环境验证 |

运行时数据都不在仓库里：配置 `~/.config/promptdock/prompts.yaml`，使用记录 `~/Library/Application Support/PromptDock/usage.sqlite`，日志 `~/Library/Logs/PromptDock/app.log`，API Key 存在钥匙串（service `local.jemry.promptdock`）。

## 踩过的坑（改相关代码前必读）

| 坑 | 规则 |
|---|---|
| 自签名证书没有 Team ID，每次重新编译后钥匙串都把新版本当成另一个程序，读取 Key 时会弹授权框 | 菜单、面板、设置窗口只能用 `KeychainStore.hasAPIKey`（只查是否存在，不弹框）；`readAPIKey` 只在真正发请求时调用。菜单展开时弹出的授权框无法输入密码 |
| 辅助功能（TCC）授权跟着证书走 | 必须用 `make install` 签名，否则每次编译都要重新授权 |
| accessory 应用默认没有编辑菜单，输入框里 ⌘V/⌘C/⌘A 不生效 | `MainMenu.install()` 不能删 |
| `Settings` 和 SwiftUI 的同名类型冲突；`PromptDockCore` 模块里又有一个同名枚举，没法用模块名限定 | 导入了 SwiftUI 的文件里改用 `AppSettings` 别名 |
| 写回 YAML 会丢注释 | 一律走 `ConfigWriter.update(from:to:)`：只重写有变化的顶层段，写前重新解析做自检，并检测外部修改冲突；写入前备份成 `.bak`；配置文件是软链接时写到链接指向的真实文件 |
| Yams 序列化：列表项顶格；`|+` 结尾会附加 `...`；末尾多个换行用 `|+` 会吞掉段与段之间的空行 | 这些在 `ConfigWriter.serialize` 里都已处理，改动时跑 `ConfigWriterTests` 的往返用例 |
| NSHostingView 把透明标题栏算作安全区，顶部会露出一条白边 | 面板设置了 `safeAreaRegions = []` |
| 终端没有辅助功能权限，没法模拟点击或按键 | 用 URL scheme 打开界面后截图验证：`open "promptdock://panel"`、`open "promptdock://actions"`（动作面板，会先读前台应用选区）、`open "promptdock://settings?tab=general|providers|prompts"`，再用 `CGWindowListCopyWindowInfo` 找窗口号，`screencapture -l <id>` 截图 |
| Ollama 的 OpenAI 兼容接口里 `think: false` 不生效 | 关闭思考要用 `extra_body: {reasoning_effort: none}`；DeepSeek 用 `{thinking: {type: disabled}}` |

## 约定

- 流程：先写 spec，再 TDD，然后在真实环境验证并截图，用户实测通过后用 `--no-ff` 合并。一个功能一个分支（`feat/*`）。
- 这是公开仓库。提交被泄露检查拦下时先确认内容，不要随手 `--no-verify`；需要新增个人敏感词就写进 `.git/info/leak-denylist`，不要写进任何被跟踪的文件。
- 截图里可能有用户的工作内容，只放在临时目录，不进仓库。唯一例外是 README 用的 `docs/screenshots/*.png`（泄露检查已放行）：截取前先备份用户配置、换成 `Resources/prompts.example.yaml`，截完恢复并核对校验和。用户自己的提示词也不进仓库，`Resources/prompts.example.yaml` 只放通用示例。
- 日志不记录选中文本、模型输出和 Key，只记字数、耗时、stop_reason。
- 改用户的 `~/.config/promptdock/prompts.yaml` 之前，先备份。
