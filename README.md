# PromptDock

macOS 菜单栏提示词管理器。在任何输入框里按 **⌥Space** 呼出面板，搜索提示词后回车，内容直接粘贴到原来的位置；选中一段文字按 **⌥⇧Space**，可以用预设的提示词调用大模型改写，结果替换原文。

<p align="center"><img src="docs/screenshots/prompt-panel.png" width="720" alt="提示词面板：左侧搜索结果，右侧预览内容"></p>

- **快速查找**：模糊搜索标题、关键词、标签和内容，中文标题还支持拼音与首字母（`pcwt` → 排查问题），按使用频率和最近使用时间自动排序
- **面板内维护**：⌥Space 面板底栏 ⊕ 新增、条目右键编辑/删除，保存即写入 YAML 生效，不用打开配置文件
- **✨ 一键生成**：关键词可由大模型从内容自动提炼；任意条目可对剪贴板文本直接执行，结果在面板内流式显示
- **占位符**：提示词里写 `{{天数}}`，粘贴后光标自动停在这里并选中，直接输入即可替换
- **选中文字动作**：润色、翻译、精简……流式显示结果，回车替换原文，⌘↩ 复制；生成中/完成后均可 ← 返回动作列表，换动作对同段文字重跑
- **朗读**：动作面板可朗读选中的原文，结果页可朗读模型输出，遇到不认识的名词先听发音再让模型解释；短英文自动标注模型给的 IPA 音标与中文释义，喇叭固定在右端，读完自动回弹、按句停顿
- **收藏词汇**：结果页 ⭐ 一键归档到 Markdown 词汇表，解释先经模型提炼成精简要点，自动去重。默认写到 Obsidian 当前仓库的「词汇表」目录，没装 Obsidian 则写到 `~/Documents/PromptDock/词汇表`；目录和拆分方式（不拆分 / 按月 / 按天）可在设置 → 通用里改
- **多模型**：同时支持 Anthropic 和 OpenAI 兼容协议（DeepSeek、Ollama 本地模型等），每个动作可以指定不同的服务和模型
- **调用历史**：`keep_history: true` 开启后记录每次动作的输入与输出（本地 SQLite，最近 200 条），菜单栏随时回看复制
- **主题配色**：低饱和深松绿主题色贯穿面板、设置与历史窗口；面板固定浅色毛玻璃（深色壁纸下也干净），选中行淡绿底 + 内描边 + 左侧指示条，悬停为中性浅底
- **纯文本配置**：所有提示词和设置都在一个 YAML 文件里，保存后自动生效，方便用 git 管理；也可以在设置窗口里编辑
- API Key 存在系统钥匙串，不写入配置文件和日志

### 设置窗口

| 通用 | 模型服务 | 提示词 |
|---|---|---|
| <img src="docs/screenshots/settings-general.png" alt="通用设置：快捷键、粘贴、模型、网络"> | <img src="docs/screenshots/settings-providers.png" alt="模型服务：协议、地址、模型、API Key"> | <img src="docs/screenshots/settings-prompts.png" alt="提示词编辑：标题、类型、关键词、内容"> |

## 下载安装

需要 macOS 15 及以上，Apple 芯片与 Intel 均可。

