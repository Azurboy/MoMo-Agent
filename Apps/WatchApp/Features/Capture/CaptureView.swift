import SwiftUI
import MoMoContracts
import MoMoRecording

struct CaptureView: View {
    let runtime: WatchRuntime
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .title2) private var scaledControlDiameter: CGFloat = 40
    @ScaledMetric(relativeTo: .caption) private var scaledStatusFontSize: CGFloat = 12
    @State private var presentedSheet: CaptureSheet?
    @State private var diagnosticSessionID: UUID?
    @State private var busy = false
    @State private var actionFailure: String?
    @State private var markConfirmation = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let diameter = min(scaledControlDiameter, max(32, min((geometry.size.width - 28) / 2, geometry.size.height * 0.25)))
                captureContent(diameter: diameter)
                    .padding(.bottom, 4)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .ignoresSafeArea(.container, edges: .horizontal)
            .toolbar {
                // Reserve the leading slot so watchOS centers its own system clock.
                ToolbarItem(placement: .topBarLeading) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { presentedSheet = .more } label: { Image(systemName: "ellipsis") }
                        .tint(MoMoPalette.surface)
                        .foregroundStyle(MoMoPalette.ink)
                        .accessibilityLabel("更多")
                        .accessibilityIdentifier("capture.more")
                }
            }
            .onChange(of: presentedSheet) { runtime.captureMeter.setPresented(presentedSheet == nil) }
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .details: details
                case .more: more
                case .mac: WatchMacConnectionView(runtime: runtime)
                case .diagnostics:
                    if let diagnosticSessionID {
                        CaptureDiagnosticHistoryView(sessionID: diagnosticSessionID, label: diagnosticLabel) {
                            try await runtime.captureDiagnosticHistory(sessionID: diagnosticSessionID)
                        }
                    }
                }
            }
            .alert("操作未完成", isPresented: Binding(get: { actionFailure != nil }, set: { if !$0 { actionFailure = nil } })) {
                Button("知道了", role: .cancel) { actionFailure = nil }
            } message: { Text(actionFailure ?? "") }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await runtime.bootstrap()
            }
            .task(id: markConfirmation) {
                guard markConfirmation else { return }
                do { try await Task.sleep(for: .seconds(2)); markConfirmation = false }
                catch is CancellationError {}
                catch { actionFailure = error.localizedDescription }
            }
            .containerBackground(MoMoPalette.canvas, for: .navigation)
        }
        .foregroundStyle(MoMoPalette.ink)
        .tint(MoMoPalette.ink)
    }

    private var isRecording: Bool { runtime.captureActivity == .recording }
    private var hasActiveSession: Bool {
        (runtime.sessionID != nil && runtime.captureIntent != .stopped) ||
        showsCapacityStop || isRecording || runtime.captureActivity == .starting || runtime.isFinalizingCapture
    }
    private var primaryPresentation: (title: String, icon: String, hint: String) {
        if showsCapacityStop { return (String(localized: "重试录音"), "arrow.clockwise", String(localized: "空间恢复后重新尝试录音，已录下的内容会保留")) }
        switch runtime.captureActivity {
        case .starting:
            return (String(localized: "正在启动"), "mic", String(localized: "正在准备声音采集，请稍候"))
        case .recording:
            return (String(localized: "静音"), "mic", String(localized: "暂停声音采集，已录下的内容会保留"))
        case .failed:
            return (String(localized: "重试录音"), "arrow.clockwise", String(localized: "重新尝试声音采集，已录下的内容会保留"))
        case .idle, .interrupted, .stopped:
            if runtime.captureIntent == .paused {
                return (String(localized: "解除静音"), "mic.slash", String(localized: "恢复本次录音的声音采集"))
            }
            return (String(localized: "继续录音"), "mic", String(localized: "恢复被中断的声音采集，已录下的内容会保留"))
        }
    }
    private var status: String {
        if !runtime.captureReady { return runtime.failure == nil ? String(localized: "正在准备录音") : String(localized: "录音资料未能打开") }
        if runtime.isFinalizingCapture { return String(localized: "正在保存录音") }
        if showsCapacityStop { return runtime.diagnostic?.code == .lowSpace ? String(localized: "空间不足，已停止") : String(localized: "无法检查可用空间") }
        switch runtime.captureActivity {
        case .idle: return runtime.captureIntent == .paused ? String(localized: "已静音") : String(localized: "准备录音")
        case .starting: return String(localized: "正在启动")
        case .recording: return String(localized: "持续录音中")
        case .interrupted: return runtime.requiresStartTap ? String(localized: "准备录音") : String(localized: "录音暂时中断")
        case .stopped: return runtime.captureIntent == .paused ? String(localized: "已静音") : String(localized: "录音已结束")
        case .failed: return String(localized: "录音已停止")
        }
    }

    private var startTitle: String {
        if runtime.isFinalizingCapture { return String(localized: "正在保存录音…") }
        if busy { return String(localized: "正在启动…") }
        if !runtime.captureReady, runtime.failure != nil { return String(localized: "重试准备录音") }
        return String(localized: "轻触以开始")
    }

    private var showsCapacityStop: Bool {
        runtime.sessionID != nil && runtime.captureIntent == .paused &&
        (runtime.diagnostic?.code == .lowSpace || runtime.diagnostic?.code == .capacityUnavailable)
    }

    private func captureContent(diameter: CGFloat) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(isRecording ? Color.red : MoMoPalette.ink.opacity(0.4)).frame(width: 7, height: 7)
                Text(status).font(.system(size: scaledStatusFontSize, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("capture.status")
            .padding(.horizontal, 8)
            ZStack {
                CaptureDots(meter: runtime.captureMeter, isRecording: isRecording)
                    .accessibilityHidden(true)
                if !hasActiveSession {
                    Button {
                        markConfirmation = false
                        perform {
                            if !runtime.captureReady { await runtime.bootstrap() }
                            guard runtime.captureReady else { return }
                            try await runtime.start()
                        }
                    } label: {
                        Text(startTitle)
                            .font(.headline)
                            .padding(10)
                            .background(MoMoPalette.canvas.opacity(0.9), in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("capture.start")
                    .accessibilityHint(runtime.captureReady ? String(localized: "开始或继续使用手表麦克风录音") : String(localized: "重新打开本机录音资料，成功后开始录音"))
                    .disabled(busy || (!runtime.captureReady && runtime.isRecoveringArchive) || runtime.isFinalizingCapture)
                }
            }
            .frame(maxHeight: .infinity)
            if hasActiveSession {
                HStack(alignment: .top, spacing: 12) { controls(diameter: diameter) }
                    .padding(.horizontal, 8)
            }
        }
    }

    @ViewBuilder private func controls(diameter: CGFloat) -> some View {
        control(title: primaryPresentation.title, icon: primaryPresentation.icon, id: "capture.primary", diameter: diameter) {
            if isRecording { try await runtime.pause() }
            else { try await runtime.resume() }
        }
        .accessibilityHint(primaryPresentation.hint)
        .frame(maxWidth: .infinity)
        control(title: markConfirmation ? String(localized: "已标记") : String(localized: "标记"), icon: "flag", id: "capture.mark", diameter: diameter) {
            try await runtime.mark()
            markConfirmation = true
        }
        .disabled(!isRecording)
        .frame(maxWidth: .infinity)
    }

    private func control(title: String, icon: String, id: String, diameter: CGFloat,
                         action: @escaping @MainActor () async throws -> Void) -> some View {
        WatchGlassButton(title: title, systemImage: icon, diameter: diameter) { perform(action) }
            .accessibilityIdentifier(id)
            .disabled(busy || !runtime.captureReady || runtime.captureActivity == .starting || runtime.isFinalizingCapture)
    }

    private var more: some View {
        NavigationStack {
            List {
                if runtime.failure != nil || runtime.syncFailure != nil || runtime.archiveFailure != nil {
                    Button("查看提示") { presentedSheet = .details }
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("capture.showFailure")
                }
                Button("连接 Mac") { presentedSheet = .mac }
                    .accessibilityIdentifier("capture.mac")
                Button("录音信息") { presentedSheet = .details }
                    .accessibilityIdentifier("capture.info")
                Button("采集诊断") {
                    guard let session = runtime.sessionID ?? runtime.diagnostic?.sessionID else { return }
                    diagnosticSessionID = session
                    presentedSheet = .diagnostics
                }
                .disabled(runtime.sessionID == nil && runtime.diagnostic == nil)
                .accessibilityIdentifier("capture.diagnostics")
                Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("capture.build")
            }
            .navigationTitle("更多")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { presentedSheet = nil }
                        .accessibilityIdentifier("capture.more.close")
                }
            }
            .containerBackground(MoMoPalette.canvas, for: .navigation)
        }
        .tint(MoMoPalette.surface)
        .foregroundStyle(MoMoPalette.ink)
    }

    private var details: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if runtime.captureReady && runtime.isRecoveringArchive {
                        Text("后台\(runtime.archiveState.description)，不影响当前录音。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let failure = runtime.failure ?? runtime.archiveFailure ?? runtime.syncFailure {
                        Text(failure).font(.footnote).foregroundStyle(.orange)
                            .accessibilityIdentifier("capture.failure")
                        Button("关闭提示") { runtime.dismissFailure() }
                            .accessibilityIdentifier("capture.failure.dismiss")
                    }
                    if showsCapacityStop {
                        Text("连接接收设备完成同步或腾出空间后，点重试录音。待确认的原音会保留在手表上。")
                            .font(.footnote).foregroundStyle(.orange)
                            .accessibilityIdentifier("capture.capacityStop")
                    }
                    Text("本次录音").font(.headline)
                    Text(Duration.seconds(runtime.elapsedSeconds).formatted(.time(pattern: .hourMinuteSecond)))
                        .font(.system(.title2, design: .monospaced)).monospacedDigit()
                        .accessibilityLabel("本次录音时长")
                        .accessibilityValue(Duration.seconds(runtime.elapsedSeconds).formatted(.units(allowed: [.hours, .minutes, .seconds])))
                        .accessibilityIdentifier("capture.elapsed")
                    if runtime.sessionID != nil && runtime.captureIntent != .stopped {
                        Button("结束录音", role: .destructive) {
                            markConfirmation = false
                            perform {
                                try await runtime.stop()
                                presentedSheet = nil
                            }
                        }
                        .accessibilityIdentifier("capture.stop")
                        .disabled(busy || runtime.isFinalizingCapture)
                    }
                    Text(runtime.macLink.grant == nil ? String(localized: "自动同步到 iPhone") : String(localized: "自动同步到 Mac")).font(.headline)
                    Text(syncDescription)
                        .accessibilityIdentifier("capture.syncState")
                    if runtime.captureActivity == .recording {
                        Text("手表正在本机录音，同步等待不影响录制。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("\(runtime.pendingChunkCount) 个片段等待接收确认")
                        .accessibilityIdentifier("capture.pendingChunks")
                    if queuedFiles > 0 {
                        Text("其中 \(queuedFiles) 个片段在系统传输队列中")
                            .font(.footnote)
                            .accessibilityIdentifier("capture.queuedChunks")
                    }
                    Text("待确认时长 \(Duration.seconds(runtime.pendingDuration).formatted(.time(pattern: .hourMinuteSecond)))")
                    Text("手表会保留原音，直到接收设备确认保存。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !runtime.macLink.ownsRoute, let snapshot = runtime.phoneStatus, case .phone(let status) = snapshot.payload {
                        Text("手机上次报告：\(status.recordingCount) 次录音，\(status.pendingAnalysisCount) 项待处理").font(.footnote)
                        Text(snapshot.sampledAt, format: .dateTime.month().day().hour().minute().second()).font(.caption)
                    }
                    if let diagnostic = runtime.diagnostic {
                        Text("最近采集事件：\(diagnosticLabel(diagnostic.code))").font(.footnote)
                        Text(diagnostic.timestamp, format: .dateTime.hour().minute().second()).font(.caption)
                        if let capacity = diagnostic.capacity {
                            Text("可用 \(capacity.availableBytes.formatted(.byteCount(style: .file)))；本次需预留 \(capacity.budget.requiredBytes.formatted(.byteCount(style: .file)))")
                                .font(.footnote)
                        }
                    }
                    if !runtime.macLink.ownsRoute, runtime.pendingReceiver != nil {
                        Text("手机资料库发生变化。确认后，仍在手表上的片段会传到这个资料库。")
                        Text("已经从手表清理的原音不会自动恢复。").font(.footnote).foregroundStyle(.secondary)
                        Button("使用新的手机资料库") { perform { try await runtime.confirmReceiverChange() } }
                    }
                    Text("录音会自动同步，连接恢复后继续。")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("capture.automaticSync")
                }.padding()
            }
            .navigationTitle("录音信息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { presentedSheet = nil }
                        .accessibilityIdentifier("capture.details.close")
                }
            }
            .containerBackground(MoMoPalette.canvas, for: .navigation)
        }
        .tint(MoMoPalette.surface)
        .foregroundStyle(MoMoPalette.ink)
    }

    private var queuedFiles: Int {
        runtime.macLink.ownsRoute ? runtime.macLink.transferring : runtime.queuedFileCount
    }

    private var syncDescription: String {
        guard runtime.macLink.grant != nil else { return runtime.synchronizationState.description }
        if let problem = runtime.macLink.problem { return problem }
        if runtime.macLink.transferring > 0 { return String(localized: "正在传送到 Mac") }
        return runtime.pendingChunkCount > 0 ? String(localized: "等待 Mac 接收确认") : String(localized: "没有待确认片段")
    }

    private func diagnosticLabel(_ code: CaptureDiagnosticCode) -> String {
        switch code {
        case .started: String(localized: "已启动采集")
        case .paused: String(localized: "已暂停")
        case .stopped: String(localized: "已结束")
        case .lowSpace: String(localized: "空间不足停止")
        case .capacityUnavailable: String(localized: "可用空间读取失败")
        case .systemInterruption: String(localized: "系统中断")
        case .routeChanged: String(localized: "音频路由改变")
        case .mediaServicesReset: String(localized: "音频服务重置")
        case .inputOverflow: String(localized: "采样缓冲已满")
        case .discontinuousInput: String(localized: "采样不连续")
        case .inputStalled: String(localized: "未收到新的采样")
        case .startupFailed: String(localized: "启动失败")
        case .writerFailed: String(localized: "写入失败")
        case .startRequested: String(localized: "请求启动采集")
        case .firstSamples: String(localized: "收到首批采样")
        case .resumeRequested: String(localized: "请求恢复采集")
        case .resumeSucceeded: String(localized: "采集已恢复")
        case .resumeFailed: String(localized: "恢复采集失败")
        case .finalized: String(localized: "采集收尾完成")
        case .cleanupFailed: String(localized: "结束清理失败")
        case .recoveredInterrupted: String(localized: "发现上次中断")
        case .encoderStalled: String(localized: "编码进度停滞")
        case .inputEnded: String(localized: "采样流已结束")
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        actionFailure = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() }
            catch is CancellationError {}
            catch { actionFailure = String(localized: "操作未完成：\(error.localizedDescription)") }
        }
    }

    private enum CaptureSheet: String, Identifiable {
        case details, more, diagnostics, mac
        var id: String { rawValue }
    }
}

