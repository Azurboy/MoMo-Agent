# Dream 2.0：统一共享 `MoMoMemory`、闲时四阶段深层整合、语义说话人推理与纯 Markdown 活页记忆（0.5.0）

## 背景与调研综合

针对原有 Dream 利用率低、输入盲区大（仅有 `signature` 与 `source_revision`，缺少录音目录、地点、日程与说话人角色）、推理关闭、受限于 `MEMORY.md` 2,200 字符上限，以及历史命名 `HermesMemory` 与 DeepSeek SuperAgent 割裂的问题，结合业界与学术前沿实践完成全面重构：

1. **统一抽象共享记忆层 `MoMoMemory`（`Apps/MacApp/Context/momo_memory.py`）：**
   - 彻底解耦历史 `HermesMemory` / `Vendor/HermesAgent` 依赖，抽象为全系统共用的独立模块 `momo_memory.py`（`MoMoMemory` / `MoMoMemoryStore` / `execute_memory_tool`），保留 `hermes_memory.py` 作为轻量向后兼容重导出。
   - 统一磁盘目录 `<data>/memories/`（并自动与 `<data>/hermes/memories/` 建立双向兼容软链，平滑继承存量记忆）：**DeepSeek SuperAgent 主控（Orchestrator）、后台执行分身（Worker）、闲时 Dream、命令行 `momo-cli`、ContextServer REST 接口及 iPhone/Mac 客户端全部直接读写同一套纯 Markdown 记忆与活页文件**。
2. **UC Berkeley / Letta《Sleep-time Compute: Beyond Inference Scaling at Test-Time》预测性预计算（Anticipatory Pre-computation）：**
   - 闲时算力不仅向后总结，更向前预判：对照今日/明日日程、提醒事项与昨日未闭环讨论，提前组装背景脉络并生成可一键发起对话的晨间建议卡片（`BRIEFING.md`）。
3. **Karpathy LLM Wiki + Obsidian 纯 Markdown（`.md`）活页笔记本：**
   - 零 JSON 产物、零平行数据库：所有持久整理结果全部落盘为 `memories/` 下的纯 Markdown 文件（`USER.md`、`MEMORY.md`、`BRIEFING.md`、`journal/YYYY-MM-DD.md`、`people/<姓名>.md`、`topics/<主题>.md`），由 `MoMoMemory` 统一映射至客户端并支持按条目/文件删除。
4. **Stanford Generative Agents 反思树 + Zep 双时态演进 + Claude Code Auto-Dream：**
   - 闲时冷却缩短至 30 分钟（有新变更即触发）并支持手动一键触发（`POST /v1/memories/dream`）；将相对时间换算为绝对日期，在 `topics/*.md` 中同时保留「当前共识」与「决策演进脉络」。
5. **语义说话人推理与声纹标签回写（`relabel_speakers` / `relabel_recording_speakers`）：**
   - 声学声纹分轨（`[说话人 1]`、`[说话人 2]` 或偶发误判的 `[我]`）可能因环境噪声或未建档而匿名或串轨。Dream 与 DeepSeek SuperAgent Worker 在通读对话时结合称呼、自我介绍、职责分工与既有 `people/*.md` 推理真实说话人身份，调用 `relabel_speakers` / `relabel_recording_speakers` 即时修正 Mac 端转录片段标签（同时在 SuperAgent 主动评估 `ingest_context_sources` 与 `orchestrator_eval` 中实时生效），并通过 `/v1/status` 的 `speaker_relabels` 队列同步回 iPhone 调用 `ArchiveStore.correctSpeakers` 更新本地转录与声纹库。

## 核心改动

