# DeepmacOS 实施方案 v0.3

> 目标：在 macOS 上做一个"原生壳 + WebView"的 DeepSeek 客户端，功能覆盖 DeepSeek 网页版聊天，走官方 API 计费，避开网页版限流。
> 状态：**v0.1 已交付**（2026-11-17）。下文 §1–§10 保留计划原貌，实际完成情况见 §0.5，后续见 §11。
> v0.2 变更：全局快捷键、Services 菜单/右键服务改为**默认关闭**；用量看板增加**余额显示**。
> v0.3 变更：锁定三项决定（阈值默认 10 可改、菜单栏常驻默认关闭、模型 `deepseek-flash`），并补交付记录与偏差说明。
> 日期：2026-11-17 · 环境：macOS 27.2.1 / Xcode 27.2 / Node 26.7.0（pnpm 待装）/ 空目录 `/Users/rarespecies/Documents/folder/DeepmacOS`

---

## 0. 一页结论

| 问题 | 结论 |
| --- | --- |
| 用什么做界面 | **官方开源的 `deepseek-ai/chat-demo`**（MIT，纯静态，无后端，直连 API），构建产物 `dist/` 原样内嵌 |
| 用什么做壳 | **SwiftUI + WKWebView**（原生壳），不引入 Electron/Tauri |
| WebView 怎么加载 | app 内起一个 **127.0.0.1 随机端口的只读静态服务**，让页面跑在真实 http origin 上（localStorage / IndexedDB 才可靠） |
| 怎么接 API | 前端**直连 `https://api.deepseek.com`**，实测 CORS 开放，无需反向代理、无需改 `chat-demo` 源码 |
| 网页版功能能否全覆盖 | 对话/思考/联网搜索/读链接/附件/OCR/图片理解/语音输入/朗读/公式/Mermaid **可覆盖**；云端同步、分享链接、账号体系**不可覆盖**（API 无对应端点） |
| 限流问题 | 网页版限流 → 换成 API 的**并发上限 + 付费额度**；壳里做**用量账本 + 余额显示**（`GET /user/balance`），省钱靠 off-peak 半价、cache hit、`deepseek-flash` 默认 |
| 交付周期 | M0 半天打通 → M1 1.5 天可用壳 → M2 2~3 天体验 → M3 1 天分发；约 **1 周出可用版本** |

一句话：**壳是我们写的，界面是官方的，脑子是 API 的，数据全在本机。**

---

## 0.5 交付记录（v0.1，2026-11-17 实测）

| 里程碑 | 状态 | 实测依据 |
| --- | --- | --- |
| M0 打通 | ✅ | 回环静态服务 + WKWebView + 内嵌 dist；真实 API 流式回复成功 |
| M1 可用壳 | ✅ | 菜单/快捷键、外链走浏览器、导出走 `WKDownloadDelegate`、窗口恢复、单实例 |
| M2 体验 | 🟡 部分 | 已做：用量账本、余额、阈值提醒、默认关闭的三项增强入口；未做：Keychain |
| M3 分发 | ✅ | ad-hoc 签名 `.app` + `.dmg`，随包 LICENSE 与 README |

实测数据：

- 真实请求一次（"用一句话确认收到"）：`input 40 / output 15` tokens，账本写入 `~/Library/Application Support/DeepmacOS/usage.jsonl`
- 余额：`GET /user/balance` 返回 `¥31.54 CNY`，面板显示与官网一致
- 导出：blob → `WKDownloadDelegate` → 落盘 18 字节 ZIP，回调 `downloadDidFinish`
- 持久化：固定端口 `43110` 后重启，探针读到 `hasKey=1`、IndexedDB `sessions=1`、`origin` 不变

交付前发现并修复的关键缺陷：**端口原先随机，导致每次启动 origin 变化，localStorage/IndexedDB 按 origin 隔离，历史与 Key 会"消失"**。现在端口写回偏好并在启动时复用（被占用才顺延）。

与计划的偏差：