private struct WatchMacConnectionView: View {
    let runtime: WatchRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    @State private var error: String?
    @State private var confirmingPhone = false

    var body: some View {
        NavigationStack {
            List {
                if let grant = runtime.macLink.grant {
                    Section("接收录音的 Mac") {
                        Text(grant.origin.host ?? grant.origin.absoluteString)
                        Text("\(runtime.pendingChunkCount) 个片段等待确认")
                        if let problem = runtime.macLink.problem {
                            Text(problem).font(.footnote).foregroundStyle(.orange)
                        }
                        if !runtime.macLink.requiresPairing {
                            Button("现在同步") { runtime.macLink.wake(manually: true) }
                        }
                        Button("改用 iPhone") { confirmingPhone = true }
                    }
                }
                Section {
                    TextField("Mac 的 HTTPS 地址", text: $address)
                        .accessibilityIdentifier("capture.mac.address")
                    SecureField("8 位手表配对码", text: $code)
                        .accessibilityIdentifier("capture.mac.code")
                    if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    Button {
                        Task { @MainActor in
                            error = nil
                            do {
                                try await runtime.connectMac(address: address, code: code)
                                code = ""
                            } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        Text(runtime.macLink.switching ? String(localized: "正在连接…") : String(localized: "配对并同步到 Mac"))
                    }
                    .disabled(runtime.macLink.switching || address.isEmpty || code.utf8.count != 8)
                    .accessibilityIdentifier("capture.mac.pair")
                } header: {
                    Text(runtime.macLink.grant == nil ? String(localized: "配对") : String(localized: "重新配对"))
                } footer: {
                    Text("从 Mac 的网页连接设置获取地址和手表配对码。配对后，待确认的录音会传到这台 Mac，离线时保存在手表上。")
                }
            }
            .onAppear { if address.isEmpty { address = runtime.macLink.grant?.origin.absoluteString ?? "" } }
            .confirmationDialog("改用 iPhone 接收待确认录音？", isPresented: $confirmingPhone) {
                Button("改用 iPhone", role: .destructive) {
                    Task { @MainActor in
                        do { try await runtime.usePhoneReceiver(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .navigationTitle("连接 Mac")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .containerBackground(MoMoPalette.canvas, for: .navigation)
        }
        .tint(MoMoPalette.surface)
        .foregroundStyle(MoMoPalette.ink)
    }
}

private struct CaptureDiagnosticHistoryView: View {
    let sessionID: UUID
    let label: @MainActor (CaptureDiagnosticCode) -> String
    let load: @MainActor () async throws -> [CaptureDiagnostic]
    @Environment(\.dismiss) private var dismiss
    @State private var events: [CaptureDiagnostic]?
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                Text("本机最多保留最近64条事件，这里只显示所选录音的记录。时间差相对此事件计算。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(.orange)
                    Button("重试") { Task { await reload() } }
                        .accessibilityIdentifier("capture.diagnostics.retry")
                } else if let events {
                    if events.isEmpty {
                        Text("这次录音没有保留的诊断记录。")
                            .accessibilityIdentifier("capture.diagnostics.empty")
                    }
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(label(event.code)).font(.headline)
                            Text(event.timestamp, format: .dateTime.year().month().day().hour().minute().second())
                                .font(.caption)
                            Text(event.code.rawValue).font(.caption2).foregroundStyle(.secondary)
                            if let context = event.context {
                                Text("阶段：\(phase(context))").font(.footnote)
                                Text(input(context.builtInMicrophoneSelected)).font(.footnote)
                                if let tap = context.tap {
                                    Text("采样：\(tap.receivedFrames)帧，\(tap.receivedBlocks)次；丢弃\(tap.droppedBlocks)次")
                                        .font(.caption)
                                }
                                Text("最近采样：\(age(context.tap?.lastTapUptime, at: context.uptime))")
                                    .font(.caption)
                                Text("编码进度：\(age(context.encoderProgressObservedAtUptime, at: context.uptime))")
                                    .font(.caption)
                                if let reason = context.routeChangeReason {
                                    Text("音频路由原因：\(reason)").font(.caption)
                                }
                            } else {
                                Text("阶段和输入：旧记录未保存").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("capture.diagnostics.event.\(event.id.uuidString)")
                    }
                    Button("刷新记录") { Task { await reload() } }
                        .disabled(loading).accessibilityIdentifier("capture.diagnostics.refresh")
                } else {
                    ProgressView("正在读取诊断")
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
            .navigationTitle("采集诊断")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.accessibilityIdentifier("capture.diagnostics.close")
                }
            }
            .containerBackground(MoMoPalette.canvas, for: .navigation)
        }
        .tint(MoMoPalette.surface).foregroundStyle(MoMoPalette.ink)
        .task(id: sessionID) { await reload() }
    }

    private func reload() async {
        guard !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let values = try await load()
            try Task.checkCancellation()
            events = values
        } catch is CancellationError {
        } catch { failure = String(localized: "诊断记录暂时无法读取，请重试。") }
    }

    private func phase(_ context: CaptureDiagnosticContext) -> String {
        switch context.activity {
        case .idle: String(localized: "未采集")
        case .starting: String(localized: "正在启动")
        case .recording: String(localized: "正在采集")
        case .interrupted: String(localized: "已中断")
        case .stopped: context.intent == .paused ? String(localized: "已暂停") : String(localized: "已结束")
        case .failed: String(localized: "采集失败")
        }
    }

    private func input(_ builtIn: Bool?) -> String {
        switch builtIn {
        case true: String(localized: "输入：手表麦克风")
        case false: String(localized: "输入：非本机麦克风或不可用")
        case nil: String(localized: "输入：未记录")
        }
    }

    private func age(_ previous: TimeInterval?, at uptime: TimeInterval) -> String {
        guard let previous, previous.isFinite, uptime.isFinite,
              previous >= 0, uptime >= 0, previous <= uptime else { return String(localized: "未记录") }
        return String(localized: "\((uptime - previous).formatted(.number.precision(.fractionLength(1))))秒前")
    }
}

struct CaptureDots: View {
    let meter: CaptureMeter
    let isRecording: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        let animating = visible && isRecording && scenePhase == .active && !reduceMotion
            && meter.history.contains { $0 > 0.02 }
        // Keep the same clock when energy changes; pause it while covered or inactive.
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !animating)) { _ in
            CaptureDotsFrame(history: !isRecording ? [] : animating
                ? meter.displayHistory(at: ProcessInfo.processInfo.systemUptime) : meter.history)
        }
        .onAppear { visible = true; meter.setPresented(true) }
        .onDisappear { visible = false; meter.setPresented(false) }
    }
}

