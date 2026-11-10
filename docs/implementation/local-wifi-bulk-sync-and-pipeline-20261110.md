# 同步通道深度去阻、局域网高速补传与后台自动转录恢复（0.4.11）

## 背景与确认问题

1. **`WatchConnectivity` 管道与手机入库层的 5 处软件开销：**
   - **逐分片同步重写跨天 `manifest.json` 锁住 `ArchiveStore`：** `PhoneReceiveCoordinator` 在单分片连续到达及 `AudioBlock` 提交时频繁同步等待 `PhoneRuntime.archiveChanged()`，每次都触发 `projectRecordingManifest` 全量解码近 4,000 个分片元数据并重写数 MB `manifest.json`（含磁盘读取对比与 `fsync`），直接阻塞 `AudioBlock` 切片写入与收件箱入库。
   - **`AudioBlock` JSON Base64 膨胀与首块空探针往返：** 原实现将二进制音频装入 JSON Base64 发送，膨胀约 `33%`，且每个新分片固定先发一次 0 字节 `probe` 多耗费一次蓝牙 RTT，每次切片还重复开关文件句柄。
   - **后台文件槽位过少（`4` 槽不足 `1 MB`）：** 2 个槽位常处于 `100%` 等待系统回调清理状态，在途总字节数低于 `watchconnectivityd` 升档点对点 Wi-Fi（AWDL）的体积阈值；且 `submitAudioBlockCopy` 先于 `submitFileBatch` 执行会产生首分片双通道重复投递。
   - **大批量单条 `Receipt` 挤占交互通道：** 手机存在数千条未确认回执时，仍走 `WCSession.sendMessage` 逐条下发并每条重复拉取系统控制队列快照，与手表上行 `AudioBlock` 发生 `WCErrorDomain 7007` 碰撞。
2. **`WatchConnectivity` 默认锁定低功耗蓝牙（BLE）的物理带宽上限：**
   - 蓝牙连通期间 `WCSession` 应用层吞吐上限仅约 `100–150 KB/s`；要实现每秒数十个分片的高速排空，必须在同网段可用时唤醒直连 Wi-Fi / 局域网 TCP 流式传输。
3. **后台已接收音频长时间停滞不转录（`后台又不转录了`）的 4 处闭环阻断：**
   - **跨天连续 Epoch 被挂起批次占用时，后台收件转录首阶段空转且次阶段门槛过高：** 手表连续多天录音属于同一未关闭 `epochID`；一旦曾发起过“后台继续整理”并进入 `.paused`（`systemEndedUnknown`），`batchReservesAnalysis` 会保留整个 `epochID`，导致 `ReceivedAudioTranscription` 首阶段 `startBackgroundAutomatic` 无可领工作（且此前还在有限后台配额内执行无上限历史声纹提取 `extractPendingVoiceprintSeedsIfNeeded`），而 `followUp` 又要求 `backgroundTimeRemaining >= 16s`，在常规 20–28s 后台收件唤醒中直接跳过批次恢复。
   - **有限配额（`finiteBudget`）主动收尾时静默丢失并发到达通知：** `TranscriptionCoordinator.drain()` 在 `remaining < 15s` 时以 `.backgroundExpired` 主动干净收尾（甚至仅跑完一次 150ms VAD、`transcribed == 0` 就提前退出），此时 `success == false` 且 `expirationReason == nil`，`ReceivedAudioTranscription` 既未走 `success && receivedWhileRunning` 分支，也未走系统过期分支，导致运行期间新到达的所有分片唤醒被静默丢弃。
   - **未启动的排队申请长期阻塞后台收件与批次恢复：** `PhoneRuntime.audioReceived` 因 `!hasTranscriptionContinuation` 在 `requestedTranscriptionBatchID != nil`（系统 `.queue` 尚未拉起或已静默丢弃）期间完全屏蔽 `receivedAudioTranscription`，且 `reconcilePendingContinuedBatch` 此前仅在前台触发；`AutomaticBackgroundSubmission` 一旦在内存置 `pending = true` 便不再周期复核系统队列。
   - **切入后台延续切片未接管挂起批次：** `leavingForeground()` 与 `background()` 在存在可恢复挂起批次但尚未进入前台 `execution` 时不会启动或恢复批次，切入后台瞬间即挂起为 `systemSuspended`。

## 实施方案与安全边界

### 1. 现有通道深度优化
- **手机端收件与磁盘投射解耦：**
  - `PhoneReceiveCoordinator` 引入非阻塞合并通知（`scheduleCoalescedChanged`），`AudioBlock` 与高速直传提交不再阻塞收件主循环；`Documents.projectRecordingManifest` 先核对文件长度再按需读取比对，`PhoneRuntime.refresh` 在高频连续入库期立即刷新时间线内存状态、将重型 `manifest.json` 全量落盘合并为 10 秒窗口投射。
  - `WatchConnectivityTransport.refreshControlQueue` 按页单次刷新系统控制快照；待发回执超过 `4` 条时自动改走后台队列，让出全部交互通道带宽给上行音频与 16 分片内联对账；`confirmFileDelivery` 仅在确实存在在途系统文件传输时才访问 `WCSession` 快照。
