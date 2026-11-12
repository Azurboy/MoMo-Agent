# 默认启用 DeepSeek SuperAgent、有界主动唤起与跨端进行中任务视图（2026-10-31）

为实现 DeepSeek 开源 `dsh-superagent-prototype` 的 Day-0 支持并对齐其主动编排哲学，MoMo Agent 现将 **DeepSeek SuperAgent** 设为默认智能体引擎（保留与 **Hermes Agent** 随时互换），严格按 `dsh-superagent` 的三要素准入与 `Ticket scope` 规范重构了主动唤起条件与流式转写聚合窗口，并在 iPhone 与 Mac 双端新增了统一的「正在进行的任务（子智能体与后台委派）」实时面板。

## 架构与模块边界

1. **固定上游源码与个人助手适配（`Vendor/SuperAgent/`、`Vendor/SuperAgent.UPSTREAM.json`）**
   - 固定引入 `https://github.com/deepseek-ai/dsh-superagent-prototype`（`6337fc823ce20251c8de8085948165c81aaa701e`，MIT 许可证），运行于 `@deepseek-ai/dsh@0.2.1-rc.5`。
   - `src/app/setup.ts`：当 `sources.github.enabled === false` 时跳过强制 GitHub 仓库探针，支持纯本地 Personal Agent 模式就绪，并跟踪 `sources.github.enabled` 热重载。
   - `src/sources/momo.ts`：`dsh-superagent-momo` 插件基于本机回环长轮询桥接 `chat`、`transcripts`、`life_signals`，按线程提供上下文窗口、幂等回传 `acknowledgement`/`reply`，并向 Worker 注入 `$DSH_SUPERAGENT_MOMO_CLI`、`$DSH_SUPERAGENT_MOMO_WORKSPACE`（MoMo 结果目录 `<data>/workspace`）与 `$DSH_SUPERAGENT_MOMO_SOURCE_ID`。

2. **默认切换至 DeepSeek SuperAgent 与共享数据底座（`Apps/MacApp/Runtime/`、`Apps/MacApp/Context/`、`Apps/MacApp/Desktop/`）**
   - `runtime_engine.py`、`context_server.py` 与 `DesktopModel.swift`：默认引擎切换为 `"superagent"`（`DEFAULT_ENGINE = "superagent"`，`proactive_mode = "auto"`），未创建 `runtime/engine.json` 的新装或升级目录默认进入 DeepSeek SuperAgent，并支持在 Mac「设置 → 通用 → 智能体引擎」或 `momo_agent.py engine --set hermes|superagent` 双向无损切换。
   - 切换引擎不拆分任何用户数据：会话与 Dots 三态回执读写 `<data>/runtime/conversation.sqlite`（`ProductStore`），录音与手机上下文读写 `<data>/context/context.sqlite`（`ContextStore`），长期记忆继续共用 `<data>/hermes/memories/MEMORY.md` 与 `USER.md`（`HermesMemory`）。
   - 流式全天录音静默聚合（`superagent_gateway.py`）：`ingest_context_sources` 引入静默稳定窗口（`5s` 静默或 `>=600` 字符或录制 `ended_at` 封口立即刷出，最长延迟 `30s`），避免把持续 ASR 的半截短句拆成残缺候选。

3. **对齐 SuperAgent `Ticket scope` 的主动唤起规范（`superagent_runtime.py`）**
   - 严格对照 `Vendor/SuperAgent/prompts/team/scope.md`、`prompts/admission.md`、`prompts/work.md` 与 `docs/000-philosophy.md` 重写 `DEFAULT_PROACTIVE_RULES`（`focused_local_change`、`grounded_artifact_and_audit`）及全角色提示词覆盖（含 `admission`、`work`、`handoff/worker`、`handoff/orchestrator`、`replies`）：
     - **什么时候唤起（三要素 + 中程高摩擦时长门槛，缺一不可）**：必须同时确立 **具体本机文件/结果目录产物或跨来源核对对象** + **明确落地执行意图** + **已定案的目标规格或既有规范**（`implementation_requested=true`、`target_basis` 为 `specified` 或 `existing-standard`、`requires_design_decision=false`），且聚焦于人工切环境动手需数分钟至数十分钟、子智能体后台可多步闭环的中程任务与长期规范自主学习。
     - **过滤秒级随口问、日常会议时间与无界发散重构**：随口一问的公开常识/语法速查、对话中已当场解答的问题、单纯同步“什么时候开会”“明天十点评审”、仍在争论未定案的设计选择（design debate），以及跨多模块无界大重构（除非明确要求只读调用面摸排），在准入阶段直接 `decision='ignore'`（0 条消息）。
     - **缺前置文件/无实质结论静默 `dropped`**：主动工单（`strength=inferred`）独立复核全文与磁盘文件；一旦发现所引用的历史基准文件不存在或无需人类行动，禁止上报 `blocked` 或追问，直接 `orchestrator_report(state='dropped')` 静默结案，严禁拼凑带占位符的空泛清单。
     - **有界闭环验证与精炼通知**：Worker 在无固定轮数上限的有界范围内完成代码/脚本/产物落地与真实单测/命令校验后，由 Orchestrator 发送 `<=100` 词的高信噪比同事式通知，点明核实结论与结果文件夹路径。

