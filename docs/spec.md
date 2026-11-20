# PromptDock 设计方案

> 版本：v0.1（2026-11-16）
> 状态：已确认，待实现
> 说明：本文档自包含，不依赖任何历史会话上下文，可直接交给新的 session 实现。

## 1. 背景与目标

在 macOS 上统一维护个人常用提示词（prompt），并能在任意应用的输入框中快速调用。

现有工具的不足：

| 工具 | 不足 |
|---|---|
| 剪贴板历史工具 | 需要手动翻找，不按使用情况排序 |
| Raycast 免费版 | Snippets 可用，但 AI 功能需付费订阅，且选中文本会经过 Raycast 服务器，工作内容存在合规风险 |

目标：

1. 提示词集中维护在一个 YAML 文件中，可纳入 git 版本管理。
2. 全局快捷键呼出搜索面板，支持模糊搜索，按使用频率与最近使用时间（frecency）排序，回车后粘贴到原输入框。
3. 对选中文本应用预设提示词调用大模型，本机直连模型 API，不经过第三方中转。
4. 架构便于持续扩展，新增能力优先通过配置与外部脚本完成，尽量不改代码。

非目标（本期不做）：多设备同步、团队共享、图形化提示词编辑器、Windows/Linux 支持。

## 2. 名词说明

| 名词 | 含义 |
|---|---|
| Prompt 面板 | 快捷键 A 呼出的浮动搜索窗口，用于检索并粘贴提示词 |
| 动作面板 | 快捷键 B 呼出的窗口，用于对选中文本执行预设动作 |
| snippet | 一类提示词条目：选中后直接粘贴内容 |
| action | 一类提示词条目：与选中文本组合后发送给模型，返回结果 |
| frecency | frequency + recency，综合使用次数与最近使用时间的排序分 |
| 辅助功能权限 | macOS「系统设置 → 隐私与安全性 → 辅助功能」授权，模拟按键、读取其他应用选区都依赖此权限 |

## 3. 分期范围

| 期 | 范围 | 验收标准 |
|---|---|---|
| **P0** | 菜单栏常驻、Prompt 面板、模糊搜索、frecency 排序、粘贴回原输入框、YAML 热重载 | 在微信、Chrome、VS Code、终端（Terminal/iTerm）四类应用中均能呼出面板、检索并成功粘贴 |
| **P1** | 动作面板、读取选中文本、调用 Claude、流式输出、替换原文或复制 | 同上四类应用中能读取选区并完成替换 |
| P2 | 模板变量、脚本动作、多模型提供方、调用历史、拼音检索 | 另行确认 |

**本次只实现 P0。** P1/P2 的设计在第 9、10 节给出，用于约束 P0 的数据结构，避免返工。

## 4. 技术选型

