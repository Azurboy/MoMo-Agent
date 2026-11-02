import SwiftUI
import MoMoArchive

struct TimelineShareView: View {
    let day: TimelineDay
    let archive: ArchiveStore
    let configurationFingerprint: String?
    @Environment(\.dismiss) private var dismiss
    @State private var customRange = false
    @State private var start: Date
    @State private var end: Date
    @State private var export = ArchiveExportController()

    init(day: TimelineDay, archive: ArchiveStore, configurationFingerprint: String?) {
        self.day = day
        self.archive = archive
        self.configurationFingerprint = configurationFingerprint
        // Seed only when this date's share sheet opens; editing stays local to the sheet.
        _start = State(initialValue: day.date())
        let currentMinute = Calendar.current.dateInterval(of: .minute, for: Date())!.start
        _end = State(initialValue: min(day.adding(days: 1).date(), currentMinute))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("范围", selection: $customRange) {
                        Text("当天").tag(false)
                        Text("自选时间段").tag(true)
                    }.pickerStyle(.segmented)
                        .accessibilityIdentifier("timeline.share.scope")
                    if customRange {
                        DatePicker("开始", selection: $start, displayedComponents: [.date, .hourAndMinute])
                            .accessibilityIdentifier("timeline.share.start")
                        DatePicker("结束", selection: $end, displayedComponents: [.date, .hourAndMinute])
                            .accessibilityIdentifier("timeline.share.end")
                        if start >= end {
                            Text("结束时间需要晚于开始时间。").foregroundStyle(.red)
                        }
                    } else {
                        Text(day.date(), format: .dateTime.year().month().day())
                    }
                } footer: {
                    Text("仅包含分享时已有的文字；按段落起始时间选取，保留完整段落。")
                }
                .disabled(export.busy)

                Section {
                    Button {
                        let scope: TimelineExportScope = customRange ? .interval(DateInterval(start: start, end: end)) : .day(day)
                        export.start(scope: scope, configurationFingerprint: configurationFingerprint, archive: archive)
                    } label: {
                        HStack {
                            Label("分享", systemImage: "square.and.arrow.up")
                            Spacer()
                            if export.preparing { ProgressView() }
                            else { Text(verbatim: "Markdown").foregroundStyle(.secondary) }
                        }
                    }
                    .disabled(export.busy || (customRange && start >= end))
                    .accessibilityIdentifier("timeline.share.confirm")
                    if export.cleanupNeeded {
                        Button("重试清理临时文件") { export.retryCleanup() }
                    }
                }
            }
            .phoneSoftTopEdge()
            .navigationTitle("分享")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { export.cancelPreparation(); dismiss() }
                        .disabled(export.busy && !export.preparing)
                }
            }
            .sheet(item: Binding(get: { export.presented }, set: { if $0 == nil { export.requestPresentationDismissal() } }),
                   onDismiss: { export.presentationDismissed() }) { artifact in
                ArchiveShareSheet(artifact: artifact) { [export] error in
                    export.activityCompleted(id: artifact.id, errorMessage: error)
                }
            }
            .alert("分享未完成", isPresented: Binding(get: { export.failure != nil }, set: { if !$0 { export.failure = nil } })) {
                Button("好", role: .cancel) { export.failure = nil }
            } message: { Text(export.failure ?? "") }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(export.busy)
        .onDisappear { export.cancelPreparation() }
    }
}