1. **Keychain 未实现**（决策 B 的 B2）：v1 继续由官方前端把 Key 存在 localStorage，README 已标注风险与后续方案。
2. 通知授权从"启动即请求"改为"应用首次激活时请求"，避免后台任务弹系统提示。
3. 阈值/开关/账本放在原生设置窗口，不改官方前端界面。
4. 增加了 `DEEPMACOS_SELFTEST=1` 自检通道（默认不出现），用于无头验证页面、用量、下载。

未验证（需要人工确认）：

- 语音输入与朗读（麦克风授权 + 实际录音）
- 全局快捷键、Services、菜单栏常驻"开启后"的行为（默认关闭，未逐项实测）
- 通知横幅展示（需系统授权）
- macOS 14 实机（本机为 27.2）

---

## 1. 事实核对（2026-11-17 实测）

### 1.1 官方开源了什么

- `deepseek-ai/chat-demo`：v0.1.1，MIT，React 18 + zustand + rspack，源码约 1.45 万行。**就是网页版聊天的前端形态**，README 明确"无需应用后端，浏览器直连 API"。
  - 功能：多会话 + 自动标题 + 重命名删除、编辑提问、重新生成、**消息分支切换**、流式回复、**深度思考**、**智能搜索 + 链接阅读 + 来源引用**、停止生成、**继续生成**、附件上传/粘贴/拖拽、**语音输入**、**朗读**、Markdown/代码高亮/KaTeX/Mermaid、中英双语、明暗主题、移动端布局、位置设置、**历史导入导出（ZIP）**。
  - 构建：`pnpm build` → `dist/`，可直接静态部署；`rspack.config.ts` 用 `createConfig({ apiOrigin })` 注入 `__API_ORIGIN__`，默认 `https://api.deepseek.com`。
- `deepseek-ai/deepseek-harness`（DSH）：MIT，Cordis "一切皆插件" 的 **agent harness**，可 `npx @deepseek-ai/dsh web` 起 Web UI（127.0.0.1:3080），官方也有 macOS/Windows 桌面端 dmg。
  - 定位差异：DSH 是**智能体工作台**（后台任务、本地文件读写、工具链），不是"网页版聊天"的复刻。我们的目标与 chat-demo 对齐，所以主路线选 chat-demo；DSH 作为 M4 可选能力来源（见 §7）。
- 官方并未开源网页版私有接口/会话体系，所以**不要**去想"复用网页版额度"。本方案只走公开 API。

### 1.2 官方 API 提供了什么（关键：够用）

- 协议：OpenAI 兼容（`https://api.deepseek.com`）**与 Anthropic 兼容**（`https://api.deepseek.com/anthropic`）。chat-demo 走 Anthropic Messages。
- 模型：
  - `deepseek-flash`：1M 上下文 / 最大 384K 输出 / **支持图片输入** / thinking 档位 low·high·max（默认 high）
  - `deepseek-v4-pro`：1M 上下文 / 仅文本 / 同档位
- 应用类 API（官方文档首页明确"全套应用 API 已可用"）：Web Search、URL Fetch、OCR、Files、ASR、TTS、模型安全。
- 并发上限：flash 2500、pro 500（这是"限流"在本方案里的真实形态，个人用远达不到）。

### 1.3 我在 chat-demo 源码里核实的端点（原生壳只需认识这几个）

| 用途 | 端点 | 鉴权 | 备注 |
| --- | --- | --- | --- |
| 校验 Key | `GET /models` | `Authorization: Bearer` | 免费，不产生 token |
| 流式对话 | `POST /anthropic/v1/messages` | `x-api-key` | SSE；开启搜索时 tools 带 `deepseek_web_search`，始终带 `deepseek_read_url` |
| 上传附件 | `POST /anthropic/v1/files` | `x-api-key` + `anthropic-beta: files-api-2025-04-14` | multipart，`purpose` 需在 `file` 前 |
| 删除附件 | `DELETE /anthropic/v1/files/{id}` | 同上 | |
| 语音识别 | `POST /v1/tools/asr` | `Authorization: Bearer` | WAV/Ogg，≤120s，≤8MiB |
| 朗读 | `POST /v1/tools/tts` | `Authorization: Bearer` | 返回裸 PCM 24kHz 单声道 s16le，`filter_markdown: true` |
| **余额** | `GET /user/balance` | `Authorization: Bearer` | 不计费；返回 `is_available` 与 `balance_infos[]`（CNY/USD，总值/赠送/充值，字段均为字符串） |

