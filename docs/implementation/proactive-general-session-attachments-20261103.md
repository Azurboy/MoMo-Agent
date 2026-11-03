# 通用主动准入、连续会话线程与 HTML/Markdown 交付预览

在 `feat/proactive-general-session-threads` 完成 SuperAgent 主动派发机制的通用化升级、录音增量连续会话切分修复、订阅兼容的联网检索能力补齐，以及 macOS / iOS 双端 `.html` 与 `.md` 交付附件的完整同步与富文档预览能力。

## 1. 双轨通用主动准入（`Vendor/SuperAgent` + `Apps/MacApp/Runtime/superagent_runtime.py`）

- 在 `Vendor/SuperAgent/src/policy.ts` 为 `ProactiveTriggerRule` 增加可选布尔字段 `exploratory?: boolean`（并在 `Vendor/SuperAgent/src/client/locales.ts` 补齐设置表单与校验文案）。
- `directionAllowed` 按规则属性执行双轨门禁：
  - 未标记 `exploratory: true` 的改动型规则（如修改用户既有代码仓的 `focused_local_change`）继续严格要求 `implementation_requested=true`、`target_basis ∈ {specified, existing-standard}`、`requires_design_decision=false`。
  - 标记 `exploratory: true` 的通用调研与方案综合规则（`research_and_synthesis`）放行尚未收敛方案的开放探索（创业/产品/技术选型讨论、多方案权衡、跨历史录音核查、外部资料调研），但仅当所命中的全部规则均声明 `exploratory: true` 时才放宽门禁。
- 在 `Vendor/SuperAgent/src/executor/dsh.ts` 注入沙盒隔离目录环境变量 `DSH_SUPERAGENT_MOMO_WORKSPACE=<MOMO_DATA_DIR>/workspace`（回退至工单独立 `workspace`），并在 `mandateInstructions` 与 `MOMO_PROMPT_CONFIG` 中约束探索性工单只允许在独立工单目录内产出 `.html` / `.md` / 验证脚本等交付物，不得擅自改动用户既有项目源码或外发外部副作用。
- 闲聊、10 秒内顺手小事、当场已明确解答的问题及纯开会时间继续在调度层 `ignore`，Worker 核查无实质增量价值时静默 `dropped`。

## 2. 消除 5 分钟硬切桶“失忆孤岛”与跨段防重复建单（`Apps/MacApp/Runtime/superagent_gateway.py`）

- 移除 `win_bucket = int(latest_span_ts // 300)`（`transcript:{sid}:w{bucket}`）的 5 分钟硬时钟切桶，改为按相邻转写片段自然静默间隔切分会话线程：`TRANSCRIPT_SESSION_GAP_SECONDS = 900.0`（静默超过 15 分钟才推进至 `transcript:{sid}:s{seg_idx + 1}`）。
  - 连续 20–40 分钟的长讨论始终保持在同一 `transcript:{sid}:s0` 线程，后续增量通过 `dsh-superagent` 原生 `Subscription` 自动汇入活跃工单，不再把一场连续讨论切成多个孤立工单。
  - 多小时离线批量回传（单次 `put_transcript` 含跨时段片段）同样按 `> 900s` 静默边界切分为独立 `:s0` / `:s1` 批次，避免不相关话题混入同一触发单元。
- `BridgeStore.coalesce_unpolled_transcripts` 改为按 `(source_id, thread_id)` 聚合未轮询增量，确保不同会话段（`:s0` 与 `:s1`）绝不在队列中被合并覆盖。
- 触发文本头部与 `/momo/internal/superagent/context` 响应新增 `recent_tickets`（最近 24 小时主动工单摘要），供 Orchestrator 与 Worker 识别同一议题已有工单，避免重复建单。

## 3. 订阅兼容的联网检索与正文提取（`Apps/MacApp/Runtime/momo_cli.py`）

- 新增 `momo_cli.py web-search` 与 `momo_cli.py web-extract` 子命令，复用 `Vendor/HermesAgent/tools/web_tools.py` 的免 Key 远程 MCP 检索环与本地提取回退链：
  - 将工具内部进度输出重定向至 `stderr`，保证 CLI `stdout` 为纯 JSON。
  - 在无独立第三方 API Key（如 ChatGPT Plus/Pro OAuth 订阅模式）时自动绕开仅限服务端推理循环的 `openai-native` 及仅支持搜索的 `ddgs` 提取后端，走免 Key 远程 MCP / 标准库兜底提取。

## 4. macOS 与 iOS 双端 `.html` / `.md` 附件同步与富文档预览

- **服务端产物自动挂载（`conversation_store.py`、`superagent_gateway.py`、`personal_agent.py`）**：
  - `collect_deliverable_attachments` 在沙盒白名单目录（`workspace/<ticket>`、`work/<ticket>` 等，严格校验 `Path.resolve().is_relative_to(...)` 并排除 `MEMORY.md`、`USER.md`、`attachments/`、隐藏文件与构建目录）自动提取 Worker 或主会话产出的 `.html`、`.md`、`.csv`、`.json`、`.txt` 及图片产物（文本交付物单文件上限 512 KB，确定性 `UUIDv5` 标识）。
  - 同时写入会话消息 `attachments_json`（`/momo/v1/conversation/messages`）与任务详情 `ConversationWorkDetail.attachments`（`/momo/v1/conversation/work/{id}`），使通过 HTTPS 或 WebRTC 连接的 iPhone 无需访问 Mac 本地 `/Users/...` 路径即可离线完整打开交付物。
- **跨端模型与导入上限对齐（`Packages/MoMoAgentAgentClient`、双端 `Importer`）**：
  - `AgentAttachment` 新增 `isHTMLDocument`、`isMarkdownDocument`，并将用户上传文本文档校验上限从 `48_000` 提升至 `256_000` 字节；双端文件选择器新增 `.html` 与 `.md` 类型支持。
  - `ConversationWorkDetail` 解码兼容旧服务端无 `attachments` 字段的响应（默认空数组），`RemoteTaskStore.attachment(id:)` 同时检索草稿、历史消息及已加载任务详情附件。
- **聊天气泡与任务详情卡片 + 沙盒富预览器（`Apps/iPhoneApp/Features/Assistant/Rendering/Web/*`、`Apps/ClientUI/*`）**：
  - `chat-core.js` / `chat.js` / `chat.css` 在保持用户侧 `.message-attachment` 120×120 磁贴几何不变的前提下，为助理侧消息渲染 `.assistant-attachment` 交付卡片（带 `HTML` / `MD` 格式徽标、文件名、体积与预览触发）；`RemoteTaskRecoveryView.swift` 在任务详情同步展示“交付附件”卡片列表。
  - `ClientAttachmentPreview`（macOS 14+ 与 iOS 18+ 共用，且 `ChatAttachmentPreview` 统一委托至此）新增基于非持久 `WKWebsiteDataStore.nonPersistent()` 的 `SandboxedDocumentWebView`：
    - `.html`：沙盒渲染交互式 HTML 原型/看板，自动补齐移动端 `viewport`，禁止读取任意本地 `file://` 路径，拦截外链交由系统浏览器打开。
    - `.md`：通过内置离线资源 `Web/markdown-document.html` + `markdown-document.js`（`marked` + `DOMPurify` + `KaTeX` + `highlight.js`）完整渲染 GFM 表格、语法高亮代码块、数学公式并自适应深浅色模式。
    - 双端均支持 **`预览` / `源码` 分段切换** 与 **`ShareLink` 原文件名导出分享**。
