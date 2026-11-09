# 手表队列游标持续推进与同步吞吐优化（0.4.10）

## 触发与确认范围

真机连续排空约两千个积压录音分片时，推进约三百六十余个分片后停在时间线 `11.8 22:11` 不再前进，且在此之前呈现一阵传、一阵停的间歇断流。现场队列、能耗与文件传输账本诊断确认底层 `WCSession.transferFile` 单分片传输本身仅需约 3.8–4.5 秒，卡停与慢速来自应用层游标重置和活跃录制下的错误节流：

1. **队首已投递待回执分片累积后，`fileCursor` 反复归零导致永远扫不到新分片：** 已通过 `transferFile` 送达但尚在等待持久 `Receipt` 回执的 `.alreadySubmitted` 分片累积到 350 个以上后，手表每次抬腕进入 `foreground()`、熄屏导致直传暂停（`.fileTransportFinished` 错误分支）、对账返回未达分片或退租卡滞副本时都会将 `fileCursor` 重置为 `0`，连激活回调也覆盖了 SQLite 持久化的 `fileTransferPosition()`。
2. **活跃录制期间被后台连接唤醒误置入冷启动窄配额（`connectivityGrant`）：** 手表正在持续录音时，每收到一条系统连接后台任务都会通过 `WatchApplicationDelegate.beginDrain()` 进入 `connectivityGrant`，将单轮文件扫描上限压到 `4` 个且禁止继续扫描（`reconcileAgain = false`）。一旦队首 `.alreadySubmitted` 分片超过 4 个，后台文件队列立即掉到 `outstandingFiles = 0`；即便抬腕亮屏按每轮 32 个从 `0` 重扫，也需要连续 12 轮对账才能越过前 361 个分片，往往在 15 秒熄屏前又被重置回 `0`。
3. **扫描路径、对账顺序与直传选片存在重复开销：**
   - `transferFileResult` 在每次扫描已投递分片时都先拉取 `WCSession.outstandingFileTransfers` 快照并执行磁盘 `fileExists` 检查，大队列扫描在主线程产生数百次重复 IPC 与 `stat`。
   - `submitControlBatch` 先发送 `receiptApplied` 再构造 `ReconcileRequest`，占满 4 个交互控制槽位后跳过对账请求，使手机端单次消息即可批量确认 16 个分片的内联对账通道长期饥饿。
   - `submitAudioBlockCopy` 优先挑选已在 `WCSession.transferFile` 传输中的同一个分片重复占用无线信道，且熄屏不可达时未立即结束挂起的 `AudioBlock` 等待门闩；`AudioBlock` 单块负载仅 16 KiB，非末块接收还包含多余的临时文件原子替换与两次 `fsync`。
   - 手机端单条 `Receipt` 发送暂败时将 `receiptCursor` 归零，放大队首阻塞。

## 修改与数据边界

1. **保持 `fileCursor` 单调推进并恢复跨重启游标：**
   - 移除 `foreground()`、`.fileTransportFinished` 失败分支、`ReconcileResponse` 未达分片与卡滞退租对 `fileCursor` 的归零重置；对账明确要求补传的分片按 `chunkID` 直接优先投递，不再回退主扫描游标。
   - `WCSession` 激活时保留 SQLite 中持久化的 `fileTransferPosition()` 直接续传后续新分片，仅标记一次队尾回绕检查以兜底重启前未投递的早期分片。
   - 新增 `LinkSubmissionState.precheckReservation`，在 `submitFileBatch` 每轮只刷新一次系统队列快照，内存 O(1) 跳过 `.alreadySubmitted` / `.retryLater` 分片，单轮扫描窗口提升至 256（受限唤醒）/ 512（常规运行）。
2. **区分冷启动窄唤醒与活跃录制/前台同步：**
   - 保留 `beginConnectivityGrant()` 与 `drainBackgroundConnectivity()` 的全部冷启动预算语义；`WatchApplicationDelegate.beginDrain()` 仅在非前台且未处于活跃录制/编码时启用 `connectivityGrant`，录制期间与前台直接走完整队列排空并在亮屏或开录时立即退出残留窄配额。
3. **对账优先、双通道不重传与单块吞吐提升：**
   - `WatchRuntime.submitControlBatch` 优先提交 `ReconcileRequest`（可达时每 30 秒允许新一轮批量对账，后台维持 15 分钟），利用手机内联回复快速批量结清已入库分片回执；手机端移除单条回执暂败时的 `receiptCursor = 0` 重置。
   - `submitAudioBlockCopy` 维护独立 `audioBlockCursor`，优先传输尚未进入 `transferFile` 的待传分片，与后台 4 槽文件传输真正并行互补；`sessionReachabilityDidChange` 检测到不可达时立即结束挂起的 `AudioBlockReplyGate`，保留断点供下次亮屏即时续传。
   - `AudioBlock` 单块负载提升至 `32 KiB`（线长上限 `60 KiB`，仍低于 WatchConnectivity 单消息限制）；`AudioBlockReceive` 非末块仅顺序追加并校验偏移，末块完整保留 `fsync`、全量 SHA-256 校验、收件箱原子入库与持久 `Receipt` 签发，不放宽任何完整性或删除授权条件。

## 验证

- `MoMoContractsTests`、`MoMoLinkTests`、`MoMoRecordingTests`、`AudioBlockReceiveTests` 与 `ReconciliationTests` 串行测试全部通过，新增 420 分片队列跳过 380 个待回执队首分片的游标与预检回归用例。
- 真机覆盖升级 `0.4.10` 后核对版本、既有资料库完整性、`11.8` 分片越过原停滞点持续增长及后台文件传输槽位饱和度。