- 存储：`localStorage` 前缀 `chat-demo:`（api-key、locale、theme、location、tts voice、thinking、search、sider），会话与附件在 IndexedDB 数据库 `chat-demo`。
- 前端设备能力：录音用 `getUserMedia`（依赖安全上下文：HTTPS / localhost / file://），朗读用 `AudioContext` 排程播放，导出用 `URL.createObjectURL` + `a[download]`。

### 1.4 CORS 实测

对 `/anthropic/v1/messages`、`/v1/tools/tts`、`/user/balance` 发 OPTIONS 预检，均返回 `access-control-allow-origin` 回显来源；对话类允许 `x-api-key/authorization/content-type/anthropic-beta`，余额只允许 `GET + authorization`。未带 Key 的 `GET /user/balance` 返回 401（CORS 头存在，页面能读到错误体）。
**=> 页面运行在 `http://127.0.0.1:PORT` 时可直连 API，不需要代理层。**

### 1.5 计费（决定产品要不要做"用量看板"）

| 项目 | 价格 |
| --- | --- |
| flash 输入（cache hit / miss） | off-peak $0.003 / $0.15 每 1M；peak 翻倍 |
| flash 输出 | off-peak $0.6 每 1M；peak $1.2 |
| pro 输入（hit / miss） | $0.022 / $0.66（off-peak）；输出 $1.98 |
| Search / Fetch | $0.75 / 千次 |
| 文件解析 / OCR | $0.225 / 千页 |
| TTS | $0.45 / 万字符（限时 $0.225） |
| ASR | $0.116 / 小时（限时 $0.058） |

- peak = 周一至周五 UTC 01:00–04:00 与 06:00–10:00 = **北京时间 09:00–12:00、14:00–18:00**，其余时间与周末/国内法定假日半价。
- cache hit 比 miss 便宜 **50 倍**：前缀（系统提示 + 历史）保持稳定、别在中途改 system prompt 就基本是 hit。

---

## 2. 目标 / 非目标

**目标**
1. 用官方开源组件实现网页版聊天功能对齐，个人日常可替代网页版。
2. 走官方 API Key 计费，不受网页版限流；用量可见、可控。
3. 原生壳该有的都有：菜单快捷键、拖拽、通知、外链、另存为、窗口恢复、深浅色跟随、单实例。
4. 数据全本地、可导出可迁移，不依赖任何自建服务。

**非目标（v1 明确不做）**
1. 不复刻网页版私有接口、不复用网页登录态或额度（违反条款，也不稳定）。
2. 不做账号体系、云端同步、分享链接（API 没有对应端点；要做需自建后端，见 §9 决策 A）。
3. 不上 Mac App Store（含密钥输入 + WebView 壳，审核风险高，个人自用没必要）。
4. 不重写 UI（纯 SwiftUI 重做 Markdown/KaTeX/Mermaid/分支树，成本 3~4 周且持续维护，不划算）。
5. 不内置模型、不做本地推理。

---

## 3. 总体架构

