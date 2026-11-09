# 录音、接收和确认的进程强杀回放

此工具验证 J08-a～f 的 Mac 软件部分。Swift 子进程使用生产 AACSegmentWriter、PCM16SegmentWriter、RecordingStore、InboxCustodian 和 ArchiveStore。Python 父进程等待真实边界报告，确认子进程进入 SIGSTOP，再发送 SIGKILL。b / c / d 使用已有 Debug macOS 观察 hook；a / e / f 在正式持久 API 返回处停止，没有新增生产 hook。

| 边界 | 被强杀时的真实状态 | 第一次正常恢复 |
| --- | --- | --- |
| J08-a | 同一真实 AAC writer 已封口 1 秒并入账；另写入 0.25 秒，活动 m4a 尚未 finish / deinit（含同步写入的 `.m4a.pcm` 滚动缓冲）；已持久保存尾部位置的 mark | 沿 WatchRuntime 的 store.recover → CaptureSpool.recover → recoverInterruptedEpochs；旧封口片保持完整，活动尾从 `.m4a.pcm` 重建完整封口 AAC 并校验解码帧数入账；若无 `.m4a.pcm` 且容器不可解码，则保留每个原字节与 draft 到 Repair |
| J08-b | 暂存目录的清单与哈希已同步，音频尚未移动 | 重启后保留为未完成收件，不进入处理队列、不产生确认；全量重传后正常提交 |
| J08-c | 正式原音与旁清单已保存，接收事务尚未开始 | processInbox 校验正式原音，登记原 chunk 和任务，产生确认 |
| J08-d | 接收事务已提交，Inbox 尚未移除 | processInbox 返回同一稳定确认，不重复登记 |
| J08-e | applyReceipt 返回，Receipt 与 ReceiptApplied 已在 Watch 事务内保存，副本尚未删除 | 正常 recover 幂等清理已确认副本，控制消息身份不变，手机仍等待 ReceiptApplied |
| J08-f | cleanupAcknowledgedChunks 返回，Watch 原音已清理，ReceiptApplied 尚未交付手机 | 控制记录仍可补发，手机收到前不自动过期，收到后允许满足其他条件的原音过期 |

b / c / d 随后再启两个新进程。第一个执行重复投递、两次 Receipt、两次 ReceiptApplied 和原音清理。第二个从正常入口恢复并重放持久 ReceiptApplied。独立 Python 检查器使用只读 SQLite 连接，核对文件 SHA-256、WAV 帧数和 PCM 哈希、不可变清单、两端身份、任务数量、确认身份、完整性与外键。

a 在强杀后、恢复后和再次重开时以系统 `afconvert` 独立解码 AAC，核对完整帧数和 PCM hash；解码输出只写到证据文件，不修改原容器。未封口 m4a 若存在 `.m4a.pcm` 滚动缓冲，真实恢复入口会据此重建封口 AAC 并核对解码帧数、清理临时缓冲；若缺乏 `.m4a.pcm` 且无法解码，则隔离原文件与 draft 到 Repair，不建立虚假尾片。已持久 mark 和中断事件同时说明“观测到的位置”和“已封口的位置”；第二次恢复必须复用原事件 ID。

e / f 在强杀进程中通过正式 AnalysisTicket / commitTranscript 提交**合成空稿**，仅用于使 job=complete、无活动读取者、回放边界已满足等过期条件成立，不声称执行过 ASR。重启进程先调用 expireAudio，证明缺 ReceiptApplied 时原音仍在；补发两次相同确认后，另一个新进程执行过期，独立检查器确认音频才被删除。检查器不补写数据库、清理文件或制造业务状态。

J08-b 的暂存目录在重启后改名为 `.incomplete`，保留清单和哈希，等待手表重传。它不进入 `processInbox`，重传成功后也不会再次产生确认。检查器分别记录待处理条目和保留的半成品数量。原临时投递文件也保留在证据目录，不能当成 Watch 已确认的副本清理。

## 运行

完整 Xcode 环境下，在仓库根目录执行。本工具使用独立 scratch、jobs=1；同一 scratch 同时只能由一个构建任务占用。本工具必须使用 Debug / macOS，观察 hook 不进入 iPhone、Watch 或 Release。

```sh
swift build --package-path Tools/CrashRecoveryReplay \
  --scratch-path tmp_agent_output/crash-build -c debug --jobs 1 --product CrashRecoveryReplay

# 用当前 SwiftPM 输出目录确定二进制位置。
swift build --package-path Tools/CrashRecoveryReplay \
  --scratch-path tmp_agent_output/crash-build -c debug --show-bin-path

uv run --no-project --offline python Tools/CrashRecoveryReplay/run.py \
  --executable /absolute/build/output/CrashRecoveryReplay \
  --output /absolute/tmp_agent_output/new-crash-run

# 正反例检查器自检只修改临时副本，不修改上述验收证据。
uv run --no-project --offline python Tools/CrashRecoveryReplay/test-run.py \
  --evidence /absolute/tmp_agent_output/new-crash-run -v
```

输出目录必须不存在。默认创建六套独立的小档案；可重复提供 `--case J08-a` 等选项选择子例，不允许重复同一个 case。不读取用户数据库，不调用 API，不自动清理结果。父进程只对本次创建的子进程发信号。任一边界未到达、退出信号错误、恢复失败或检查不一致，命令返回非零，`summary.json` 保留失败信息。

证据包括每个阶段的 stdout / stderr、真实 PID 与信号、清单、原音、SQLite、强杀后及恢复/重开后的只读快照。完成条件是全部选中子例通过，并且 SIGKILL、恢复和最后重开来自不同进程。

本工具使用合成 PCM 输入：a 经真实 AAC 编码，其他五例沿用 2 秒 WAV。不执行 ASR。Mac 进程强杀不能替代 Watch 系统终止、断电、设备重启或真实 WC 临时文件生命周期。完整故障矩阵仍按 E2E 方案执行；每次结果以独立输出目录的 summary.json 为准，不覆盖旧 b / c / d 或失败证据。
