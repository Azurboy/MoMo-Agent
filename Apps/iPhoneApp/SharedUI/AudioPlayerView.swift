import SwiftUI
import UIKit
import MoMoArchive

/// All three presentations observe the runtime's one player. A preview never starts playback.
struct AudioPlayerCard: View {
    let playback: AudioPlaybackController
    let target: AudioPlaybackTarget
    let playLabel: String
    let actionIdentifier: String
    var unavailableReason: String? = nil
    var failureIdentifier: String? = nil
    var disabled = false
    @State private var preview: AudioPlaybackSnapshot?
    @State private var failure: String?
    @State private var changing = false
    @State private var operation = UUID()
    @State private var seekPreview: Double?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var active: AudioPlaybackSnapshot? { playback.snapshot?.target == target ? playback.snapshot : nil }
    private var display: AudioPlaybackSnapshot? { active ?? (preview?.target == target ? preview : nil) }
    private var playing: Bool { active != nil ? playback.playbackRequested : changing && seekPreview == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TranscriptAudioCardSurface {
                HStack(alignment: .center, spacing: 16) {
                    PlaybackToggleButton(playing: playing, loading: changing || active?.state == .loading,
                                         label: playing ? String(localized: "暂停回听") : active?.state == .paused ? String(localized: "继续回听") : playLabel,
                                         size: 52, identifier: actionIdentifier) { toggle() }
                        .disabled(disabled || unavailableReason != nil)
                    PlaybackWaveform(snapshot: display, identifier: actionIdentifier + ".seek",
                                     disabled: disabled || unavailableReason != nil,
                                     reading: unavailableReason == nil && failure == nil && !disabled,
                                     previewPosition: $seekPreview, seek: seek)
                        .frame(height: dynamicTypeSize.isAccessibilitySize ? 64 : 52)
                }
            } times: {
                PlaybackTimes(position: seekPreview ?? display?.position ?? 0, duration: display?.duration)
            }
            if let reason = unavailableReason ?? failure ?? (active != nil ? playback.failure : nil) {
                Text(reason).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    .accessibilityIdentifier(failureIdentifier ?? actionIdentifier + ".failure")
            }
        }
        .task(id: PreviewIdentity(target: target, unavailable: unavailableReason, disabled: disabled, active: active != nil)) {
            preview = nil; failure = nil
            guard unavailableReason == nil, !disabled, active == nil else { return }
            do {
                let value = try await playback.preview(for: target) { metadata in
                    if !Task.isCancelled { preview = metadata }
                }
                try Task.checkCancellation()
                guard value.target == target else { return }
                preview = value
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled {
                    preview?.waveform = []; preview?.waveformProgress = nil
                    failure = String(localized: "暂时无法读取原音，请检查音频是否已收到或已清理。")
                }
            }
        }
        .onChange(of: target) { operation = UUID(); changing = false; seekPreview = nil }
    }

    private func toggle() {
        let expectedTarget = target
        let wasPlaying = playing
        let wasActive = active != nil
        let attempt = UUID()
        operation = attempt
        changing = true; failure = nil
        Task {
            defer { if operation == attempt { changing = false; seekPreview = nil } }
            do {
                guard operation == attempt else { return }
                if wasPlaying { await playback.pause() }
                else if wasActive {
                    guard playback.snapshot?.target == expectedTarget else { return }
                    try await playback.resume()
                } else {
                    let position = seekPreview.flatMap { $0 < (display?.duration ?? 0) ? $0 : nil }
                    try await playback.play(expectedTarget, from: position)
                }
            } catch is CancellationError { }
            catch {
                if operation == attempt { failure = String(localized: "原音暂时无法播放，请检查可回听范围后重试。") }
            }
        }
    }

    private func seek(_ position: Double) {
        guard !disabled, unavailableReason == nil, display?.canSeek == true else { return }
        let expectedTarget = target
        let attempt = UUID()
        operation = attempt
        seekPreview = position
        changing = true; failure = nil
        Task {
            defer { if operation == attempt { changing = false; seekPreview = nil } }
            do {
                guard operation == attempt else { return }
                try await playback.seek(to: position, in: expectedTarget)
            }
            catch is CancellationError { }
            catch {
                if operation == attempt { failure = String(localized: "这个位置暂时无法回听，已保留最近可用的播放位置。") }
            }
        }
    }

    private struct PreviewIdentity: Equatable {
        let target: AudioPlaybackTarget
        let unavailable: String?
        let disabled: Bool
        let active: Bool
    }
}