```
┌────────────────────────────── DeepmacOS.app（SwiftUI, macOS 14+）──────────────────────────────┐
│  Scene / NSWindow                                                                              │
│   ├─ WKWebView  ←  http://127.0.0.1:<随机端口>/   （真实 origin ⇒ localStorage/IndexedDB 正常）  │
│   │     ├─ 静态资源：内嵌 chat-demo 的 dist/（只读，SPA fallback 到 index.html）                 │
│   │     └─ 前端 fetch/SSE 直连 https://api.deepseek.com（CORS 已开放）                          │
│   ├─ LoopbackServer  NWListener 只绑 127.0.0.1，随机端口，仅 GET/HEAD，路径越权防护             │
│   ├─ NavigationPolicy  外链→系统浏览器；blob 下载→NSSavePanel；file input→NSOpenPanel           │
│   ├─ MediaCapture  WKUIDelegate 媒体授权回调 + NSMicrophoneUsageDescription                     │
│   └─ NativeBridge  WKScriptMessageHandler（Keychain / 通知 / 用量账本 / 快捷键 / 导出 / 更新）   │
└───────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 3.1 为什么是"本地回环 HTTP"而不是别的加载方式

| 方案 | 问题 | 结论 |
| --- | --- | --- |
| `file://` 直开 dist | WebKit 下 file origin 的 localStorage/IndexedDB 不可靠（官方 README 同样提示 file:// 依赖浏览器存储支持）；`getUserMedia` 也拿不到安全上下文 | ✗ |
| 自定义 scheme（`WKURLSchemeHandler`，如 `app://`） | 自定义 scheme 在 WKWebView 里 origin/存储行为不统一，IndexedDB 常报 SecurityError；会话历史一丢就是灾难 | ✗ |
| 内嵌 `chat.deepseek.com` | 又回到网页版限流、且不能用 API Key，还需要登录态，违背初衷 | ✗ |
| **127.0.0.1 loopback 静态服务** | 需要自己写 ~200 行 HTTP/1.1 静态服务 | **✓ 选它** |

- 端口随机、只绑回环、只读、只允许 GET/HEAD，路径规范化后必须落在资源根目录内（防 `..` 越界）。
- 附带好处：`http://127.0.0.1:*` 在 WebKit 里属于"potentially trustworthy origin"，录音可用（M0 必验，见 §6）。

### 3.2 为什么不做 API 代理

CORS 已开放 ⇒ 代理只增加 SSE 透传、multipart、abort、流式下载四个坑。原生壳要做的增强（Keychain、用量）通过 `WKScriptMessageHandler` 或"注入 localStorage"更轻。
若后续要做**统一计量/重试/脱敏日志**，再在 M2 加可选代理（`apiOrigin` 指向 `http://127.0.0.1:PORT/api` 即可，`createConfig` 已支持）。

### 3.3 数据与安全模型

- **数据落地**：WKWebView `websiteDataStore = .default()`，存储位于 app 容器内（`~/Library/Containers/.../WebKit/WebsiteData/`）。会话与附件在 IndexedDB；设置与 Key 在 localStorage。
- **Key 的两种放法**（决策 B）：
  - B1 零改动：留在 localStorage（与网页版一致，明文落在 app 容器内，依赖 FileVault）。
  - B2 Keychain：打一个**单文件小 patch**（`src/services/settings.ts` 的 `read/write` 走 `window.webkit.messageHandlers.*`），Key 存 Keychain，localStorage 只留掩码。推荐 B2，代价约半天。
- **不记录敏感内容**：日志只记端点、状态码、耗时、token 数；请求体/回复正文不入日志。
- **备份**：复用 chat-demo 自带的 ZIP 导入导出（会话 + 图片），M2 加"每周自动导出到 `~/Documents/DeepmacOS Backups`"（可选）。
- **清缓存等于删全部本地历史**：UI 上要二次确认，并提示先导出。

---

## 4. 功能对齐矩阵（网页版 → 本 app）

| 网页版功能 | 本方案 | 承载 | 风险 |
| --- | --- | --- | --- |
| 多轮对话 / 流式输出 | ✅ | chat-demo + SSE | 低 |
| 深度思考（含展开、耗时） | ✅ | `thinking:{type:enabled}` + `reasoning_effort` | 低 |
| 联网搜索 + 来源引用 | ✅ | 服务端 tool `deepseek_web_search`（结果块 `web_search_tool_result`） | 中：搜索按次计费 |
| 链接阅读 | ✅ | `deepseek_read_url` / Fetch 工具 | 低 |
| 上传文件（PDF/Word/Excel/PPT/图片） | ✅ | Files API + 服务端解析/OCR | 中：格式与大小由服务端校验，需前置提示 |
| 图片理解 | ✅ | flash 的 vision | 低（pro 不支持图片） |
| 语音输入 | ✅ | `/v1/tools/asr` | 中：`getUserMedia` 需安全上下文 + 麦克风授权 |
| 朗读 | ✅ | `/v1/tools/tts`（PCM 流式播放） | 低 |
| Markdown / 代码高亮 / 公式 / Mermaid | ✅ | chat-demo 内置 | 低 |
| 历史记录 | ✅ **仅本地** | IndexedDB + ZIP 导入导出 | 中：清缓存即丢，需备份策略 |
| 跨设备同步 / 云端历史 | ❌ | API 无端点 | 需自建后端（决策 A） |
| 分享对话链接 | ❌ | API 无端点 | 可退化为"导出 Markdown/图片" |
| 账号 / 登录 / 会员额度 | ❌ 换形态 | 直接 API Key + 余额 | 体验差异需在引导页说明 |
| 网页版限流 | ✅ 不适用 | API 并发 2500/500 + 付费 | 成本要可见（§5 用量看板） |

