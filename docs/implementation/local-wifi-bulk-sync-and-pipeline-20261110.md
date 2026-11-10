# 同步通道深度去阻与局域网高速补传（0.4.11）

## 背景与确认瓶颈

`0.4.10` 修复了游标重置与熄屏队列跌零问题后，实测双端亮屏速率稳定在约 `28–34` 倍实时（约 `95–116 KB/s`），手机锁屏后则因系统酌情调度断续挂起，处理大跨度积压仍显缓慢。逐层拆解后确认剩余两类核心瓶颈：

1. **现有 `WatchConnectivity` 管道与手机入库层的 5 处软件开销：**
   - **逐分片同步重写跨天 `manifest.json` 锁住 `ArchiveStore`：** `PhoneReceiveCoordinator` 在单分片连续到达及 `AudioBlock` 提交时频繁同步等待 `PhoneRuntime.archiveChanged()`，每次都触发 `projectRecordingManifest` 全量解码近 4,000 个分片元数据并重写数 MB `manifest.json`（含磁盘读取对比与 `fsync`），直接阻塞 `AudioBlock` 切片写入与收件箱入库。
   - **`AudioBlock` JSON Base64 膨胀与首块空探针往返：** 原实现将二进制音频装入 JSON Base64 发送，膨胀约 `33%`，且每个新分片固定先发一次 0 字节 `probe` 多耗费一次蓝牙 RTT，每次切片还重复开关文件句柄。
   - **后台文件槽位过少（`4` 槽不足 `1 MB`）：** 2 个槽位常处于 `100%` 等待系统回调清理状态，在途总字节数低于 `watchconnectivityd` 升档点对点 Wi-Fi（AWDL）的体积阈值；且 `submitAudioBlockCopy` 先于 `submitFileBatch` 执行会产生首分片双通道重复投递。
   - **大批量单条 `Receipt` 挤占交互通道：** 手机存在数千条未确认回执时，仍走 `WCSession.sendMessage` 逐条下发并每条重复拉取系统控制队列快照，与手表上行 `AudioBlock` 发生 `WCErrorDomain 7007` 碰撞。
2. **`WatchConnectivity` 默认锁定低功耗蓝牙（BLE）的物理带宽上限：**
   - 蓝牙连通期间 `WCSession` 应用层吞吐上限仅约 `100–150 KB/s`；要实现每秒数十个分片的高速排空，必须在同网段可用时唤醒直连 Wi-Fi / 局域网 TCP 流式传输。

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

## 验证

- `MoMoContractsTests`、`MoMoLinkTests`、`AudioBlockReceiveTests`、`ArchiveStatusTests`、`LocalSyncIntegrationTests`、`ReconciliationTests` 与 `MoMoRecordingTests` 全部通过（含二进制 `AudioBlock` 免探针、真实 TCP 双模式并发上传、错误令牌 `401` 拦截与回执批量核销测试）。
- 真机覆盖升级 `0.4.11` 后核对双端版本、既有资料库保留率与实时排空吞吐。