- **统一共享记忆层与后端可靠性（`momo_memory.py`、`context_store.py`、`memory_review.py`、`transcript_ingestion.py`、`context_server.py`、`superagent_gateway.py`、`momo_cli.py`）：**
  - `MoMoMemory` 原生支持 `memory` / `user` 核心记忆（`MEMORY.md` 容量上限提升至 3,600 字符）及 `briefing`、`journal`、`person`、`topic` 四类纯 Markdown 活页读写、列表与删除（拒绝原始 JSON 写入）。
  - **修复线上 Dream 停摆 5 天的 4 项根因**：
    1. `SuperAgentGateway` 启动与轮询时自动清理进程重启残留的孤儿 `api_runs`（`status='started'`），并在 `context_server.py` 为 `running` 态任务增加 420 秒超时自动恢复，彻底杜绝单条孤儿任务永久阻塞 `dispatch()` 队列；
    2. 扩容 `MEMORY.md` 并将详尽会议纪要、人物档案分流至 `notebook`（`journal/`、`people/`、`topics/`），消除 2,200 字符溢出导致的连续写入失败；
    3. `_extract_receipt` 与 `_finalize_memory_review_output` 支持从包裹 Markdown/说明文字的模型输出中提取回执，并在工具循环耗尽但已完成真实落盘时自动合成合法回执；
    4. `memory_review.chat_idle()` 兼容检查 `superagent/bridge.sqlite` 并忽略 `waiting_for_input` 或超时挂起状态。
- **DeepSeek SuperAgent 原生打通（`Vendor/SuperAgent/src/app/sessions.ts`、`Vendor/SuperAgent/src/app/tools/momo-pim.ts`、`superagent_gateway.py`）：**
  - `sessions.ts`（`momoMemoryPromptBlock`）在创建 DeepSeek SuperAgent 主会话（`master`）与每个 `worker-*` 会话时，自动将 `USER.md`、`MEMORY.md`、`BRIEFING.md` 及 `people/*.md`、`topics/*.md`、`journal/*.md` 活页索引注入系统提示词。
  - `momo-pim.ts` 为 SuperAgent Worker 注册 4 个一等原生工具：`list_memory_notebooks`、`read_memory_notebook`、`write_memory_notebook`、`relabel_recording_speakers`（共 23 个原生工具）。
- **iPhone 与 Mac 产品界面（`ClientControls.swift`、`PhoneRemoteView.swift`、`RemoteMemoryView.swift`、`DesktopMemory.swift`）：**
  - 恢复并升级首页晨间卡片（`DreamHomeCardsSection` + 6 种原创数学点阵纹样），直接从纯 Markdown `BRIEFING.md` 解析渲染，支持单卡通栏与双卡并列、点击直发对话、长按查看晨间简报全文或暂时收起。
  - iPhone 与 Mac「记忆」页新增分类筛选栏（`全部 / 晨间简报 / 每日日志 / 人物 / 主题 / 核心记忆`）、Markdown 排版阅读器（`MarkdownReadingView`）及「立即 Dream 整理」入口。

## 验证

- Python 单元测试：`Tests/AgentRuntime/test_hermes_memory.py`、`test_memory_review.py`、`test_context.py`、`test_superagent_runtime.py` 共 35 项全部通过。
- SuperAgent Node 单元测试：`Vendor/SuperAgent/tests/momo-pim.spec.ts` 全部通过（23 项原生工具注册与网桥鉴权验证）。
- Swift 编译与集成测试：`MoMoAgent`（iOS）与 `MoMoAgentMac`（macOS）构建及 `DreamBriefingDocument` Markdown 解析回归验证通过。

## 0.5.13 说话人排除与手机回执

子代理收到说话人纠正时，通过 `exclude_recording_speaker` 表达负反馈。单段或多段纠正传同一录音的精确 span ID。用户明确给出时间界限时，传含时区的 `recorded_from`。手机按录音片段的起始时刻执行包含边界的规则，首次分析和后续声纹重算共用这条规则。已知正确身份时仍可用 `relabel_recording_speakers`。

Mac 保存排除指令和回执。手机成功提交声纹修正后才确认投递，重复指令可安全重放。升级时，Mac 如查到旧系统派发过名为「身份待确认」的正向标签，手机会清理对应的非本人声纹档案和训练样本。