struct AudioMiniPlayer: View {
    let playback: AudioPlaybackController
    let openRecording: (UUID) -> Void
    var openWindow: ((TimelineWindowID) -> Void)? = nil
    @State private var changing = false
    @State private var failure: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let snapshot = playback.snapshot {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    PlaybackToggleButton(playing: snapshot.state == .playing, loading: changing || snapshot.state == .loading,
                                         label: snapshot.state == .playing ? String(localized: "暂停回听") : snapshot.state == .ended ? String(localized: "重新回听") : String(localized: "继续回听"), size: 36,
                                         identifier: "playback.mini.toggle") {
                        changing = true; failure = nil
                        Task {
                            defer { changing = false }
                            do {
                                guard playback.snapshot?.target == snapshot.target else { return }
                                if snapshot.state == .playing { await playback.pause() }
                                else { try await playback.resume() }
                            } catch is CancellationError { }
                            catch {
                                if playback.snapshot?.target == snapshot.target {
                                    failure = String(localized: "原音暂时无法继续播放，请打开录音检查。")
                                }
                            }
                        }
                    }.disabled(changing || snapshot.state == .loading)
                    Button {
                        if let id = snapshot.target.windowID, let openWindow { openWindow(id) }
                        else { openRecording(snapshot.target.sessionID) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(snapshot.target.windowID.map { "\(TimelineDate.day($0.day)) · \(TimelineDate.range($0, end: snapshot.target.windowEnd ?? $0.start))" }
                                    ?? snapshot.recordedAt.map(RecordingDatePresentation.title) ?? String(localized: "原音回听"))
                                    .phoneText(.history)
                                if snapshot.target.source != nil {
                                    Text("片段").phoneText(.caption).foregroundStyle(MoMoPalette.muted)
                                }
                            }
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            PlaybackWaveformDrawing(snapshot: snapshot, position: snapshot.position)
                                .frame(height: 26).accessibilityHidden(true)
                            PlaybackTimes(position: snapshot.position, duration: snapshot.duration)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("打开正在回听的录音")
                    .accessibilityIdentifier("playback.mini.open")
                    Button {
                        Task {
                            guard playback.snapshot?.target == snapshot.target else { return }
                            await playback.stop()
                        }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 16))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(MoMoPalette.muted)
                    .accessibilityLabel("结束回听并收起播放器")
                    .accessibilityIdentifier("playback.mini.close")
                }
                if let reason = failure ?? playback.failure {
                    Text(reason).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 10).frame(minHeight: 88, alignment: .top)
            .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 22))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("playback.mini")
            .onChange(of: snapshot.target) { failure = nil }
        }
    }
}

private struct PlaybackWaveform: View {
    let snapshot: AudioPlaybackSnapshot?
    let identifier: String
    let disabled: Bool
    let reading: Bool
    @Binding var previewPosition: Double?
    let seek: (Double) -> Void

    private var canSeek: Bool {
        !disabled && snapshot?.canSeek == true && snapshot?.duration.map { $0.isFinite && $0 > 0 } == true
    }
    private var position: Double { previewPosition ?? snapshot?.position ?? 0 }
    private var rangeLabel: String {
        if snapshot?.target.source != nil { String(localized: "引用片段") } else { String(localized: "整段原音") }
    }

    var body: some View {
        ZStack {
            PlaybackWaveformDrawing(snapshot: snapshot, position: position, reading: reading)
                .allowsHitTesting(false).accessibilityHidden(true)
            PlaybackSeekInput(snapshot: snapshot, enabled: canSeek, identifier: identifier,
                label: canSeek ? String(localized: "\(rangeLabel)播放进度") : String(localized: "\(rangeLabel)波形"),
                previewPosition: $previewPosition, seek: seek)
        }
        .frame(minHeight: 44)
        .onChange(of: snapshot?.target) { previewPosition = nil }
        .onChange(of: canSeek) { if !canSeek { previewPosition = nil } }
    }
}

/// UIKit arbitrates the horizontal scrub before claiming a touch from the enclosing vertical scroll view.
private struct PlaybackSeekInput: UIViewRepresentable {
    let snapshot: AudioPlaybackSnapshot?
    let enabled: Bool
    let identifier: String
    let label: String
    @Binding var previewPosition: Double?
    let seek: (Double) -> Void

    func makeUIView(context: Context) -> PlaybackSeekControl { PlaybackSeekControl(frame: .zero) }