4. **手机端与电脑端「正在进行的任务」列表（`RemoteTaskRecoveryView.swift`、`PhoneRemoteView.swift`、`DesktopViews.swift`）**
   - 统一聚合 `RemoteTaskStore.backgroundWork` 与活跃 `sharedRuns`：自动识别并展示 `SuperAgent · 主动子智能体`、`SuperAgent · 子智能体工单`、`Hermes · 子智能体任务`、`Hermes · 后台终端任务` 及当前主会话任务，支持一键停止可取消任务（调用 `/momo/v1/conversation/work/{id}/cancel` 联动停止对应 `dsh` 工单或 Hermes 委派）。
   - **iPhone 端**：在聊天页顶部导航栏右侧、`电脑桌面`（`desktopcomputer`）按钮**正左侧**新增任务列表圆形毛玻璃按钮（`checklist`，`remote.tasks`，有活跃任务时显示实时数量角标），点击弹出半屏/全屏任务面板。
   - **Mac 端**：在桌面聊天页右上角新增「任务」胶囊按钮（`desktop.activeTasks` + 实时数量角标），点击展开原生 Popover 面板实时查看与停止任务，保持输入框底部清爽。

## 验证记录

- **Vendor/SuperAgent 构建与单测**：`pnpm build` 重新打包 `lib/index.js` 与 `lib/momo-watch.js`；`npx vitest run tests/momo-source.spec.ts` 3/3 通过。
- **Python 运行时全量单测**：`Tests/AgentRuntime/test_*.py` 共 **222 项测试全部通过**（验证默认引擎 `superagent`、流式 ASR 静默窗口合并、活跃/已结案 `dsh` 工单向 `background_work` 投影及取消链路）。
- **真机模型端到端（E2E）Scope 与唤起三场景实测**（模型：`openai-codex` / `gpt-6.1-sol`，真实启动 `ContextService` + `SuperAgentGateway` + `dsh`）：
  1. **场景 A（日常开会时间 + 未决设计争论）**：「明天上午十点开设计评审会，首页改成双列卡片流还是单列列表流明天会上再定，今天先别改」→ 准入直接 `kind=ignore`，聊天消息数 `0`。
  2. **场景 B（引用不存在的本地基准文件 `legacy_rebate_2025.yaml`）** → 静默接单核查后，Worker 发现磁盘缺失该基准文件，立即执行 `outcome=dropped` 静默关闭工单，聊天消息数 `0`（零凑数清单）。
  3. **场景 C（跨历史定案录音修复本地代码 + 单测 + 报价核对表）**：根据昨日「Q4 商业化定价定案会」录音（拍板年付 8 折 `0.80`）与当前「报价脚本走查」录音，SuperAgent 静默唤起主动子智能体（执行期间 `/momo/v1/conversation/runs` 实时暴露 `superagent:<tid>`、`state="running"`、`native_state="proactive:working"`，交付后自动清空），修复 `pricing_calc/quote_calculator.py` 与单测（`4/4` 通过），生成带 `momoagent://source/...` 原话引用的 `pricing_calc/quote_audit_12_seats.md`（12 席位月付 `1,410` 元、年付 `13,536` 元、修正差额 `846` 元），并向会话发送 2 句精炼交付通知。
- **双端编译验证**：`MoMoAgentMac`（macOS）与 `MoMoAgentBeta`（iOS Simulator）均通过 `xcodebuild` 编译校验。

## 2026-11-12 显式聊天派单回话

用户在聊天中交办事项后，Mac 网关将 SuperAgent 随派单生成的 `acknowledgement` 写入原消息所在的对话轮次，立即同步到聊天。收到正文后客户端收起三个点，用户可以继续发消息。Worker 上报 `ready` 后唤醒主会话，由 MoMo 撰写结果，通过原工单的回复渠道交付。

网关 HTTP 集成测试覆盖接单时任务仍在执行、重连回放、重复投递、两项任务逆序完成以及主动录音工单的静默接单。
