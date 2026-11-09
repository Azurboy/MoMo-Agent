# 手表与手机同步链路整体优化（0.4.10）

## 触发与确认范围

真机连续排空约两千个积压录音分片时，推进约三百六十余个分片后停在时间线 `11.8 22:11` 不再前进，且在此之前呈现一阵传、一阵停的间歇断流。对整条手表—手机同步链路逐层排查后，确认底层 `WCSession.transferFile` 单分片传输本身仅需约 3.8–4.5 秒，卡停与慢速来自两端多处设计失当的游标重置、配额错用、全量历史扫描抢占及通道优先级倒置：

1. **两端发送游标反复归零导致队首阻塞：**
   - 手表侧每当已投递待回执（`.alreadySubmitted`）分片累积到 350 个以上后，抬腕亮屏（`foreground()`）、熄屏直传暂停（`.fileTransportFinished` 错误分支）、对账返回未达分片及退租卡滞副本都会将 `fileCursor` 重置为 `0`，连接激活回调还覆盖了 SQLite 持久化的 `fileTransferPosition()`。
   - 手机侧 `PhoneReceiveCoordinator.submitReceiptPage` 在存在任意待重试控制消息时无条件执行 `if retrying { receiptCursor = 0 }`（尽管紧接着已显式遍历失败队列），导致手机侧新分片回执同样从队首重扫。
2. **活跃录制期间被后台连接唤醒误置入冷启动窄配额（`connectivityGrant`），且可达时仍受 5 分钟分批门限拖延：**
   - 手表持续录音时，每收到一条系统连接后台任务都会进入 `connectivityGrant`，将单轮扫描压到 `4` 个且禁止继续扫描（`reconcileAgain = false`），导致后台文件槽位直接掉到 `outstandingFiles = 0`。
   - `admitAudioBatch` 此前要求同时亮屏或手机打开状态页才立即放行新封口分片，即便两端实时可达也会把新分片扣留最多 5 分钟。
3. **对账请求被全量历史已清理分片与逐条回执确认反客为主：**
   - `RecordingStore.nextReconciliationRequest` 在 24 小时全量历史审计到期或未完成时，即便还有大量 `.ready` 待同步分片，也会强制从 `rowid = 0` 扫描过去 14 天内已确认删除（`removed`）的数千条历史记录，迟迟扫不到当天待确认分片。
   - `WatchRuntime.submitControlBatch` 先按 `RecordingControlKind.allCases` 发送最低优先级的 `ReceiptApplied` 再构造 `ReconcileRequest`，且 `WatchConnectivityTransport` 交互控制并发窗口仅 `4` 条，使手机单次内联回复即可批量确认 16 个分片的快速对账通道长期饥饿。
4. **单轮扫描粒度过碎与直传信道重复传同一文件：**
   - 手表文件扫描每页仅取 `4` 条，且每次检查 `.alreadySubmitted` 分片都重复拉取 `WCSession.outstandingFileTransfers` 快照并执行磁盘 `stat`。
   - `submitAudioBlockCopy` 优先挑选已在 `WCSession.transferFile` 上传中的同一个分片重复占用无线信道，熄屏不可达时还会挂起等待超时；`AudioBlock` 单块仅 `16 KiB`，非末块接收存在多余的临时文件原子替换与两次 `fsync`。

## 整体优化方案与数据边界

1. **双端游标单调推进与大页内存预检：**
   - 手表侧移除 `foreground()`、`.fileTransportFinished` 失败分支、`ReconcileResponse` 未达分片与卡滞退租对 `fileCursor` 的归零；对账明确要求补传的分片按 `chunkID` 直接投递，`WCSession` 激活保留持久化 `fileTransferPosition()` 继续向前推进，仅在扫到队尾时按需回绕一次。
   - 新增 `RecordingStore.pendingChunkPage`（常规 32 条/页）与 `LinkSubmissionState.precheckReservation`，每轮仅刷新一次系统传输快照，内存 O(1) 跳过已投递/退避分片，单轮扫描上限提升至 256 / 512。
   - 手机侧移除 `submitReceiptPage` 中途的 `receiptCursor = 0` 重置，失败回执走独立重试列表，主游标顺序推进新分片回执直至队尾自然回绕。
2. **活跃录制解除冷启动窄配额，可达时零延迟放行新分片：**
   - 保留 `beginConnectivityGrant()` 与 `drainBackgroundConnectivity()` 的冷启动预算保护；`WatchApplicationDelegate.beginDrain()` 仅在非前台且未处于活跃录制/编码时启用 `connectivityGrant`，录制期间与前台直接走完整队列排空；只要 `transport.isReachable` 为真即刻放行新封口分片进入传输队列。
3. **待同步分片优先批量对账与控制通道扩容分级：**
   - `nextReconciliationRequest` 新增 `allowHistoricalAudit` 控制：存在待同步分片（`pendingChunkCount > 0`）时跳过已 `removed` 历史记录并可抢占未完成的空闲全量审计，直指当前 `.ready` 分片；待同步队列清空后再恢复每日全量历史核对。
   - 控制通道交互并发窗口由 `4` 提升至 `16`；手表发送顺序调整为 `ReconcileRequest`（16 分片批量内联对账）→ 删除与录制边界事件（`.deletion` / `.capture`）→ 回执已读确认（`.receipt`）。
4. **后台文件队列与交互式 `AudioBlock` 并行互补：**
   - `submitAudioBlockCopy` 维护独立 `audioBlockCursor`，优先流式发送尚未进入 `transferFile` 的分片，与后台 4 槽文件传输并行推进、互不重传；`sessionReachabilityDidChange` 检测到熄屏不可达时立即结束挂起的 `AudioBlockReplyGate`，保留断点供下次亮屏即时续传。
   - `AudioBlock` 单块负载提升至 `32 KiB`（线长上限 `60 KiB`），`AudioBlockReceive` 非末块顺序追加免除中间 `fsync` 与临时重命名，末块完整保留 `fsync`、全量 SHA-256 校验、收件箱原子入库与持久 `Receipt` 签发，不放宽任何完整性或删除授权条件。

## 验证

- `MoMoContractsTests`、`MoMoLinkTests`、`MoMoRecordingTests`、`AudioBlockReceiveTests` 与 `ReconciliationTests` 串行测试全部通过，新增大积压队列游标推进与待同步优先抢占历史审计回归用例。
- 真机覆盖升级 `0.4.10` 后核对版本、既有资料库完整性、`11.8` 分片越过原停滞点持续增长及后台文件传输槽位饱和度。