- **`WatchConnectivity` 音频管道扩容与二进制直传：**
  - `WatchConnectivityTransport` 文件并发窗口提升至 `LinkSubmissionState.bulkMaximumOutstandingFiles = 12`（约 `2.5 MB` 在途缓冲），消除回调间隙并触发系统底层高速链路升档；手表调整为先填满后台文件槽位再挑选未入队分片进入 `AudioBlock`，消除重复上传。
  - `AudioBlock` 新增二进制字典帧（`audio_block_header` + 原始 `Data` `audio_block_payload`，单块提升至 `44 KiB`，保留旧版 JSON 帧兼容），新分片跳过 0 字节首探针并在内存一次性切片，单分片交互往返次数减半。

### 2. 局域网 Wi-Fi 高速补传通道（`LocalSyncServer` / `LocalSyncClient`）
- **手机端 `LocalSyncServer`：**
  - 基于 `NWListener` 在本地随机端口监听 HTTP/1.1 Keep-Alive 连接，每次启动生成 256 位随机 `Bearer` 令牌（常量时间比对），通过已配对认证的 `PhoneArchiveStatus.localSync` 下发局域网地址与令牌；`NWPathMonitor` 监听网口变化自动刷新状态。
  - `POST /v1/chunks` 接收原始二进制音频流与 `ManifestEnvelope`，复用 `ArchiveStore.receiveDirectChunk` 执行完全一致的协议校验、全量 `SHA-256` 校验、音频格式检查、收件箱原子入库及持久 `Receipt` 签发；`POST /v1/receipts-applied` 在单事务内批量确认最多 `128` 条 `ReceiptApplied`。
- **手表端 `LocalSyncClient` 与无缝回退：**
  - 优先尝试绑定 `requiredInterfaceType = .wifi` 的原生 TCP 连接池（在录音会话激活期按 TN3135 直接唤醒手表 Wi-Fi 绕过蓝牙代理），不可用时自动切换 `URLSession` Keep-Alive 4 并发上传池；若设备不在同一局域网，2.5 秒探针超时后静默冷却并继续由优化后的 `WatchConnectivity` 传输，不丢分片、不放宽任何删除授权条件。

### 3. 后台自动转录与批次恢复闭环修复
- **收件即转与挂起批次优先接管：**
  - `ReceivedAudioTranscription` 首阶段对齐 `BGProcessingTask`：无未保留实时高优音频时直接恢复系统挂起批次（`resumeSystemEndedBatchForBackgroundProcessing`），不再空跑首阶段或被 16s 门槛拦截；次阶段接力阈值收紧至 `10s`。
  - 修复 `ReceivedAudioTranscription` 主动收尾（`.backgroundExpired`）与系统任务切换期间（`systemTaskActive`）的到达事件续接：释放旧后台任务后若仍有可用后台时间（`> 12s`）立即申请新切片继续转录，配额耗尽则干净释放避免空转。
- **有限后台预算全额留给 VAD + ASR：**
  - `TranscriptionCoordinator.drain()` 在有限后台任务期间跳过耗时的历史声纹种子提取；尚未产出转录窗口（仅完成毫秒级 VAD）时保留至 `< 6s` 才收尾，产出窗口后在 `< 10s` 干净收尾，单次后台唤醒可多完成数倍转录窗口。
- **消除排队死锁与切后台断流：**
  - `PhoneRuntime.audioReceived` 仅在实际系统后台任务运行期让路；`PhoneBackgroundTasks.reconcileOrReleaseStalledPendingContinuedBatch` 在后台自动清理被系统丢弃或超 `60s` 未拉起的排队请求；`AutomaticBackgroundSubmission` 每 `60s` 允许重新核对系统 `BGTaskScheduler` 队列；后台冷启动与前台切后台均自动衔接可恢复批次继续转录。

## 验证

- `MoMoContractsTests`、`MoMoLinkTests`、`AudioBlockReceiveTests`、`ArchiveStatusTests`、`LocalSyncIntegrationTests`、`ReconciliationTests`、`MoMoRecordingTests` 以及 `BackgroundGrantLifecycleTests`、`AutomaticBackgroundSubmissionTests`、`ContinuedBackgroundSubmissionTests`、`TranscriptionBatchIntegrationTests` 全部通过。
- 真机覆盖升级 `0.4.11` 后核对双端版本、既有资料库保留率、高速同步吞吐与后台自动转录推进。