| 项 | 选择 | 理由 |
|---|---|---|
| 语言 | Swift 6 | 本机已有 Xcode 27.2 / Swift 6.4 |
| UI | SwiftUI + AppKit（`NSPanel`） | 浮动面板、焦点控制需要 AppKit |
| 最低系统 | macOS 15 | 个人使用，无需兼容旧版本 |
| 构建 | Swift Package Manager + `Makefile` 组装 `.app` | 纯命令行可构建，不依赖 Xcode 工程文件 |
| 全局快捷键 | Carbon `RegisterEventHotKey` | 系统自带，无第三方依赖 |
| YAML 解析 | [Yams](https://github.com/jpsim/Yams) | 唯一第三方依赖 |
| 使用统计存储 | 系统自带 SQLite（`import SQLite3`） | 无额外依赖，P1 调用历史可复用 |
| 密钥存储（P1） | 系统钥匙串（Keychain） | 不落明文 |
| 开机自启 | `SMAppService.mainApp` | 系统标准方式 |

## 5. 总体架构

```
PromptDock.app（菜单栏常驻，Info.plist 设置 LSUIElement = YES，不出现在 Dock）
│
├── HotkeyManager        注册全局快捷键，分发到对应面板
├── PanelController      管理浮动面板的显示、隐藏与焦点还原
│   ├── PromptPanelView  （P0）搜索框 + 结果列表 + 内容预览
│   └── ActionPanelView  （P1）动作列表 + 流式结果区
├── PromptStore          读取 prompts.yaml，监听文件变化并热重载
├── UsageStore           SQLite 记录使用事件，计算 frecency
├── Matcher              模糊匹配与综合排序（纯函数，便于单测）
├── PasteService         剪贴板备份/写入/恢复，模拟 ⌘V
├── SelectionService     （P1）读取选中文本
└── LLMProvider          （P1）模型调用抽象，首个实现为 AnthropicProvider
```

## 6. 数据设计

### 6.1 文件位置

| 文件 | 默认路径 | 说明 |
|---|---|---|
| 提示词库 | `~/.config/promptdock/prompts.yaml` | 用户手工维护；可改为软链接指向 git 仓库中的文件 |
| 使用统计 | `~/Library/Application Support/PromptDock/usage.sqlite` | 程序维护，用户无需关心 |
| 应用日志 | `~/Library/Logs/PromptDock/app.log` | 排障用 |

首次启动若 `prompts.yaml` 不存在，自动生成一份带注释的示例文件。

### 6.2 prompts.yaml 结构

```yaml
version: 1

settings:
  hotkeys:
    prompt_panel: "option+space"
    action_panel: "option+shift+space"   # P1 启用
  paste:
    restore_clipboard: true              # 粘贴后恢复原剪贴板内容
    restore_delay_ms: 500

prompts:
  - id: code-review                      # 必填，唯一且稳定；使用统计按 id 关联，改名不丢历史
    title: 代码审查                       # 必填，面板中显示的名称
    type: snippet                        # snippet | action（P1）| script（P2）
    keywords: [review, cr, 审查]          # 可选，参与搜索
    tags: [dev]                          # 可选，P0 仅参与搜索，不做分组
    content: |                           # snippet 必填
      请从正确性、可读性、性能三个方面审查以下代码……

  - id: polish-zh
    title: 中文润色
    type: action                         # P0 解析并展示，但选中后提示「P1 支持」
    keywords: [润色, polish]
    model: claude-sonnet-5-5             # P1 字段，可选，缺省用全局默认
    system: 你是一名中文技术编辑。          # P1 字段，可选
    content: |
      润色下面这段文字，保持原意，书面、克制：
      {selection}
    output: replace                      # P1 字段：replace | copy | show
```

解析规则：

1. `id` 重复、缺少必填字段时，跳过该条并记录警告，不影响其他条目。
2. 未知的 `type` 或未知字段一律忽略并记录警告，以保证向后兼容。
3. 整个文件解析失败时，保留上一次加载成功的数据，菜单栏图标显示警告状态，菜单中给出错误行号。

### 6.3 usage.sqlite 结构

```sql
CREATE TABLE usage_event (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  prompt_id TEXT    NOT NULL,
  used_at   INTEGER NOT NULL,          -- Unix 时间戳（秒）
  kind      TEXT    NOT NULL           -- paste | copy | action（P1）
);
CREATE INDEX idx_usage_prompt ON usage_event(prompt_id, used_at);
```

启动时清理 180 天前的事件。

## 7. 核心算法

### 7.1 frecency

```
frecency(p) = Σ 0.5 ^ (距今天数 / 半衰期)     对 p 的每一次使用事件求和
半衰期 = 7 天
```

含义：今天用一次记 1 分，7 天前用的一次记 0.5 分，14 天前的记 0.25 分。经常用、最近用的条目排在前面。

### 7.2 模糊匹配

对查询串 `q`（转小写、去首尾空格）与条目各字段做子序列匹配，取各字段得分的最大值：

| 字段 | 权重 |
|---|---|
| title | 1.0 |
| keywords | 0.9 |
| tags | 0.6 |
| content | 0.3 |
| title 拼音全拼 | 0.85 |
| title 拼音首字母 | 0.8 |

单字段得分规则（0~1）：完全相等 = 1.0；前缀匹配 = 0.9；包含连续子串 = 0.75；子序列匹配 = 0.5 × 紧凑度（匹配跨度越短越高）；不匹配 = 0。

**拼音检索（2026-11-17）**：含汉字的 title 用系统 Latin 转换（`applyingTransform(.toLatin)` + 去声调）生成全拼与首字母索引（`Pinyin.index`，零依赖零数据表）：「排查问题」→ `paichawenti` / `pcwt`，英文数字片段混入（「GPT-4o 测试」→ `gpt4oceshi` / `g4cs`）。权重低于关键词档：直接打中文标题的命中排在拼音命中之前。拼音档只认相等、前缀、连续子串，不走子序列（纯字母串上 `ui`、`ai` 这类短查询按子序列几乎处处命中）；索引按标题缓存。

### 7.3 综合排序

```
查询为空：按 frecency 降序；frecency 相同按 title 升序
查询非空：score = match_score + 0.3 × (frecency / 当前结果集中最大 frecency)
         过滤掉 match_score = 0 的条目，按 score 降序
```

`Matcher` 实现为纯函数（输入：条目列表、使用统计、查询串、当前时间；输出：排序结果），时间作为参数传入，便于单测。

## 8. P0 交互与流程

### 8.1 Prompt 面板

| 操作 | 行为 |
|---|---|
| ⌥Space | 呼出面板；再按一次关闭 |
| 输入 | 实时过滤排序 |
| ↑ / ↓ | 移动选中项 |
| Enter | 粘贴到原输入框，记录 `paste` 事件 |
| ⌘Enter | 只复制到剪贴板，不粘贴，记录 `copy` 事件 |
| Esc / 失去焦点 | 关闭面板，焦点回到原应用 |
| 数字 1-9、0 | 列表前 10 条直选并触发（0 = 第 10 条，角标同显）；仅搜索框为空时生效，输入中数字放行给输入框；动作面板的无选区输入回退模式下不生效（输入框承载待处理内容，首字符可能是数字）（2026-11-17） |
| ⌃, / ⌘, | 关闭面板并打开设置窗口；提示词面板与动作面板都生效，新增/编辑表单中不生效（避免丢失未保存内容），输入法组字时不生效（2026-11-20） |
| 底栏 + 按钮 | 主区域切换为「新增提示词」表单（2026-11-17） |
| 列表项 ✨ 按钮 | 关键词旁的 ✨（仅提示词面板）：剪贴板文本 + 该提示词直接发给模型，面板内流式显示结果（show 语义）。发送前按 8.6 去掉 `{{占位符}}` 的花括号，剪贴板文本替换 `{selection}` 或追加在末尾。执行时提示条显示剪贴板前 40 字供核对（盲发防错，复制失败/残留旧内容一眼可辨；notice 保持到返回列表）。生成中 ↩ 无效；完成后 ↩/⌘↩ 复制；失败后 ↩ 重试（重新读取剪贴板）；请求发出前失败（缺 Key 等）同样显示在结果区。剪贴板无文本时提示（2026-11-17） |
| 列表项右键 | 仅提示词面板。「编辑…」：表单回填该条，保存只改 title/keywords/content，id 与其余字段不动，改名不影响使用统计；保存时若磁盘上该条已与打开表单时不同（外部修改），拒绝保存并提示。「删除…」：面板顶部出现确认条，确认后写盘（写前备份 .bak）。不用弹窗确认，因为弹窗会让面板失焦关闭（2026-11-17） |

布局：顶部搜索框；下方左侧为结果列表（显示 title 与 keywords），右侧为选中项的内容预览。窗口居中偏上，宽约 720pt、高约 420pt，浅色主题跟随系统外观。

新增表单：字段为名称（必填）、关键词（可选，逗号或空格分隔，标签旁 ✨ 按钮可调默认模型从内容自动提炼）、内容（必填）；默认新增 `type: snippet` 条目。⌘Enter 保存（名称或内容为空时禁用），Esc 取消返回列表。id 由 title 的英文字母与数字生成 kebab-case，无可用字符时用 `prompt`，与现有 id 冲突时追加序号（`Prompt.uniqueID`）。保存走 `ConfigWriter.update(from:to:)` 统一写回通道（保注释、防冲突、写前备份），base 以磁盘当前内容为准——追加语义不以内存 state 为基准，避免热加载窗口期内 state 落后于磁盘被冲突检测误拒（2026-11-17 实测踩坑）；写入成功后由热加载刷新面板列表，新条目立即出现。表单模式下回车、↑↓ 不触发面板命令路由，只有 Esc 被拦截用于取消表单。

### 8.2 粘贴流程

```
1. 呼出面板前记录当前前台应用（NSWorkspace.shared.frontmostApplication）
2. 面板使用 NSPanel + .nonactivatingPanel 样式：可以接收键盘输入，但不抢占原应用的激活状态
3. 用户按 Enter：
   a. 备份剪贴板全部内容（所有 pasteboardItems 的所有类型）
   b. 写入提示词内容
   c. 关闭面板，激活第 1 步记录的应用
   d. 等待约 80ms 后，用 CGEvent 发送 ⌘V
   e. 等待 restore_delay_ms 后恢复剪贴板（仅当剪贴板 changeCount 未被其他程序改动时）
```

### 8.3 菜单栏

| 菜单项 | 行为 |
|---|---|
| 打开 Prompt 面板 | 同快捷键 |
| 编辑提示词… | 用默认编辑器打开 `prompts.yaml` |
| 重新加载 | 手动重载（正常情况下热重载已覆盖） |
| 打开数据目录 | 在 Finder 中显示 |
| 开机自启 | 勾选开关 |
| 配置错误：第 N 行 … | 仅在解析失败时出现 |
| 退出 | — |

### 8.4 热重载

监听 `prompts.yaml` 所在目录（而不是单个文件），因为很多编辑器保存时采用「写临时文件再重命名」的方式，只监听文件会丢失事件。变化后防抖 300ms 再重新解析。

### 8.5 权限

启动时调用 `AXIsProcessTrustedWithOptions` 检查辅助功能权限。未授权时弹出引导窗口，说明用途并提供「打开系统设置」按钮。未授权时面板仍可使用，但 Enter 自动降级为「仅复制」，并给出提示。

### 8.6 占位符（2026-11-17）

提示词内容里写 `{{说明}}`，粘贴时去掉花括号；粘贴后光标移到第一个占位符并选中其中文字，直接输入即可替换。

| 规则 | 说明 |
|---|---|
| `{{XX}}` | 粘贴为 `XX` 并选中 |
| `{{}}` | 只定位光标，不选中 |
| 多个占位符 | 只定位第一个，其余只去掉花括号 |
| 内含换行或花括号 | 不视为占位符，原样粘贴（避免误伤代码里的 `{{ }}`） |
| 末尾换行 | 有占位符时去掉（单行输入框会吞掉换行，导致位置偏一位） |
| ⌘↩ 复制 | 复制去掉花括号后的文本，不定位 |

实现：粘贴后等 80ms，模拟 ← 键 N 次（N = 占位符后的字符数），再 ⇧← 选中占位符。字符数超过 3000 时不定位。

已知限制（推断，待实测）：粘贴时会自动缩进或改写文本的编辑器（如部分代码编辑器）、会吞掉中间换行的单行输入框，光标位置可能偏移。

## 9. P1 设计（已实现，2026-11-16）

### 9.1 面板分工

| 快捷键 | 面板 | 列出的条目 |
|---|---|---|
| ⌥Space | Prompt 面板 | 仅 `type: snippet` |
| ⌥⇧Space | 动作面板 | 仅 `type: action` |

动作面板流程：读取选区（此时焦点仍在原应用）→ 显示面板，顶部显示「选中 N 字」与摘要，尾部 🔊 按钮可朗读选区原文 → 选择动作回车 → 流式显示结果 → 按 output 处理。

**无选区输入回退（2026-11-17）**：读不到选区（未选中/应用不支持）时面板仍可打开，进入输入模式：搜索框 placeholder 变为「输入要处理的内容…」，输入的文字即待处理文本（`selectionText` 回退到 query），列表**不过滤**保持全量（输入的是问题不是搜索词），回车把输入文本当作选区执行——朗读、音标、⭐ 收藏全链路同样可用。顶部栏显示「输入 N 字」。

| 阶段 | ↩ | ⌘↩ | Esc / 点击外部 |
|---|---|---|---|
| 选择 | 执行 | 执行 | 关闭 |
| 生成中 | — | — | 取消请求并关闭 |
| 完成 | replace：替换原文；show：复制 | 复制 | 关闭 |
| 失败 | 重试 | — | 关闭 |

### 9.2 读取选中文本

```
1. 优先：辅助功能接口读取焦点元素的 AXSelectedText
2. 降级：备份剪贴板 → 发送 ⌘C → 轮询 changeCount（最多 300ms）→ 读取 → 恢复剪贴板
   （部分 Electron 应用，如 VS Code、飞书，第 1 步取不到选区）
3. 两步都失败：进入无选区输入回退模式（见 9.4）
```

**误判过滤（2026-11-20，`SelectionFilter`，Core 带测试）**：有些应用没有选区时按 ⌘C 也会往剪贴板放内容，降级路径会把它当成选区，面板进入「搜索动作」而不是「输入内容」。实测日志：VS Code 空行读到 1 字（整行复制），iTerm 读到 103916 字。过滤规则：

| 规则 | 依据 |
|---|---|
| 去掉空白后为空 → 视为无选区 | VS Code 在空行上复制整行，只得到换行符 |
| iTerm：不加规则 | 实验（2026-11-20）：无选区时 ⌘C 不复制任何内容；之前读到的 103916 字推断是未注意到的旧选区（iTerm 切换应用后选区仍保留），属于真实选区，靠界面 ✕ 纠正 |
| VS Code 非空行整行复制：不加规则 | 实验（2026-11-20）：剪贴板只有 `public.utf8-plain-text`，没有 `vscode-editor-data` 等可识别的标记，与真选中一整行无法区分；按行尾换行判断会误伤三击选中的整行。靠界面「来自 {应用}」+ ✕ 纠正 |

**误判兜底（界面）**：过滤不可能覆盖所有应用，所以动作面板必须能一键纠正、且两种模式一眼可辨：

| 模式 | 顶部栏 |
|---|---|
| 读到选区 | 「选中 N 字 · 来自 {应用名}」+ 摘要 + 🔊 + **✕**。点 ✕ 丢弃选区，清空输入框，切到输入模式，焦点回输入框 |
| 输入模式 | 主题绿突出显示「直接输入要处理的内容」+「输入 N 字」+ 🔊；输入框 placeholder 同步说明 |

### 9.3 模型服务（providers）

支持两种协议，服务在 `settings.providers` 中按名字配置，数量不限：

```yaml
settings:
  llm:
    provider: claude        # 默认服务
    effort: medium          # 仅对 Anthropic 官方接口生效
  providers:
    claude:   { protocol: anthropic, base_url: https://api.anthropic.com,   model: claude-opus-5-5 }
    deepseek: { protocol: openai,    base_url: https://api.deepseek.com,    model: deepseek-flash,
                extra_body: { thinking: { type: disabled } } }
    ollama:   { protocol: openai,    base_url: http://localhost:11434/v1,   model: qwen3.8:27b-mlx,
                extra_body: { reasoning_effort: none } }
```

| 字段 | 必填 | 说明 |
|---|---|---|
| protocol | 是 | `anthropic` 或 `openai` |
| base_url | 是 | anthropic 协议不带 `/v1`（拼接 `/v1/messages`）；openai 协议照抄服务商文档（拼接 `/chat/completions`） |
| model | 是 | 该服务的默认模型 |
| max_tokens | 否 | anthropic 协议默认 64000；openai 协议默认不传 |
| effort | 否 | 覆盖 `llm.effort`；第三方 anthropic 兼容接口只有显式配置时才发送 |
| extra_body | 否 | 合并进请求体的任意字段，同名时覆盖默认值 |

未配置 `providers` 时内置一个名为 `anthropic` 的官方服务。单条 action 可用 `provider`、`model` 覆盖。`settings.llm.model` 已废弃，写了会给出警告并忽略。

| 项 | anthropic 协议 | openai 协议 |
|---|---|---|
| 鉴权 | `x-api-key`，必须有 Key | `Authorization: Bearer`；未设置 Key 时不带鉴权头（本地 Ollama） |
| 官方专属参数 | 仅 `api.anthropic.com`：`anthropic-beta: server-side-fallback-2026-07-01` + `fallbacks: "default"` + `output_config.effort` | — |
| API 版本 | `anthropic-version: 2026-10-21`（不接受 temperature 等采样参数，因此不传） | — |
| 思考内容 | `thinking` 块 | `delta.reasoning_content`（DeepSeek）或 `delta.reasoning`（Ollama） |
| 结束原因 | `stop_reason` 原样使用 | `finish_reason` 映射：stop → end_turn，length → max_tokens，content_filter → refusal |

思考内容只用于在面板上显示「思考中…」，不进入结果。最终 `stop_reason` 为 refusal 时判定失败，不允许替换。

API Key 按服务存在系统钥匙串（service `local.jemry.promptdock`，account `api-key:<服务名>`），在菜单栏「API Key」子菜单中设置，不写入 YAML 与日志。记录位于传统登录钥匙串，`kSecAttrAccessible` 在其中不生效；改用数据保护钥匙串需要开发者 Team ID，自签名证书做不到。地址为明文 http 且主机不是本机回环地址（localhost、127.*、::1）时，带 Key 的请求直接拒绝，不带 Key 的（如局域网 Ollama）照常发送。代理默认跟随系统代理；`settings.network.proxy` 显式指定时，本机地址（localhost、127.0.0.1、*.local）不走代理。

实测记录（2026-11-16，本机 Ollama 0.32.14，qwen3.8:27b-mlx，翻译一句短中文）：

| 参数 | 首字/总耗时 | 是否思考 |
|---|---|---|
| 默认 | 24.7s | 是 |
| `think: false` | 6.2s | 是（Ollama 原生接口参数，OpenAI 兼容接口不生效） |
| `reasoning_effort: none` | 0.9s | 否 |

提示词组装：

- `{selection}` 一次性替换为选中文本（选中文本里的 `{selection}` 不会被再次展开）；`content` 中没有占位符时，把选中文本追加到末尾。
- `output` 为 replace / copy 时，在 system 末尾追加「只输出处理后的文本本身，不要解释、前言或代码块包裹」，保证结果可以直接替换原文。

### 9.4 结果处理

| output | 行为 |
|---|---|
| replace（默认） | 完成后按 ↩ 替换原选区（复用粘贴流程） |
| copy | 完成后自动复制到剪贴板 |
| show | 只在面板中显示，↩ 复制 |

结果首尾空白会被去掉。日志只记录字数、耗时、首字延迟和 stop_reason，不记录选中文本和模型输出。

动作执行的所有阶段（生成中、完成、失败）底栏右侧均提供返回箭头，点击回到动作选择列表：面板不关闭，生成中会先取消请求，然后清空本次输出与提示，焦点回到搜索框，选区文字保留，可换一个动作对同一段文字重跑。键盘 ← 等价于点击返回箭头（2026-11-17）；← 在表单、搜索框等输入场景放行给输入控件，仅动作结果阶段生效。

**朗读（2026-11-17）**：动作面板选择阶段可在「选中 N 字」尾部点 🔊 朗读选区原文，结果页（含 ⌥Space 面板 ✨ 跑模型的结果）底栏可点 🔊 朗读模型输出。朗读中按钮变为 ⏹，再点即停；两处按钮共享同一朗读状态，任意一处均可停止当前朗读。用系统 `AVSpeechSynthesizer` 实现，无新配置：文本含 CJK 字符选 zh-CN 声音、否则 en-US；声音按「音质最高 → 平级优先女声 → 名字序」选择（用户从系统设置下载高级/增强声音后自动升级）；语速为默认的 0.9 倍、音调 1.05，偏柔和。面板关闭（Esc、点击外部）或返回列表时自动停止朗读，不让声音悬空播放。典型用法：遇到不认识的 AI 名词或英文单词，点 🔊 听原文发音，同时回车执行「解释」类动作对照阅读。

**朗读音标（2026-11-17）**：开始朗读时若文本是短英文（≤4 个词、不含 CJK，`SpeechPhonetics.shouldLookup`），异步调默认模型要美式 IPA 与简要中文释义（≤12 字），返回经 `SpeechPhonetics.normalize` 清洗（取第一段 `/.../` 作音标、其后首个非空行剥标签作释义，无效为 nil）。显示固定布局：音标（等宽）+ 释义在左，🔊 按钮钉在面板右端不随内容伸缩。查询失败或无效静默不显示，不影响朗读；换朗读、返回列表、重开面板时清空，迟到结果按令牌丢弃。长文本与中文不查音标。

**收藏到 Obsidian 词汇表（2026-11-17）**：结果页（动作结果与 ✨ 跑模型）底栏 ⭐ 收藏本次原文 + 模型解释 + 当前音标释义。收藏分两步：先把解释发给默认模型提炼成精简要点（首行一句核心释义 ≤25 字 + 1-4 条「- 」要点行，失败回退原文解释不中断收藏），提炼期间 ⭐ 转进度圈防连点；再写入 vault 下的 `词汇表/YYYY-MM.md`（每月一文件，vault 由 `ObsidianVaultLocator` 自动探测：先读 Obsidian 自己的 vault 列表 `~/Library/Application Support/obsidian/obsidian.json`，取仍存在的、当前打开（`open: true`）优先、其次最近使用（`ts` 最大）的 vault（`ObsidianVaults.preferred`，Core 带测试）；读不到时兜底扫描 iCloud Obsidian 目录与 ~/Documents，目录本身是 vault 优先于子目录（子目录可能残留旧的 `.obsidian`，2026-11-20 踩坑：写进了 `00 Inbox/词汇表/`）；都找不到提示）。**月文件内按词条标题去重**（标题行 `### {title}` 全词匹配，跨天也拦），重复时 notice 提示未重复收藏。文件结构：frontmatter + 标题 + 插入锚点，词条按天分组（`## MM-dd`），月内与天内均最新在最上。词条为精简卡：三级标题行（原文首行截 40 字 + 音标 + 释义）+ 提炼正文，无 callout 无时间戳。成功后 ⭐ 变实心。生成/插入/去重逻辑在 `VocabularyNotebook`（Core，带测试），写盘走原子写。

### 9.6 调用历史（2026-11-17）

`settings.keep_history: true` 开启（**默认关闭**，隐私考量：会保存输入与输出全文）。开启后每次成功完成的动作（含 ✨ 跑模型）记录：动作标题、服务 · 模型、输入、输出、时间，存 `~/Library/Application Support/PromptDock/history.sqlite` 的 `history` 表（`HistoryStore`，Core 带测试），容量 200 条超出删最旧。菜单栏 → 调用历史… 打开查看窗口：列表展开看输入/输出全文、复制输出、清空。失败与 refusal 不记录。`keep_history` 只在开启时由 `ConfigWriter` 写出，设置窗口保存或菜单切换默认服务不会把它冲掉。

### 9.7 设置窗口（2026-11-17）

入口：菜单栏 → 设置…，或 `promptdock://settings?tab=general|providers|prompts`。菜单栏另有「默认服务」子菜单，点选即切换。

| 页 | 内容 |
|---|---|
| 通用 | 两个快捷键、粘贴后恢复剪贴板及延迟、Anthropic 默认 effort、HTTP 代理 |
| 模型服务 | 服务列表（增删）；协议、地址、模型、默认服务；API Key 设置与清除；max_tokens、effort、附加请求参数（JSON） |
| 提示词 | 列表（搜索、新增提示词/动作、删除）；标题、类型、关键词、标签、内容；动作另有服务、模型、结果方式、系统提示词 |

**写回方式**：YAML 仍是唯一数据源，手工编辑和热重载照常可用。保存时只重写有变化的顶层段（`settings:` / `prompts:`），其余文本逐字保留；被重写的段内手写注释会丢失。多行内容用 `|` 块写法，条目之间空一行；末尾带多个换行等块写法表示不了的内容自动改用引号写法。

| 保护措施 | 说明 |
|---|---|
| 写前自检 | 新文本重新解析，与预期完全一致才写入，否则报错放弃 |
| 外部修改冲突 | 窗口打开期间文件被手工改过：改的是同一段则拒绝保存（避免覆盖），改的是另一段则保留外部修改 |
| 原文件有错误 | 拒绝写入，提示先修复 |
| 备份 | 每次写入前把原文件保存为 `prompts.yaml.bak` |
| 符号链接 | 写入链接指向的真实文件，不破坏链接 |
| 服务改名 | 已保存的服务名不可改（名字被提示词条目的 `provider` 和钥匙串记录引用）；需要改名就删掉重建 |
| 条目 id | 已保存的条目 id 不可改（使用记录按 id 统计排序）；新条目自动生成 id，保存前可改 |
| 删除服务 | 保存后同时清除该服务在钥匙串中的 API Key |

窗口只查询 Key 是否存在，不读取内容，打开时不会触发钥匙串授权框。

**快捷键录制（2026-11-17）**：通用页的两个快捷键不再手工输入文字，改为点击后按下组合键录制。YAML 中的写法不变（如 `option+shift+space`），手工编辑照常可用。

| 操作 | 结果 |
|---|---|
| 点击录制框 | 进入录制状态，显示「请按下快捷键…」 |
| 按下 修饰键+主键 | 记录并显示为 `⌥⇧Space`，保存时按 control、option、shift、command 的顺序写成配置字符串 |
| 没有修饰键 | 不记录，提示至少需要一个修饰键 |
| 不支持的按键 | 不记录，提示不支持；可录按键与手写配置相同：字母、数字、F1–F12、Space、Return、Tab、Esc（需带修饰键） |
| Esc（不带修饰键）、再次点击录制框、录制框失去焦点 | 取消录制，保留原值 |

录制期间暂停两个全局快捷键（Carbon 注册的热键在系统层被截获，不暂停就录不到当前已注册的组合），录制结束后恢复。两个快捷键相同时保存被拒绝（沿用原校验）。

### 9.8 词汇表设置（2026-11-20，feat/vocabulary-settings）

**目标**：⭐ 收藏的写入位置和文件拆分方式由用户决定。普通用户在设置窗口里点选，进阶用户可以写 YAML。

**配置**（两项都可选，只在不同于默认值时由 `ConfigWriter` 写出，并补往返测试，避免被保存冲掉）：

```yaml
settings:
  vocabulary:
    dir: ~/Notes/词汇表      # 词汇表目录（最终写入目录，不再拼 folderName）；留空 = 自动识别
    split: month            # none / month / day，默认 month；其他值给加载警告并按 month 处理
```

`dir` 支持 `~` 展开；可以是任意 Markdown 目录，不要求在 Obsidian vault 里；不存在时写入前自动创建。

**目录解析顺序**（`VocabularyLocation.resolve`，Core 带测试）：

| 顺序 | 条件 | 目录 |
|---|---|---|
| 1 | 配置了 `dir` | 配置的目录 |
| 2 | 默认目录里已有 `.md` 文件 | `~/Documents/PromptDock/词汇表/`（已有数据的位置优先，避免后装 Obsidian 后新旧词条分家） |
| 3 | 识别到 Obsidian vault | `{vault}/词汇表/` |
| 4 | 以上都不满足 | `~/Documents/PromptDock/词汇表/` |

始终有可写目录，不打断用户；不打开设置窗口（面板失焦即关闭，会丢掉本次结果）。没装 Obsidian 也能用：词汇表是普通 Markdown 文件。

**文件拆分**：

| split | 文件名 | 文件内部 | 去重范围 |
|---|---|---|---|
| none | `词汇表.md` | 按天分节（`## YYYY-MM-DD`），最新在上 | 全部历史 |
| month（默认） | `2026-11.md` | 按天分节（`## MM-dd`），最新在上 | 当月 |
| day | `2026-11-20.md` | 不分节，词条直接排在插入锚点后，最新在上 | 当天 |

none 的分节标题带年份，否则跨年会撞名。模板（frontmatter + 标题 + 插入锚点）随拆分方式变化：none 的标题为「词汇表」，day 的为「词汇表 · 2026-11-20」。文件名、模板、插入、去重统一由 `VocabularyNotebook` 按 split 参数化，Core 带测试。

**设置窗口**（通用页新增「词汇收藏」分组）：

| 行 | 控件 |
|---|---|
| 保存位置 | 路径文本 +「选择…」（`NSOpenPanel` 选文件夹）+「自动」（清空配置）+「在 Finder 中显示」。未配置时以次级色显示按上表解析出的实际路径 |
| 文件拆分 | 下拉：不拆分 / 按月 / 按天 |

**收藏反馈**：成功后提示条显示「已收藏到 {完整路径，家目录缩写为 ~}」；重复时提示「{文件名} 里已有同标题词条」。⭐ 悬停提示为「收藏到词汇表」，不绑定 Obsidian 字样。

**不做**：自定义文件名模板、关闭按天分节、自定义词条格式。

## 10. 扩展方向（P2 候选）

| 能力 | 设计要点 |
|---|---|
| 模板变量 | `{clipboard}` `{date}` `{input:提示文字}`（粘贴前弹出输入框，适合多个占位符依次填写） |
| 脚本动作 | `type: script` + `command: ~/bin/xxx.sh`；选中文本通过 stdin 传入，stdout 作为结果；超时 30s |

## 11. 工程结构

```
promot-management/
├── Package.swift
├── Makefile                  # build / app / sign / install / test
├── Resources/
│   ├── Info.plist            # LSUIElement、Bundle ID: local.jemry.promptdock
│   └── prompts.example.yaml
├── Sources/
│   ├── PromptDockCore/       # 纯逻辑，可单测：模型定义、YAML 解析、Matcher、frecency、UsageStore
│   └── PromptDock/           # App：AppDelegate、菜单栏、面板、快捷键、粘贴、权限
├── Tests/
│   └── PromptDockCoreTests/
└── docs/
    ├── spec.md               # 本文档
    └── acceptance/           # 验收截图
```

`Makefile` 目标：

| 目标 | 作用 |
|---|---|
| `make test` | `swift test` |
| `make app` | release 构建并组装 `build/PromptDock.app` |
| `make sign` | 用固定的自签名证书签名（见第 12 节） |
| `make install` | 复制到 `~/Applications/` 并重启应用 |

## 12. 签名（需用户手动完成一次）

**问题**：本机没有代码签名证书。使用临时签名（ad-hoc）时，每次重新编译签名都会变化，macOS 会认为是新应用，辅助功能授权随之失效，需要反复重新授权。

**解决**：创建一个固定的自签名证书，所有构建都用它签名。

1. 打开「钥匙串访问」→ 菜单「钥匙串访问 → 证书助理 → 创建证书…」
2. 名称：`PromptDock Dev`；身份类型：自签名根证书；证书类型：代码签名
3. 创建完成后，在终端执行 `security find-identity -p codesigning`（**不要加 `-v`**），确认能看到 `"PromptDock Dev" (CSSMERR_TP_NOT_TRUSTED)`。显示「不受信任」是正常的：自签名证书不在系统信任链中，加 `-v` 时会被过滤掉，但不影响本地签名。已验证（2026-11-16）：用它签名后，签名标识绑定在证书指纹上，重新编译后保持不变
4. `Makefile` 中使用 `codesign --force --deep --sign "PromptDock Dev" build/PromptDock.app`

## 13. 已知限制

| 场景 | 表现 | 处理 |
|---|---|---|
| 密码框等安全输入状态 | 快捷键、模拟粘贴被系统拦截 | 系统行为，不处理 |
| 输入法处于组字状态 | ⌘V 可能被输入法吞掉 | 粘贴前不做处理；如实测有问题再定方案 |
| 快捷键与其他应用冲突 | 注册失败 | 菜单中提示冲突，可在 YAML 中修改快捷键 |
| 远程桌面、虚拟机窗口 | 粘贴行为取决于对方软件 | 不保证 |

## 14. P0 任务拆分（TDD）

| # | 任务 | 测试方式 |
|---|---|---|
| 1 | 初始化 git、SwiftPM 工程、Makefile、空菜单栏 App 可启动 | 手动：菜单栏出现图标 |
| 2 | 数据模型 + YAML 解析（含容错规则 6.2） | 单测：正常、缺字段、重复 id、未知 type、语法错误 |
| 3 | UsageStore（SQLite 读写、180 天清理） | 单测：使用临时数据库 |
| 4 | frecency 计算 | 单测：固定当前时间，校验半衰期 |
| 5 | Matcher 匹配与综合排序 | 单测：空查询、前缀、子序列、权重、frecency 加成 |
| 6 | 全局快捷键 + 浮动面板显示/隐藏 | 手动 |
| 7 | 面板 UI：搜索、列表、预览、键盘导航 | 手动 |
| 8 | PasteService：剪贴板备份/恢复、焦点还原、⌘V | 剪贴板备份恢复做单测；粘贴手动 |
| 9 | 热重载 + 解析错误提示 | 手动：用 vim/VS Code 保存触发 |
| 10 | 权限检查与降级 | 手动：撤销授权后验证 |
| 11 | 开机自启、菜单项补全 | 手动 |
| 12 | 真实环境验收 | 四类应用逐一验证，截图存 `docs/acceptance/` |

## 15. 开发流程约定

1. 在 `feat/p0` 分支开发，主分支为 `main`。
2. 每个任务先写测试再实现；全部单测通过后再进入手动验证。
3. 完成后按第 3 节验收标准逐项实测并截图，用户亲自实测通过后，以 `--no-ff` 合并到 `main`。
4. commit message 不添加任何 AI 署名或生成标记。