1. 从 [Releases](https://github.com/jemry/promptdock/releases/latest) 下载 `PromptDock-x.y.z.dmg`，打开后把 PromptDock 拖进「应用程序」
2. **首次打开**：本应用未经 Apple 公证（需要付费开发者账号），双击会提示「无法验证开发者」。任选一种方式放行：
   - 系统设置 → 隐私与安全性 → 页面底部找到 PromptDock → 点「仍要打开」
   - 或在终端执行：`xattr -dr com.apple.quarantine /Applications/PromptDock.app`
3. 按提示授予「辅助功能」权限，粘贴和读取选中文字都依赖它
4. 按 ⌥Space 试试；使用选中文字动作前，在菜单栏 → 设置… → 模型服务 中填入 API Key

**升级提示**：每个版本的签名都不同，升级后需要重新授予辅助功能权限。在系统设置 → 隐私与安全性 → 辅助功能 中删除旧的 PromptDock，再重新添加。

## 从源码编译

需要 Swift 6 工具链（安装 Xcode 或 Command Line Tools）。

### 1. 创建签名证书（只需一次）

macOS 的辅助功能授权和应用签名绑定。用固定的自签名证书签名，重新编译后授权不会失效。

1. 打开「钥匙串访问」→ 菜单「钥匙串访问 → 证书助理 → 创建证书…」
2. 名称填 `PromptDock Dev`，身份类型选「自签名根证书」，证书类型选「代码签名」
3. 终端执行 `security find-identity -p codesigning`（不要加 `-v`），能看到 `"PromptDock Dev" (CSSMERR_TP_NOT_TRUSTED)` 即可。「不受信任」是正常的，不影响本地使用

不想建证书也可以用临时签名：`make install SIGN_ID=-`。代价是每次重新编译后都要重新授权辅助功能。

### 2. 编译安装

```sh
git clone https://github.com/jemry/promptdock.git
cd promptdock
make install      # 编译、签名，安装到 ~/Applications 并启动
```

首次启动后：

1. 系统会提示授予「辅助功能」权限（系统设置 → 隐私与安全性 → 辅助功能），粘贴和读取选中文字都依赖它
2. 菜单栏出现图标，按 ⌥Space 试试
3. 菜单栏 → 设置… → 模型服务，填入 API Key（使用选中文字动作才需要）

## 使用

| 操作 | 说明 |
|---|---|
| ⌥Space | 提示词面板：输入关键词搜索（中文标题支持拼音/首字母），↑↓ 选择，↩ 粘贴，⌘↩ 复制，数字 1-9 直选、0 选第 10 条，双击条目直接粘贴，Esc 关闭 |
| ⌥⇧Space | 动作面板：先选中文字再按。选择动作后回车开始生成，完成后 ↩ 替换原文，⌘↩ 复制；读不到选区时可直接在输入框输入要处理的内容 |
| 底栏 ⊕ / 条目右键 | 新增提示词（名称、关键词、内容，⌘↩ 保存）；右键菜单可编辑、删除该条 |
| 关键词旁 ✨ | 表单里用默认模型从「内容」提炼搜索关键词 |
| 条目 ✨ | 剪贴板文本 + 该条提示词直接发给模型，面板内流式显示，↩ 复制；发送前提示条显示剪贴板前 40 字供核对，剪贴板没有文本时按钮置灰（悬停有提示） |
| ← | 生成中/完成后返回列表：取消请求、保留选区，换动作对同段文字重跑；在输入框中照常移动光标 |
| 🔊 | 朗读选中原文（动作面板）或模型输出（结果页），再点 ⏹ 停止；关面板自动停。短英文朗读时左侧标注模型给的 IPA 音标 + 简要中文释义 |
| ⭐ | 结果页收藏到词汇表：解释先经模型提炼成精简要点再写入，默认每月一个文件、按天分组、文件内去重，最新在最上；提示条显示写入路径 |
| 菜单栏 → 设置… | 编辑通用设置、模型服务和提示词 |
| 菜单栏 → 调用历史… | 回看最近 200 条动作的输入与输出（需在配置里开启 keep_history），可复制、清空 |
| 菜单栏 → 默认服务 | 快速切换默认使用的模型服务 |
| `open promptdock://panel` | 从脚本或其他工具呼出面板 |

## 配置

配置文件位于 `~/.config/promptdock/prompts.yaml`，首次启动时自动生成示例（见 [`Resources/prompts.example.yaml`](Resources/prompts.example.yaml)）。可以手工编辑，也可以把它换成软链接，指向你自己的 git 仓库。

```yaml
version: 1

settings:
  llm:
    provider: deepseek            # 默认服务
  keep_history: true              # 可选：记录调用历史（输入与输出全文，本地保存最近 200 条）
  vocabulary:                     # 可选：⭐ 词汇表，也可在设置 → 通用里改
    dir: ~/Notes/词汇表            # 留空自动：Obsidian 当前仓库/词汇表，没有则 ~/Documents/PromptDock/词汇表
    split: month                  # none 不拆分 / month 按月（默认）/ day 按天
  providers:
    deepseek:
      protocol: openai            # openai 或 anthropic
      base_url: https://api.deepseek.com
      model: deepseek-flash
    ollama:                       # 本地模型，无需 Key
      protocol: openai
      base_url: http://localhost:11434/v1
      model: qwen3

prompts:
  # 提示词：⌥Space 选中后粘贴
  - id: slow-pr
    title: 慢 PR 分析
    keywords: [pr, 性能]
    content: |
      分析最近 {{7}} 天里最慢的 PR，找出可以优化的地方。

  # 动作：⌥⇧Space 处理选中文字，{selection} 替换为选中内容
  - id: to-english
    title: 翻译成英文
    type: action
    keywords: [fy, translate]
    provider: ollama              # 可选，不写则用默认服务
    output: replace               # replace 替换原文 / copy 复制 / show 只显示
    content: |
      把下面的文字翻译成自然的英文：
      {selection}
```

完整字段说明见 [`docs/spec.md`](docs/spec.md)。

## 权限与隐私

- **辅助功能权限**：用于模拟 ⌘V 粘贴、读取选中文字（必要时模拟 ⌘C）、粘贴后移动光标
- **网络**：只在执行动作时，把选中文字和提示词发送给你配置的模型服务；粘贴提示词不联网
- **API Key**：存在系统钥匙串；地址是明文 http 且不是本机时拒绝发送 Key
- **剪贴板**：粘贴时临时借用剪贴板，并标记为临时内容（剪贴板历史工具会跳过），完成后恢复原内容
- **本地数据**：使用记录存在 `~/Library/Application Support/PromptDock/usage.sqlite`（只记录条目 id、时间和粘贴/复制方式，保留 180 天），日志在 `~/Library/Logs/PromptDock/app.log`（不记录文字内容和 Key）。调用历史默认关闭，`keep_history: true` 开启后存在 `history.sqlite`（记录动作的输入与输出全文，最近 200 条，仅本机）

## 已知限制

- 密码框等安全输入状态下，系统会拦截快捷键和模拟粘贴
- 占位符定位靠模拟方向键：粘贴时会自动缩进的编辑器、会吞掉换行的单行输入框里，光标位置可能有偏差
- 部分应用不支持读取选中文字的辅助功能接口，此时会模拟 ⌘C 读取；VS Code 等编辑器在未选中文字时 ⌘C 会复制整行

## 开发

```sh
make test         # 单元测试
make install      # 编译并重新安装
make hooks        # 启用提交前泄露检查（每个 clone 执行一次，需要 brew install gitleaks）
make dmg          # 打包发布用的 dmg（通用二进制、临时签名）
make lint         # 手动执行泄露检查：密钥、个人信息黑名单、禁止提交的文件类型
```

发布新版本：`git tag v0.2.0 && git push origin v0.2.0`，GitHub Actions 会自动编译、打包 dmg 并创建 Release。

个人信息黑名单写在 `.git/info/leak-denylist`（每行一个正则，不会被提交）。GitHub Actions 在每次推送时用 gitleaks 检查密钥。

`PromptDockCore` 是纯逻辑层（解析、排序、请求构造等），都有单元测试；`PromptDock` 是 AppKit/SwiftUI 界面层。设计文档在 [`docs/spec.md`](docs/spec.md)。

## 许可证

[MIT](LICENSE)