---

## 5. 原生壳能力清单

**M1 必备（不做就等于套壳，体验掉档）**
- 菜单栏：文件（新对话 ⌘N、导出、关闭）、编辑（撤销/粘贴，走 WebView 系统行为）、显示（重载 ⌘R、缩放、全屏）、窗口、帮助。
- 快捷键：⌘N 新对话、⌘, 设置、⌘F 页内搜索、⌘⇧S 导出、⌘0/⌘± 缩放。
- 拖拽：文件拖到窗口任意位置即上传（`registerForDraggedTypes` + 注入到页面 drop 区），Dock 图标拖入也能接。
- 外链：`http(s)` 目标 `_blank` → `NSWorkspace.open` 系统浏览器；站内路由放行。
- 下载：`a[download]`（历史导出）→ `WKDownloadDelegate` → `NSSavePanel`。
- 通知：回复完成（窗口非前台时）→ `UNUserNotificationCenter`；Dock 角标显示未读数。
- 窗口：多窗口（⌘N 开新窗口可配置）、位置尺寸恢复、单实例（`LSMultipleInstancesProhibited`）。
- 主题：跟随系统深浅色（页面已有 `themePreference`）；窗口透明/侧边栏毛玻璃按需。
- 安全：麦克风用途说明、无摄像头权限、`WKWebView` 禁止 `window.open` 新窗口逃逸。

**M2 体验增强**
- Keychain 存 Key（B2 patch）+ 设置页显示"已存于钥匙串"。
- **用量看板 + 余额**（侧边栏入口 + 设置页"用量与费用"）：
  - 账本：本地记录每次请求的 `usage`（input/output/cache 命中）、搜索次数、TTS 字符数、ASR 时长；按官方价目分 peak/off-peak 估算当日、当月花费。
  - **余额**：`GET /user/balance`，主行显示 `total_balance`，副行显示 `granted_balance` / `topped_up_balance`；CNY 与 USD 分行显示；`is_available=false` 时红字提示"余额不足，请求会被拒"。
  - 刷新时机：启动、打开面板、每次回复结束后（去抖 5s，且两次请求间隔 ≥60s）、手动刷新；失败静默，显示"上次更新 14:32"，不弹错误框。
  - 低余额提醒：默认阈值 ¥10 / $1，命中后每天最多通知一次，阈值可改。
  - 对账：面板并列"账本估算花费"与"余额实际减少"，偏差 >10% 时提示（价目调整或漏记）。
  - 余额与账本只存本地快照（JSONL，保留 90 天），不上报。
- **全局快捷键：默认关闭**。设置 → 增强功能里显式开启（默认 ⌥Space，可改），开启时提示可能与 Alfred/Raycast/输入法冲突；用 `RegisterEventHotKey` 注册，不申请辅助功能权限；开关关闭时**不注册任何热键**（不占键、不监听）。
- **Services 菜单 / 右键服务：默认不启用**。`NSServices` 是 Info.plist 静态声明、运行时无法增删，所以做成"服务项存在、默认不动作"：偏好关闭时选中文本调用该服务，只弹一句"该功能未启用，去设置开启"，不弹提问框、不发任何请求；设置里开关旁写明"开启后选中文本即可用"。首次启动不做相关提示。
- 导出当前会话为 Markdown / PDF（WebKit `createPDF`）。
- 崩溃与错误上报：仅本地日志文件 + 一键导出诊断包。
- 自动更新：Sparkle 2（自建 appcast 或 GitHub Releases）。

