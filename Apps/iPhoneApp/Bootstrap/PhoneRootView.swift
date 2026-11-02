import SwiftUI
import MoMoArchive

private enum PhoneTab: Hashable { case chat, transcripts }

struct PhoneRootView: View {
    let runtime: PhoneRuntime
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: PhoneTab = .chat
    @State private var showingSettings = false

    var body: some View {
        Group {
            if runtime.remoteAgent.setupStep == .welcome {
                WelcomeExperienceView(finishTitle: "开始配对", finish: { runtime.remoteAgent.advanceSetup(.connect) })
            } else if runtime.remoteAgent.setupStep == .connect {
                PhoneConnectionFlow(agent: runtime.remoteAgent, finish: { runtime.remoteAgent.advanceSetup(.completed) }, deferConnection: {
                    selectedTab = .transcripts; runtime.remoteAgent.advanceSetup(.deferred)
                })
            } else { mainTabs }
        }
        .onChange(of: runtime.remoteAgent.notifications.navigationRevision) { _, _ in
            showingSettings = false; selectedTab = .chat
        }
        .onChange(of: selectedTab) { _, _ in updateChatVisibility() }
        .onChange(of: showingSettings) { _, _ in updateChatVisibility() }
        .onChange(of: scenePhase) { _, _ in updateChatVisibility() }
        .task {
            if runtime.remoteAgent.notifications.route.pending != nil { selectedTab = .chat; showingSettings = false }
            updateChatVisibility()
            if scenePhase == .active { await runtime.foreground() } else { await runtime.start() }
        }
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            Tab(String(localized: "聊天"), systemImage: "bubble.left.and.bubble.right", value: .chat) {
                NavigationStack {
                    PhoneRemoteView(agent: runtime.remoteAgent, openSettings: { showingSettings = true },
                        watchStatus: runtime.library.watchStatus, requestWatchStatus: runtime.requestWatchStatus,
                        openLibrary: { selectedTab = .transcripts }, speech: runtime.speech,
                        stopPlayback: { await runtime.playback.stop(deactivateImmediately: true) },
                        chatIsVisible: selectedTab == .chat && !showingSettings)
                        .recordingSourceLinks(archive: runtime.archive, playback: runtime.playback)
                }
            }
            Tab(String(localized: "转录"), systemImage: "doc.text", value: .transcripts) {
                NavigationStack {
                    LibraryView(model: runtime.library, playback: runtime.playback,
                        transcription: runtime.transcriptionSnapshot, speechFailure: runtime.speechFailure,
                        batches: runtime.activeBatches,
                        delete: { try await runtime.delete(sessionID: $0) },
                        refresh: { await runtime.refresh() }, canDiscuss: runtime.remoteAgent.store != nil,
                        discuss: { discuss([$0]) }, openSettings: { showingSettings = true },
                        retryTranscription: { try await runtime.retryTranscription(sessionID: $0, expectedGeneration: $1) },
                        discussSources: discuss,
                        retryTimeline: { try await runtime.retryTimeline($0) },
                        continueInBackground: runtime.supportsTranscriptionContinuation
                            ? { try await runtime.continueTranscriptionInBackground() } : nil,
                        hasBackgroundContinuation: runtime.hasTranscriptionContinuation,
                        requestWatchStatus: runtime.requestWatchStatus,
                        onSpeakersChanged: { await runtime.didCommitTargetedSpeakerFeedback() },
                        resolveFiles: { try await runtime.resolveFiles($0, choosing: $1) })
                }
            }
        }
        .tint(MoMoPalette.ink)
        .phonePageSurface()
        // Status surfaces switch between the watch and the earphone without threading it through every view.
        .environment(runtime.earphone)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(archive: runtime.archive, remoteAgent: runtime.remoteAgent,
                    modelDirectory: runtime.modelDirectory, modelStatus: runtime.modelStatus,
                    speechSettings: runtime.speechSettings, earphone: runtime.earphone,
                    speakerRematch: runtime.speakerRematch,
                    onSpeakersChanged: { await runtime.didMutateSpeakers() })
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingSettings = false } } }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let failure = runtime.failure ?? runtime.refreshFailure ?? runtime.syncFailure ?? runtime.statusFailure ?? runtime.library.speakerFeedbackFailure {
                HStack {
                    Text(failure).font(.footnote).accessibilityIdentifier("app.failure")
                    Button("关闭", action: runtime.dismissFailure).accessibilityIdentifier("app.failure.dismiss")
                }.padding(12).background(.regularMaterial)
            }
        }
    }

    private func updateChatVisibility() {
        runtime.remoteAgent.notifications.chatVisible = selectedTab == .chat && !showingSettings && scenePhase == .active
    }

    private func discuss(_ sources: [SourceReference]) {
        selectedTab = .chat
        Task {
            let resolved = await runtime.prepareSourcesForDiscussion(sources)
            runtime.remoteAgent.selectSources(resolved)
        }
    }
}