struct CaptureDotsFrame: View {
    let history: [Float]
    private static let columns = CaptureMeter.columns
    private static let rows = 15

    var body: some View {
        Canvas { context, size in
            let horizontalPitch = size.width / Double(Self.columns)
            let verticalPitch = size.height / Double(Self.rows)
            let pitch = min(horizontalPitch, verticalPitch)
            for row in 0..<Self.rows {
                for column in 0..<Self.columns {
                    let x = horizontalPitch * (Double(column) + 0.5)
                    let y = verticalPitch * (Double(row) + 0.5)
                    let strength = history.isEmpty ? 0 : Double(history[column])
                    let envelope = max(0, 1 - abs(Double(row) - 7) / (0.75 + strength * 7))
                    let intensity = strength > 0.02 ? envelope : 0
                    let radius = pitch * (0.085 + intensity * 0.255)
                    context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                                        width: radius * 2, height: radius * 2)),
                                 with: .color(MoMoPalette.ink.opacity(0.16 + intensity * 0.84)))
                }
            }
        }
    }
}

private struct WatchGlassButton: View {
    let title: String
    let systemImage: String
    let diameter: CGFloat
    let action: () -> Void
    @ScaledMetric(relativeTo: .caption2) private var scaledLabelFontSize: CGFloat = 12

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                if #available(watchOS 26, *) {
                    symbol.glassEffect(.regular.tint(MoMoPalette.surface).interactive(), in: .circle)
                } else {
                    symbol.background(MoMoPalette.surface, in: Circle())
                }
                Text(title).font(.system(size: scaledLabelFontSize, weight: .regular))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            // The compact circle and caption share one full-size hit region.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(MoMoPalette.ink)
        .accessibilityLabel(title)
    }

    private var symbol: some View {
        Image(systemName: systemImage)
            .font(.system(size: diameter * 0.5))
            .frame(width: diameter, height: diameter)
    }
}