**M3 可选**
- 菜单栏常驻小窗（MenuBarExtra）快速问答，默认关闭、需在设置开启。
- 离线 ASR（`SFSpeechRecognizer`）替代付费 ASR；系统 `AVSpeechSynthesizer` 兜底朗读。
- 多 provider（OpenAI 兼容端点可换 base_url）。

---

## 6. 里程碑与验收

| 阶段 | 产出 | 验收标准 | 估时 |
| --- | --- | --- | --- |
| **M0 打通** | Xcode 工程骨架 + LoopbackServer + WKWebView + `dist` 内嵌 | 填 Key → 出流式回复；停止生成可中断；断网有错误提示；`GET /models` 校验通过 | 0.5 天 |
| **M1 可用壳** | 菜单/快捷键/拖拽/外链/下载/通知/窗口恢复 | 上面 6 项逐条手工验收；⌘N/⌘R/⌘F 生效；导出 ZIP 能另存 | 1.5 天 |
| **M2 体验** | Keychain、用量看板 + 余额、全局唤起（默认关）、Services（默认关）、PDF/MD 导出 | 账本与官方账单同量级（±5%）；余额与官网一致、≤60s 可刷新；Key 不出现在 localStorage；**冷启动默认零全局热键注册、选中文本不触发请求**；显式开启后唤起 <300ms | 2~3 天 |
| **M3 分发** | ad-hoc 签名 + DMG + 首启引导 + LICENSE/第三方声明 | 双击可开（无 quarantine 报错或用 `xattr -d`）；首启引导 3 屏；包含 MIT LICENSE 文本 | 1 天 |
| **M4 可选** | 分享/同步（需后端）、自动更新、agent 能力 | 按需单独立项 | 2 天+ |

**M0 必须先验证的 6 个假设**（任何一条翻车都要改架构，所以放最前面）：
1. `http://127.0.0.1:PORT` 在 WKWebView 里是安全上下文 → `getUserMedia` 可用；
2. 该 origin 的 localStorage / IndexedDB 重启后仍在；
3. SSE 增量渲染正常，`AbortController` 能真正中断上游；
4. blob `a[download]` 能被 `WKDownloadDelegate` 接管；
5. 拖拽文件进 WKWebView 能触发页面上传；
6. 直连 `api.deepseek.com` 的预检与流式响应在 WebView 里无异常（curl 已验证，浏览器环境待验）。

---

## 7. 目录结构与构建

```
DeepmacOS/
├─ PLAN.md
├─ Makefile                      # web-build / app-build / dmg / run
├─ vendor/chat-demo/             # git submodule，锁定 commit（勿跟 main 浮动）
├─ app/
│  ├─ DeepmacOS.xcodeproj
│  ├─ Sources/
│  │  ├─ App/DeepmacOSApp.swift          # Scene、命令菜单、单实例
│  │  ├─ Web/WebViewHost.swift           # NSViewRepresentable + WKWebView 配置
│  │  ├─ Web/NavigationPolicy.swift      # 外链/下载/新窗口拦截
│  │  ├─ Web/MediaCapture.swift          # 麦克风授权回调
│  │  ├─ Web/Downloads.swift             # WKDownloadDelegate → NSSavePanel
│  │  ├─ Server/LoopbackServer.swift     # NWListener + 最小 HTTP/1.1
│  │  ├─ Server/StaticHandler.swift      # MIME、SPA fallback、越界防护、缓存头
│  │  ├─ Bridge/NativeBridge.swift       # WKScriptMessageHandler（读写偏好开关）
│  │  ├─ API/BalanceClient.swift         # GET /user/balance（去抖 + 失败静默）
│  │  ├─ Storage/Keychain.swift
│  │  ├─ Storage/UsageLedger.swift       # 用量/费用账本 + 余额快照（SQLite 或 JSONL）
│  │  ├─ Shortcuts/GlobalHotKey.swift    # 默认不注册，开启后才 RegisterEventHotKey
│  │  ├─ Services/AskService.swift       # NSServices handler，偏好关闭时不动作
│  │  └─ UI/Settings.swift, Onboarding.swift, MenuBar.swift, UsagePanel.swift
│  ├─ Resources/web/                     # dist 产物（构建生成，.gitignore）
│  └─ Info.plist                         # NSMicrophoneUsageDescription、LSMinimumSystemVersion=14.0
└─ dist/                                 # 打包产物：DeepmacOS.app / .dmg
```