    func updateUIView(_ control: PlaybackSeekControl, context: Context) {
        if control.playbackTarget != snapshot?.target || control.isEnabled != enabled {
            control.resetInteraction()
        }
        control.playbackTarget = snapshot?.target
        control.duration = snapshot?.duration ?? 0
        control.isEnabled = enabled
        control.pan.isEnabled = enabled
        control.tap.isEnabled = enabled
        control.accessibilityIdentifier = identifier
        control.accessibilityLabel = label
        control.accessibilityValue = "\(PlaybackTime.text(previewPosition ?? snapshot?.position ?? 0))，共 \(PlaybackTime.text(snapshot?.duration))"
        control.accessibilityHint = enabled ? String(localized: "向上或向下调整播放位置") : String(localized: "当前范围暂不支持定位")
        control.accessibilityTraits = enabled ? [.adjustable] : [.adjustable, .notEnabled]
        control.preview = { previewPosition = $0 }
        control.commit = seek
        control.adjust = { forward in
            guard var value = snapshot else { return }
            value.position = previewPosition ?? value.position
            if let position = value.adjustedSeekPosition(forward: forward) { seek(position) }
        }
    }
}

private final class PlaybackSeekControl: UIView, UIGestureRecognizerDelegate {
    var isEnabled = true
    var playbackTarget: AudioPlaybackTarget?
    var duration = 0.0
    var preview: ((Double?) -> Void)?
    var commit: ((Double) -> Void)?
    var adjust: ((Bool) -> Void)?
    private var dragDuration: Double?
    private var resetting = false
    lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        pan.delegate = self
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
        tap.require(toFail: pan)
    }

    required init?(coder: NSCoder) { return nil }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled, duration.isFinite, duration > 0 else { return false }
        guard gestureRecognizer === pan else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    func resetInteraction() {
        resetting = true
        pan.isEnabled = false; tap.isEnabled = false
        dragDuration = nil
        resetting = false
    }

    private func position(at point: CGPoint, duration: Double) -> Double {
        min(1, max(0, Double(point.x / max(1, bounds.width)))) * duration
    }

    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        guard !resetting, isEnabled else { return }
        switch recognizer.state {
        case .began, .changed:
            if dragDuration == nil { dragDuration = duration }
            preview?(position(at: recognizer.location(in: self), duration: dragDuration ?? duration))
        case .ended:
            let selected = position(at: recognizer.location(in: self), duration: dragDuration ?? duration)
            dragDuration = nil
            commit?(selected)
        case .cancelled, .failed:
            let wasDragging = dragDuration != nil
            dragDuration = nil
            if wasDragging { preview?(nil) }
        default: break
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard isEnabled, recognizer.state == .ended else { return }
        commit?(position(at: recognizer.location(in: self), duration: duration))
    }

    override func accessibilityIncrement() { if isEnabled { adjust?(true) } }
    override func accessibilityDecrement() { if isEnabled { adjust?(false) } }
}

private struct PlaybackWaveformDrawing: View {
    let snapshot: AudioPlaybackSnapshot?
    let position: Double
    var reading = true

    var body: some View {
        if let snapshot, !snapshot.waveform.isEmpty {
            Canvas { context, size in
                let count = max(1, Int(size.width / 4)), mid = size.height / 2
                let duration = snapshot.duration ?? 0
                for column in 0..<count {
                    let fraction = Double(column) / Double(max(1, count - 1))
                    let at = fraction * duration
                    if let through = snapshot.waveformLoadedThrough, at > through { continue }
                    if snapshot.gaps.contains(where: { $0.contains(at) }) { continue }
                    let lower = column * snapshot.waveform.count / count
                    let upper = max(lower + 1, (column + 1) * snapshot.waveform.count / count)
                    let amplitude = snapshot.waveform[lower..<min(snapshot.waveform.count, upper)].max() ?? 0
                    let height = CGFloat(sqrt(max(0, min(1, amplitude)))) * min(16, mid)
                    let x = CGFloat(fraction) * max(0, size.width - 2) + 1
                    for row in -4...4 where abs(CGFloat(row) * 4) <= max(0, height) {
                        let dot = CGRect(x: x - 0.8, y: mid + CGFloat(row) * 4 - 0.8, width: 1.6, height: 1.6)
                        context.fill(Path(ellipseIn: dot), with: .color(at <= position ? MoMoPalette.ink : MoMoPalette.muted.opacity(0.5)))
                    }
                }
                if duration > 0 {
                    let x = CGFloat(min(1, max(0, position / duration))) * size.width
                    context.fill(Path(roundedRect: CGRect(x: x - 0.8, y: max(0, mid - 20), width: 1.6, height: min(40, size.height)), cornerRadius: 0.8), with: .color(MoMoPalette.ink))
                    context.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: mid - 3.5, width: 7, height: 7)), with: .color(MoMoPalette.ink))
                }
            }
        } else {
            PlaybackEmptyWaveform()
        }
    }
}