**构建流程**
```bash
# 1) 前端（一次装好，之后只在升级 chat-demo 时跑）
corepack enable && corepack prepare pnpm@latest --activate
cd vendor/chat-demo && pnpm install --frozen-lockfile && pnpm build
# 2) 把 dist 拷进 app 资源
rsync -a --delete vendor/chat-demo/dist/ app/Resources/web/
# 3) 原生
xcodebuild -project app/DeepmacOS.xcodeproj -scheme DeepmacOS -configuration Release build
```
- `dist/` 作为 **folder reference** 打进 Resources（保持目录结构，hash 文件名不带进 bundle id 逻辑）。
- 已落地基线：`vendor/chat-demo` 已克隆到 **`5d5dd75`**（v0.1.1，2026-11-13，"fix: clarify history import errors and release v0.1.1"），以该 commit 锁定，后续改为 submodule 引用它。
- 升级 chat-demo = 改 submodule commit + 重跑 1)/2) + 跑一遍 §6 验收。**不要把 `main` 浮在上面**，它还是 0.1.x 的 demo。
- 本机签名：ad-hoc（`CODE_SIGN_IDENTITY=-`）即可自用；给别人用需要 Developer ID + 公证（决策 C）。

**关键实现要点（骨架）**
```swift
// WebViewHost：只允许加载自己的回环 origin
let cfg = WKWebViewConfiguration()
cfg.websiteDataStore = .default()                    // 持久化会话历史
cfg.preferences.isElementFullscreenEnabled = true
cfg.setURLSchemeHandler(...)                         // 不用，保留默认
webView = WKWebView(frame: .zero, configuration: cfg)
webView.uiDelegate = self                            // 媒体授权 / file input / 新窗口
webView.navigationDelegate = self                    // 外链与下载策略
webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))

// 媒体授权（macOS 12+）：录音必须显式允许，否则 getUserMedia 直接 reject
func webView(_ w: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
             initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
             decisionHandler: @escaping (WKPermissionDecision) -> Void) {
    decisionHandler(type == .microphone ? .grant : .deny)
}
```
```swift
// StaticHandler 的越界防护（伪代码）
let root = Bundle.main.resourceURL!.appendingPathComponent("web").standardized
let target = root.appendingPathComponent(path).standardized
guard target.path.hasPrefix(root.path) else { return 403 }
// 不存在且不是资源 → 返回 index.html（SPA 路由）
```

---

## 8. 风险登记表

| # | 风险 | 影响 | 概率 | 对策 |
| --- | --- | --- | --- | --- |
| R1 | chat-demo 是 demo，接口/字段会变 | 升级即坏 | 中 | 锁 commit；M2 加启动自检（6 个端点探活 + `/models` 校验 + 版本指纹） |
| R2 | WebView 存储被系统清理/配额 | 历史丢失 | 中 | 自动备份导出 + 首启提示 + 清缓存二次确认 |
| R3 | `getUserMedia` 在回环 origin 被拒 | 语音输入不可用 | 低 | M0 首验；兜底：原生 `AVAudioEngine` 录音 → 走 ASR（bridge 传 WAV） |
| R4 | 大附件上传慢/超限 | 上传失败 | 中 | 前端已由服务端校验；壳侧前置大小与类型提示；区分"图片直传 vs 文档解析" |
| R5 | SSE 长回复被系统挂起 | 回复中断 | 低 | 后台任务 + 断点"继续生成"（chat-demo 自带） |
| R6 | Key 泄露面（localStorage、日志、崩溃报告） | 账号被盗刷 | 中 | 决策 B2（Keychain）+ 日志脱敏 + 关闭 WebKit 远程调试（Release） |
| R7 | 费用失控（搜索/OCR/TTS 都是按次） | 账单超预期 | 中 | 用量看板 + 余额显示 + 低余额/阈值提醒 + 默认关搜索、需要时开 |
| R8 | 合规/命名 | 被投诉或下架 | 低 | 见 §9；不叫 DeepSeek、不用其图标，只写"基于 DeepSeek API 的第三方客户端" |
| R9 | macOS 版本差异（27.x 新特性） | 兼容问题 | 低 | 部署目标 14.0，只在 14+ API 上用 |
| R10 | 默认关闭的快捷键 / Services 用户根本找不到 | 功能形同不存在 | 中 | 设置里单列「增强功能」分区、开关旁一句说明；关闭态不注册热键、不动作；首启引导不打扰 |

---

## 9. 合规与命名

- **许可**：chat-demo 是 MIT，分发时**必须**带上 `LICENSE`（构建已自动拷进 `dist/LICENSE`）与第三方声明（Mermaid/KaTeX/Prism 等各自许可）。我们修改的部分同样以 MIT 放出即可。
- **命名**：不要用 "DeepSeek" 作为产品名/图标（避免混淆官方），建议 `DeepmacOS` 或自取名字，副标题写"第三方客户端，基于 DeepSeek 开放 API"。
- **条款**：只调用公开 API；不抓取网页接口、不复用 cookie/登录态、不绕过限流。API Key 归属本人，按官方价目付费。
- **隐私**：数据默认只在本机；但发消息、上传附件、语音都会按需发送到 `api.deepseek.com`，首启引导要一句话讲清楚（chat-demo README 同样声明）。

---

## 10. 待你拍板（这 4 个决定会改变排期）

| # | 决策 | 选项 | 我的建议 |
| --- | --- | --- | --- |
| A | 历史只存本地够不够？ | (a) 只本地 + ZIP 导出 (b) 自建同步后端 | **(a)**，省 1~2 周；真要同步，M4 单独立项 |
| B | API Key 放哪？ | (a) localStorage 零改动 (b) Keychain 需 1 处 patch | **(b)**，半天成本换掉一个长期风险 |
| C | 分发给谁？ | (a) 只自己/小圈子：ad-hoc 签名 (b) 公开分发：Developer ID + 公证（$99/年） | **(a)** 起步 |
| D | 要不要保底内嵌网页版？ | (a) 不嵌 (b) 第二 tab 打开 chat.deepseek.com | **(a)**，会再次撞限流且体验割裂 |

补充几个小问题：
- 默认模型用 `deepseek-flash` 还是 `deepseek-v4-pro`？（建议 flash，需要硬活再切 pro；pro 不支持图片）
- 低余额提醒阈值默认 ¥10 / $1，要不要改？
- 全局快捷键与 Services 已按你的要求**默认关闭**，入口统一放「设置 → 增强功能」；菜单栏常驻（M3，同样默认关闭）还要不要？

---

## 附：参考

- 官方开源聊天前端：https://github.com/deepseek-ai/chat-demo （在线 demo：https://deepseek-ai.github.io/chat-demo/）
- 官方 harness（另一条路线的参考）：https://github.com/deepseek-ai/deepseek-harness
- API 文档：https://api-docs.deepseek.com/ （模型与价格 / Files API / Web Search & Fetch / ASR & TTS / Vision）
- 官方桌面端下载页（说明官方桌面端是 Harness，不是网页版聊天）：https://www.deepseek.com/zh/download/

---

## 11. 后续（v1.1+）

1. **Keychain 迁移**：patch `src/services/settings.ts`，Key 只进钥匙串，localStorage 存掩码；启动时用 `WKUserScript` 注入。
2. 全局快捷键 / Services 开启后的端到端测试，以及按键冲突提示（⌥Space 常被 Alfred/Raycast 占用）。
3. 导出当前会话为 Markdown / PDF（`createPDF`），接到文件菜单。
4. Sparkle 2 自动更新（自建 appcast 或 GitHub Releases）。
5. 语音链路端到端（ASR/TTS），可选离线 `SFSpeechRecognizer` 兜底。
6. 多窗口 / 标签页；菜单栏常驻小窗（默认关闭）打磨。
7. 分享与同步（需自建后端，另立项）。
