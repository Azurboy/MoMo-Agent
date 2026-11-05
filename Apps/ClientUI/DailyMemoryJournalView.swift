import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import MoMoContracts
import Observation
import SQLite3
import SwiftUI
import UniformTypeIdentifiers
#if canImport(ImagePlayground)
import ImagePlayground
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - On-Device FoundationModels Distillation

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct OnDeviceJournalBriefIdea {
    @Guide(description: "4 to 12 Chinese characters warm cute daily memory handbook title, optionally weaving in the place name")
    var headline: String

    @Guide(description: "One warm, grounded, cute Chinese sentence (18 to 44 characters) reflecting on this time slot's recorded moments and place")
    var note: String

    @Guide(description: "2 to 4 short concrete topic tags in Chinese or English from the transcript")
    var tags: [String]

    @Guide(description: "3 concrete English kawaii picture-book scene phrases featuring tiny chubby round marshmallow mascot creature pals, cozy miniature props, pastel watercolor wash; strictly NO humans, human faces, or portraits")
    var sceneConcepts: [String]

    @Guide(description: "Mood palette key: morningAmber, studioSage, breezeSky, twilightApricot, or lampNight")
    var palette: String
}
#endif

enum DailyJournalOnDeviceDistiller {
    static func distill(from input: DailyJournalInput, style: DailyJournalStyleChoice) async -> DailyJournalBrief {
        let base = DailyJournalConceptExtractor.extract(from: input, style: style)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let transcriptSnippet = input.segments
                .prefix(8)
                .map { "[\(String(format: "%02d:00", $0.hour))] \($0.text.prefix(260))" }
                .joined(separator: "\n")
            if !transcriptSnippet.isEmpty {
                do {
                    let styleGuide = style == .chiikawa
                        ? "画面采用吉伊卡哇（Chiikawa）式的治愈软萌手绘绘本风：奶白圆润小团子吉祥物、粉扑扑腮红、棕色手绘细线、淡彩水彩晕染与迷你生活道具。"
                        : "画面采用温暖治愈的手绘生活手账插画风格。"
                    let instructions = """
                    你是温暖可爱的小管家 Momo，正在把用户这一时段的录音与所在地点提炼成一页「分时段记忆手账」插画卡。
                    忠于真实谈话内容与地点，不编造事实；标题灵动温暖，一句话手记温和治愈。
                    \(styleGuide)
                    sceneConcepts 必须是英文短语，严禁包含任何人类、人像、人脸词汇（person/portrait/face）。
                    """
                    let placeLine = input.placeLabel.map { "\n所在地点：\($0)" } ?? ""
                    let session = LanguageModelSession(instructions: instructions)
                    let generated = try await session.respond(
                        to: "时间：\(input.dateLabel)\(placeLine)\n片段：\n\(transcriptSnippet)",
                        generating: OnDeviceJournalBriefIdea.self
                    ).content
                    let resolvedPalette = DailyJournalPalette(rawValue: generated.palette) ?? base.palette
                    let sanitizedConcepts = DailyJournalConceptExtractor.sanitizeSceneConcepts(
                        generated.sceneConcepts,
                        fallbackPalette: resolvedPalette,
                        style: style
                    )
                    var cleanTags: [String] = []
                    if let place = base.placeLabel, !place.isEmpty {
                        cleanTags.append("📍\(place)")
                    }
                    for tag in generated.tags {
                        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty, !cleanTags.contains(trimmed) {
                            cleanTags.append(trimmed)
                        }
                    }
                    return DailyJournalBrief(
                        headline: generated.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? base.headline
                            : String(generated.headline.trimmingCharacters(in: .whitespacesAndNewlines).prefix(18)),
                        note: generated.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? base.note
                            : String(generated.note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(68)),
                        tags: cleanTags.isEmpty ? base.tags : Array(cleanTags.prefix(4)),
                        sceneConcepts: sanitizedConcepts,
                        safeExtractionSummary: sanitizedConcepts.joined(separator: ", "),
                        palette: resolvedPalette,
                        motifs: base.motifs,
                        placeLabel: base.placeLabel,
                        distilledByOnDeviceLLM: true
                    )
                } catch {
                    return base
                }
            }
        }
        #endif
        return base
    }
}

// MARK: - Cross-Platform Location & Visit Provider

@MainActor @Observable
final class DailyJournalLocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = DailyJournalLocationProvider()

    private(set) var visits: [DailyJournalPlaceVisit] = []
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var isSamplingLocation = false
    private(set) var latestPlaceLabel: String?
    private(set) var statusHint: String?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let geocoder = CLGeocoder()
    @ObservationIgnored private let placeStore = DailyJournalPlaceStore()
    @ObservationIgnored private var lastSampledAt: Date = .distantPast
    @ObservationIgnored private var pendingAuthSample = false

    override init() {
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
        reloadStoredVisits()
    }

    var isAuthorized: Bool {
        #if os(macOS)
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorized
        #else
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
        #endif
    }

    func reloadStoredVisits(macDataDirectory: URL? = nil) {
        var mergedByID: [String: DailyJournalPlaceVisit] = [:]
        for item in placeStore.load() {
            mergedByID[item.id] = item
        }
        for item in Self.readPhoneVisitsJSON() {
            mergedByID[item.id] = item
        }
        if let macDataDirectory {
            for item in Self.readMacSyncedVisitsSQLite(dataDirectory: macDataDirectory) {
                mergedByID[item.id] = item
            }
        }
        let sorted = mergedByID.values.sorted { $0.startTimestamp < $1.startTimestamp }
        if sorted != visits {
            visits = sorted
        }
        latestPlaceLabel = sorted.last(where: { !$0.shortLabel.isEmpty })?.shortLabel
    }

    func refreshIfAuthorized(force: Bool = false) {
        authorizationStatus = manager.authorizationStatus
        guard isAuthorized else { return }
        guard force || Date().timeIntervalSince(lastSampledAt) >= 1_200 else { return }
        guard !isSamplingLocation else { return }
        isSamplingLocation = true
        lastSampledAt = Date()
        manager.requestLocation()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.isSamplingLocation == true {
                self?.isSamplingLocation = false
            }
        }
    }

    func requestAuthorizationOrRefresh() {
        statusHint = nil
        authorizationStatus = manager.authorizationStatus
        if isAuthorized {
            refreshIfAuthorized(force: true)
            return
        }
        switch authorizationStatus {
        case .notDetermined:
            pendingAuthSample = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            statusHint = String(localized: "定位权限未开启，可在系统设置中允许位置访问后自动关联手账地点。")
        default:
            refreshIfAuthorized(force: true)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorizationStatus = status
            if self.pendingAuthSample && self.isAuthorized {
                self.pendingAuthSample = false
                self.refreshIfAuthorized(force: true)
            } else if self.pendingAuthSample && (status == .denied || status == .restricted) {
                self.pendingAuthSample = false
                self.statusHint = String(localized: "定位权限未开启，手账会继续从对话场景中推断地点。")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        let lat = latest.coordinate.latitude
        let lon = latest.coordinate.longitude
        let ts = latest.timestamp.timeIntervalSince1970
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isSamplingLocation = false }
            await self.reverseGeocodeAndSave(latitude: lat, longitude: lon, timestamp: ts)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSamplingLocation = false
        }
    }

    private func reverseGeocodeAndSave(latitude: Double, longitude: Double, timestamp: Double) async {
        guard latitude.isFinite, longitude.isFinite else { return }
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude))
            guard let place = placemarks.first else { return }
            let parts = [place.locality, place.subLocality, place.areasOfInterest?.first ?? place.name]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var deduped: [String] = []
            for p in parts where !deduped.contains(p) {
                deduped.append(p)
            }
            let fullName = deduped.joined(separator: " ")
            guard !fullName.isEmpty else { return }
            let bucketHour = Int(floor(timestamp / 3_600.0))
            let visit = DailyJournalPlaceVisit(
                id: "live-\(bucketHour)",
                name: fullName,
                startTimestamp: timestamp - 900,
                endTimestamp: timestamp + 3_600,
                latitude: latitude,
                longitude: longitude,
                isLiveLocation: true
            )
            try? placeStore.upsert(visit)
            reloadStoredVisits()
            statusHint = nil
        } catch {
            // Keep existing visits if offline reverse-geocoding fails.
        }
    }

    private struct RawPhoneVisitRecord: Decodable {
        let id: String
        let title: String?
        let start: Double?
        let end: Double?
        let latitude: Double?
        let longitude: Double?
    }

    private static func readPhoneVisitsJSON() -> [DailyJournalPlaceVisit] {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }
        let candidates = [
            support.appendingPathComponent("MoMoAgent/MacAgent/phone-visits.json"),
            support.deletingLastPathComponent().appendingPathComponent("Application Support/MoMoAgent/MacAgent/phone-visits.json")
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let records = try? JSONDecoder().decode([RawPhoneVisitRecord].self, from: data) else {
                continue
            }
            return records.compactMap { rec in
                guard let title = rec.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty,
                      let ts = rec.start ?? rec.end else {
                    return nil
                }
                return DailyJournalPlaceVisit(
                    id: "visit-\(rec.id)",
                    name: title,
                    startTimestamp: ts,
                    endTimestamp: rec.end,
                    latitude: rec.latitude,
                    longitude: rec.longitude,
                    isLiveLocation: true
                )
            }
        }
        return []
    }

    private struct SyncedSnapshotPayload: Decodable {
        let records: [RawPhoneVisitRecord]?
    }

    private static func readMacSyncedVisitsSQLite(dataDirectory: URL) -> [DailyJournalPlaceVisit] {
        let dbURL = dataDirectory.appendingPathComponent("context/context.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT payload FROM phone_source_snapshots WHERE kind = 'visits'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [DailyJournalPlaceVisit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let jsonText = String(cString: cStr)
            guard let payload = try? JSONDecoder().decode(SyncedSnapshotPayload.self, from: Data(jsonText.utf8)),
                  let records = payload.records else {
                continue
            }
            for rec in records {
                guard let title = rec.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty,
                      let ts = rec.start ?? rec.end else {
                    continue
                }
                results.append(
                    DailyJournalPlaceVisit(
                        id: "mac-visit-\(rec.id)",
                        name: title,
                        startTimestamp: ts,
                        endTimestamp: rec.end,
                        latitude: rec.latitude,
                        longitude: rec.longitude,
                        isLiveLocation: true
                    )
                )
            }
        }
        return results
    }
}

// MARK: - Cross-Platform CGImage PNG Helpers

enum DailyJournalImageCodec {
    static func encodePNG(_ cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func decodeCGImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: - Coordinator (N-Hour Chapters + Periodic Generation + ImagePlayground)

enum DailyJournalCreatorCapability: Equatable, Sendable {
    case unknown
    case available
    case unavailableOnDevice
}

@MainActor @Observable
final class DailyMemoryJournalCoordinator {
    static let shared = DailyMemoryJournalCoordinator()

    var interval: DailyJournalIntervalOption = DailyJournalIntervalOption.current() {
        didSet {
            if oldValue != interval {
                DailyJournalIntervalOption.setCurrent(interval)
            }
        }
    }

    private(set) var covers: [String: LoadedCover] = [:]
    private(set) var generatingKeys: Set<String> = []
    private(set) var creatorCapability: DailyJournalCreatorCapability = .unknown
    private(set) var lastNotice: String?
    @ObservationIgnored private let store = DailyJournalCoverStore()

    struct LoadedCover: Equatable {
        var metadata: DailyJournalStoredCover
        var cgImage: CGImage?

        static func == (lhs: LoadedCover, rhs: LoadedCover) -> Bool {
            lhs.metadata == rhs.metadata && (lhs.cgImage != nil) == (rhs.cgImage != nil)
        }
    }

    private func cacheKey(dayKey: String, style: DailyJournalStyleChoice) -> String {
        "\(dayKey)|\(style.rawValue)"
    }

    func chapters(for dayInput: DailyJournalInput, visits: [DailyJournalPlaceVisit]) -> [DailyJournalChapter] {
        DailyJournalChapterBuilder.buildChapters(
            from: dayInput,
            interval: interval,
            visits: visits
        )
    }

    func currentCover(for input: DailyJournalInput, style: DailyJournalStyleChoice = .chiikawa) -> LoadedCover {
        let key = cacheKey(dayKey: input.dayKey, style: style)
        if let mem = covers[key], mem.metadata.isFresh(for: input) {
            return mem
        }
        if let disk = store.load(dayKey: input.dayKey, style: style), disk.metadata.isFresh(for: input) {
            let loaded = LoadedCover(
                metadata: disk.metadata,
                cgImage: disk.imageData.flatMap(DailyJournalImageCodec.decodeCGImage)
            )
            covers[key] = loaded
            return loaded
        }
        let existingVariation = covers[key]?.metadata.variationIndex ?? 0
        let fallbackBrief = DailyJournalConceptExtractor.extract(from: input, style: style)
        return LoadedCover(
            metadata: DailyJournalStoredCover(
                dayKey: input.dayKey,
                fingerprint: input.fingerprint,
                style: style,
                source: .proceduralHandDrawn,
                brief: fallbackBrief,
                variationIndex: existingVariation
            ),
            cgImage: nil
        )
    }

    func isGenerating(dayKey: String, style: DailyJournalStyleChoice) -> Bool {
        generatingKeys.contains(cacheKey(dayKey: dayKey, style: style))
    }

    func prepareChaptersIfNeeded(
        _ chapters: [DailyJournalChapter],
        style: DailyJournalStyleChoice = .chiikawa
    ) async {
        for chapter in chapters {
            if Task.isCancelled { return }
            await prepareIfNeeded(for: chapter.chapterInput, style: style)
        }
    }

    func prepareIfNeeded(for input: DailyJournalInput, style: DailyJournalStyleChoice = .chiikawa) async {
        guard input.hasReadableContent else { return }
        let key = cacheKey(dayKey: input.dayKey, style: style)
        if let existing = covers[key] ?? loadIntoMemory(dayKey: input.dayKey, style: style),
           existing.metadata.isFresh(for: input) {
            return
        }
        await generate(for: input, style: style, advanceVariation: false)
    }

    func regenerate(for input: DailyJournalInput, style: DailyJournalStyleChoice) async {
        await generate(for: input, style: style, advanceVariation: true)
    }

    func applyPlaygroundSheetImage(
        from url: URL,
        for input: DailyJournalInput,
        style: DailyJournalStyleChoice
    ) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let rawData = try? Data(contentsOf: url),
              let cgImage = DailyJournalImageCodec.decodeCGImage(rawData),
              let pngData = DailyJournalImageCodec.encodePNG(cgImage) else {
            lastNotice = String(localized: "未能读取图乐园生成的插画，请重试。")
            return
        }
        let current = currentCover(for: input, style: style)
        let updated = DailyJournalStoredCover(
            dayKey: input.dayKey,
            fingerprint: input.fingerprint,
            style: style,
            source: .appleImagePlaygroundSheet,
            brief: current.metadata.brief,
            variationIndex: current.metadata.variationIndex
        )
        try? store.save(metadata: updated, pngData: pngData)
        covers[cacheKey(dayKey: input.dayKey, style: style)] = LoadedCover(metadata: updated, cgImage: cgImage)
        creatorCapability = .available
        lastNotice = nil
    }

    private func loadIntoMemory(dayKey: String, style: DailyJournalStyleChoice) -> LoadedCover? {
        guard let disk = store.load(dayKey: dayKey, style: style) else { return nil }
        let loaded = LoadedCover(
            metadata: disk.metadata,
            cgImage: disk.imageData.flatMap(DailyJournalImageCodec.decodeCGImage)
        )
        covers[cacheKey(dayKey: dayKey, style: style)] = loaded
        return loaded
    }

    private func generate(
        for input: DailyJournalInput,
        style: DailyJournalStyleChoice,
        advanceVariation: Bool
    ) async {
        let key = cacheKey(dayKey: input.dayKey, style: style)
        guard !generatingKeys.contains(key) else { return }
        generatingKeys.insert(key)
        defer { generatingKeys.remove(key) }
        lastNotice = nil

        let previous = covers[key] ?? loadIntoMemory(dayKey: input.dayKey, style: style)
        let baseVariation = previous?.metadata.variationIndex ?? 0
        let nextVariation = advanceVariation ? (baseVariation + 1) : baseVariation
        let brief = await DailyJournalOnDeviceDistiller.distill(from: input, style: style)

        if creatorCapability != .unavailableOnDevice,
           let cgImage = await tryGenerateWithImageCreator(brief: brief, style: style),
           let pngData = DailyJournalImageCodec.encodePNG(cgImage) {
            let stored = DailyJournalStoredCover(
                dayKey: input.dayKey,
                fingerprint: input.fingerprint,
                style: style,
                source: .appleImageCreator,
                brief: brief,
                variationIndex: nextVariation
            )
            try? store.save(metadata: stored, pngData: pngData)
            covers[key] = LoadedCover(metadata: stored, cgImage: cgImage)
            creatorCapability = .available
            return
        }

        let stored = DailyJournalStoredCover(
            dayKey: input.dayKey,
            fingerprint: input.fingerprint,
            style: style,
            source: .proceduralHandDrawn,
            brief: brief,
            variationIndex: nextVariation
        )
        try? store.save(metadata: stored, pngData: nil)
        covers[key] = LoadedCover(metadata: stored, cgImage: nil)
    }

    private func tryGenerateWithImageCreator(
        brief: DailyJournalBrief,
        style: DailyJournalStyleChoice
    ) async -> CGImage? {
        #if canImport(ImagePlayground)
        if #available(iOS 18.4, macOS 15.4, *) {
            do {
                let creator = try await ImageCreator()
                let desired: ImagePlaygroundStyle = switch style {
                case .chiikawa, .illustration: .illustration
                case .sketch: .sketch
                case .animation: .animation
                }
                let resolvedStyle = creator.availableStyles.contains(desired)
                    ? desired
                    : (creator.availableStyles.first ?? .illustration)
                var primaryConcepts: [ImagePlaygroundConcept] = [
                    .extracted(from: brief.safeExtractionSummary, title: brief.headline)
                ]
                primaryConcepts.append(contentsOf: brief.sceneConcepts.map { .text($0) })
                do {
                    for try await created in creator.images(for: primaryConcepts, style: resolvedStyle, limit: 1) {
                        return created.cgImage
                    }
                } catch let error as ImageCreator.Error {
                    if #available(iOS 26.0, macOS 26.0, *), error == .conceptsRequirePersonIdentity {
                        let pureScene = brief.sceneConcepts.map { ImagePlaygroundConcept.text($0) }
                        for try await created in creator.images(for: pureScene, style: resolvedStyle, limit: 1) {
                            return created.cgImage
                        }
                    } else {
                        throw error
                    }
                }
            } catch let error as ImageCreator.Error {
                switch error {
                case .notSupported, .unavailable:
                    creatorCapability = .unavailableOnDevice
                case .backgroundCreationForbidden:
                    lastNotice = String(localized: "回到前台后可生成 Apple 图乐园插画。")
                default:
                    break
                }
            } catch {
                creatorCapability = .unavailableOnDevice
            }
        } else {
            creatorCapability = .unavailableOnDevice
        }
        #else
        creatorCapability = .unavailableOnDevice
        #endif
        return nil
    }
}

// MARK: - Compact Timeline Journal Banner (Shared iPhone & Mac)

struct DailyMemoryJournalBanner: View {
    let input: DailyJournalInput
    let openSheet: () -> Void
    var macDataDirectory: URL? = nil
    var coordinator: DailyMemoryJournalCoordinator = .shared
    var locationProvider: DailyJournalLocationProvider = .shared

    var body: some View {
        let chapters = coordinator.chapters(for: input, visits: locationProvider.visits)
        let activeChapter = chapters.last
        let targetInput = activeChapter?.chapterInput ?? input
        let cover = coordinator.currentCover(for: targetInput, style: .chiikawa)
        let brief = cover.metadata.brief
        let slotBadge: String = {
            if chapters.count > 1, let ch = activeChapter {
                return "\(ch.timeRangeLabel) · 共\(chapters.count)幅"
            } else if let ch = activeChapter, coordinator.interval != .fullDay {
                return "\(ch.timeRangeLabel) · \(coordinator.interval.shortTitle)"
            }
            return String(localized: "吉伊记忆手账")
        }()

        Button(action: openSheet) {
            HStack(spacing: 14) {
                DailyJournalArtworkFrame(
                    input: targetInput,
                    cover: cover,
                    cornerRadius: 12
                )
                .frame(width: 86, height: 68)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: cover.cgImage != nil ? "apple.image.playground" : "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(paletteAccent(brief.palette))
                        Text(slotBadge)
                            .phoneText(.caption)
                            .foregroundStyle(MoMoPalette.muted)
                            .lineLimit(1)
                        if let place = activeChapter?.place?.shortLabel ?? brief.placeLabel, !place.isEmpty {
                            Text("📍\(place)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(paletteAccent(brief.palette))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(MoMoPalette.muted)
                    }
                    Text(brief.headline)
                        .phoneText(.menu)
                        .fontWeight(.medium)
                        .foregroundStyle(MoMoPalette.ink)
                        .lineLimit(1)
                    Text(brief.note)
                        .phoneText(.caption)
                        .foregroundStyle(MoMoPalette.muted)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(MoMoPalette.line, lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("每日记忆手账，\(brief.headline)，\(brief.note)")
        .accessibilityIdentifier("timeline.journal.card")
        .task(id: "\(input.fingerprint)|\(coordinator.interval.rawValue)") {
            locationProvider.reloadStoredVisits(macDataDirectory: macDataDirectory)
            locationProvider.refreshIfAuthorized()
            let currentChapters = coordinator.chapters(for: input, visits: locationProvider.visits)
            await coordinator.prepareChaptersIfNeeded(currentChapters, style: .chiikawa)
            // Periodically check while mounted so crossing into a new N-hour window refreshes location & generates the new illustration automatically.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { break }
                locationProvider.reloadStoredVisits(macDataDirectory: macDataDirectory)
                locationProvider.refreshIfAuthorized()
                let updatedChapters = coordinator.chapters(for: input, visits: locationProvider.visits)
                await coordinator.prepareChaptersIfNeeded(updatedChapters, style: .chiikawa)
            }
        }
    }
}

// MARK: - Full Interactive Journal Sheet (Multi-Chapter + Location + Chiikawa Strip)

struct DailyMemoryJournalSheet: View {
    let input: DailyJournalInput
    var macDataDirectory: URL? = nil
    @Bindable var coordinator: DailyMemoryJournalCoordinator = .shared
    var locationProvider: DailyJournalLocationProvider = .shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var selectedStyle: DailyJournalStyleChoice = .chiikawa
    @State private var selectedChapterID: String?
    @State private var comicStripMode = false
    @State private var showingPlaygroundSheet = false
    @State private var sharePNG: DailyJournalExportPNG?

    var body: some View {
        let chapters = coordinator.chapters(for: input, visits: locationProvider.visits)
        let activeChapter = chapters.first(where: { $0.id == selectedChapterID }) ?? chapters.last
        let activeInput = activeChapter?.chapterInput ?? input
        let activeCover = coordinator.currentCover(for: activeInput, style: selectedStyle)
        let generating = coordinator.isGenerating(dayKey: activeInput.dayKey, style: selectedStyle)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    chapterAndModeHeader(chapters: chapters, activeChapter: activeChapter)

                    if comicStripMode && chapters.count > 1 {
                        DailyJournalComicStripView(
                            dayDateLabel: input.dateLabel,
                            interval: coordinator.interval,
                            chapters: chapters,
                            style: selectedStyle,
                            coordinator: coordinator
                        )
                    } else {
                        DailyJournalPostcardView(
                            input: activeInput,
                            cover: activeCover,
                            place: activeChapter?.place,
                            timeSlotLabel: activeChapter?.timeRangeLabel,
                            isGenerating: generating
                        )
                    }

                    styleIntervalAndLocationControls(
                        activeInput: activeInput,
                        activeChapter: activeChapter,
                        cover: activeCover,
                        isGenerating: generating
                    )

                    capabilityFootnote(cover: activeCover)
                }
                .padding(20)
            }
            .background(MoMoPalette.canvas)
            .navigationTitle("每日记忆手账")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("timeline.journal.close")
                }
                if let sharePNG {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(
                            item: sharePNG,
                            preview: SharePreview("\(input.dateLabel) · \(activeCover.metadata.brief.headline)", image: sharePNG.image)
                        ) {
                            Label("分享手账", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("timeline.journal.share")
                    }
                }
            }
        }
        .modifier(
            ImagePlaygroundSheetModifier(
                isPresented: $showingPlaygroundSheet,
                brief: activeCover.metadata.brief,
                existingCGImage: activeCover.cgImage,
                onCreated: { url in
                    Task {
                        await coordinator.applyPlaygroundSheetImage(
                            from: url,
                            for: activeInput,
                            style: selectedStyle
                        )
                        refreshShareSnapshot(chapters: chapters, activeChapter: activeChapter)
                    }
                }
            )
        )
        .task(id: "\(input.fingerprint)|\(selectedStyle.rawValue)|\(coordinator.interval.rawValue)|\(locationProvider.visits.count)") {
            locationProvider.reloadStoredVisits(macDataDirectory: macDataDirectory)
            locationProvider.refreshIfAuthorized()
            let updatedChapters = coordinator.chapters(for: input, visits: locationProvider.visits)
            if selectedChapterID == nil || !updatedChapters.contains(where: { $0.id == selectedChapterID }) {
                selectedChapterID = updatedChapters.last?.id
            }
            await coordinator.prepareChaptersIfNeeded(updatedChapters, style: selectedStyle)
            let resolvedActive = updatedChapters.first(where: { $0.id == selectedChapterID }) ?? updatedChapters.last
            refreshShareSnapshot(chapters: updatedChapters, activeChapter: resolvedActive)
        }
        .onChange(of: selectedChapterID) {
            refreshShareSnapshot(chapters: chapters, activeChapter: activeChapter)
        }
        .onChange(of: comicStripMode) {
            refreshShareSnapshot(chapters: chapters, activeChapter: activeChapter)
        }
    }

    @ViewBuilder
    private func chapterAndModeHeader(
        chapters: [DailyJournalChapter],
        activeChapter: DailyJournalChapter?
    ) -> some View {
        if chapters.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(chapters) { chapter in
                        let selected = !comicStripMode && chapter.id == activeChapter?.id
                        Button {
                            comicStripMode = false
                            selectedChapterID = chapter.id
                        } label: {
                            HStack(spacing: 4) {
                                Text(chapter.timeRangeLabel)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                if let place = chapter.place?.shortLabel, !place.isEmpty {
                                    Text("📍\(place)")
                                        .font(.system(size: 11, weight: .medium))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(selected ? MoMoPalette.canvas : MoMoPalette.ink)
                            .background(selected ? MoMoPalette.ink : MoMoPalette.paper, in: Capsule())
                            .overlay {
                                Capsule().strokeBorder(MoMoPalette.line, lineWidth: selected ? 0 : 0.75)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline.journal.chapter.\(chapter.slotIndex)")
                    }

                    Button {
                        comicStripMode.toggle()
                    } label: {
                        Label("连载长图 (\(chapters.count))", systemImage: "rectangle.grid.1x2.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(comicStripMode ? MoMoPalette.canvas : MoMoPalette.ink)
                            .background(comicStripMode ? MoMoPalette.ink : MoMoPalette.paper, in: Capsule())
                            .overlay {
                                Capsule().strokeBorder(MoMoPalette.line, lineWidth: comicStripMode ? 0 : 0.75)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("timeline.journal.comicToggle")
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func styleIntervalAndLocationControls(
        activeInput: DailyJournalInput,
        activeChapter: DailyJournalChapter?,
        cover: DailyMemoryJournalCoordinator.LoadedCover,
        isGenerating: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("画风", selection: $selectedStyle) {
                ForEach(DailyJournalStyleChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("timeline.journal.stylePicker")

            HStack(spacing: 10) {
                Menu {
                    Picker("生图间隔", selection: $coordinator.interval) {
                        ForEach(DailyJournalIntervalOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "clock.badge.sparkles")
                        Text(coordinator.interval.title)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .phoneText(.metadata)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                    .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(MoMoPalette.line, lineWidth: 0.75)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(MoMoPalette.ink)
                .accessibilityIdentifier("timeline.journal.intervalPicker")

                Button {
                    locationProvider.requestAuthorizationOrRefresh()
                } label: {
                    HStack(spacing: 5) {
                        if locationProvider.isSamplingLocation {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: locationProvider.isAuthorized ? "location.fill" : "location")
                        }
                        Text(locationButtonLabel(activeChapter: activeChapter))
                            .lineLimit(1)
                    }
                    .phoneText(.metadata)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(MoMoPalette.line, lineWidth: 0.75)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(MoMoPalette.ink)
                .accessibilityIdentifier("timeline.journal.locationButton")
            }

            HStack(spacing: 12) {
                Button {
                    Task {
                        if comicStripMode {
                            let all = coordinator.chapters(for: input, visits: locationProvider.visits)
                            for ch in all {
                                await coordinator.regenerate(for: ch.chapterInput, style: selectedStyle)
                            }
                            refreshShareSnapshot(chapters: all, activeChapter: activeChapter)
                        } else {
                            await coordinator.regenerate(for: activeInput, style: selectedStyle)
                            let all = coordinator.chapters(for: input, visits: locationProvider.visits)
                            refreshShareSnapshot(chapters: all, activeChapter: activeChapter)
                        }
                    }
                } label: {
                    Label(
                        isGenerating
                            ? String(localized: "正在绘制…")
                            : (cover.cgImage != nil ? String(localized: "重新生成插画") : String(localized: "换一幅软萌构图")),
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                    )
                    .phoneText(.metadata)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(isGenerating)
                .accessibilityIdentifier("timeline.journal.regenerate")

                if !comicStripMode {
                    ImagePlaygroundTriggerButton(isPresented: $showingPlaygroundSheet)
                }
            }

            if let hint = locationProvider.statusHint ?? coordinator.lastNotice {
                Text(hint)
                    .phoneText(.caption)
                    .foregroundStyle(MoMoPalette.muted)
            }
        }
    }

    private func locationButtonLabel(activeChapter: DailyJournalChapter?) -> String {
        if let place = activeChapter?.place {
            return place.isLiveLocation
                ? "📍 \(place.shortLabel)"
                : "📍 \(place.shortLabel)（场景推断）"
        }
        if let latest = locationProvider.latestPlaceLabel, !latest.isEmpty {
            return "📍 \(latest)"
        }
        return locationProvider.isAuthorized
            ? String(localized: "刷新所在位置")
            : String(localized: "关联所在位置")
    }

    private func capabilityFootnote(cover: DailyMemoryJournalCoordinator.LoadedCover) -> some View {
        let provenance: String = switch cover.metadata.source {
        case .appleImagePlaygroundSheet:
            String(localized: "插画由你在 Apple Intelligence「图乐园」微调定制，仅保存在本机。")
        case .appleImageCreator:
            cover.metadata.brief.distilledByOnDeviceLLM
                ? String(localized: "由端侧 FoundationModels 结合时段与位置提炼吉伊风意象，并通过 Apple Intelligence ImageCreator 在本机生成。")
                : String(localized: "已结合时段、地点与对话主题提取意象，并通过 Apple Intelligence ImageCreator 在本机生成。")
        case .proceduralHandDrawn:
            coordinator.creatorCapability == .unavailableOnDevice
                ? String(localized: "每 \(coordinator.interval.shortTitle) 自动结合所在地点与对话话题，为你绘制吉伊风治愈手账；在启用 Apple 图乐园的设备上将自动联动 ImageCreator。")
                : String(localized: "Momo 按所选时段间隔与所在地点为你绘制的专属手账插画，所有位置与音频数据均留在本地。")
        }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.caption)
                .foregroundStyle(MoMoPalette.muted)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(provenance)
                .phoneText(.caption)
                .foregroundStyle(MoMoPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func refreshShareSnapshot(
        chapters: [DailyJournalChapter],
        activeChapter: DailyJournalChapter?
    ) {
        if comicStripMode && chapters.count > 1 {
            let stripExport = DailyJournalComicStripView(
                dayDateLabel: input.dateLabel,
                interval: coordinator.interval,
                chapters: chapters,
                style: selectedStyle,
                coordinator: coordinator,
                forExport: true
            )
            .frame(width: 400)
            .padding(16)
            .background(Color(red: 0.99, green: 0.98, blue: 0.95))
            .environment(\.colorScheme, .light)

            let renderer = ImageRenderer(content: stripExport)
            renderer.scale = max(2.0, displayScale)
            if let cgImage = renderer.cgImage,
               let png = DailyJournalImageCodec.encodePNG(cgImage) {
                sharePNG = DailyJournalExportPNG(
                    data: png,
                    filename: "MoMo-吉伊手账连载-\(input.dayKey).png",
                    image: Image(decorative: cgImage, scale: 2.0, orientation: .up)
                )
            }
            return
        }

        let targetInput = activeChapter?.chapterInput ?? input
        let cover = coordinator.currentCover(for: targetInput, style: selectedStyle)
        let exportView = DailyJournalPostcardView(
            input: targetInput,
            cover: cover,
            place: activeChapter?.place,
            timeSlotLabel: activeChapter?.timeRangeLabel,
            isGenerating: false,
            forExport: true
        )
        .frame(width: 380)
        .padding(16)
        .background(Color(red: 0.99, green: 0.98, blue: 0.95))
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: exportView)
        renderer.scale = max(2.0, displayScale)
        if let cgImage = renderer.cgImage,
           let png = DailyJournalImageCodec.encodePNG(cgImage) {
            sharePNG = DailyJournalExportPNG(
                data: png,
                filename: "MoMo-手账-\(targetInput.dayKey).png",
                image: Image(decorative: cgImage, scale: 2.0, orientation: .up)
            )
        }
    }
}

private struct DailyJournalExportPNG: Transferable {
    let data: Data
    let filename: String
    let image: Image

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
            .suggestedFileName { $0.filename }
    }
}

// MARK: - Multi-Panel Comic Strip View (全天分时段连载总览)

struct DailyJournalComicStripView: View {
    let dayDateLabel: String
    let interval: DailyJournalIntervalOption
    let chapters: [DailyJournalChapter]
    let style: DailyJournalStyleChoice
    let coordinator: DailyMemoryJournalCoordinator
    var forExport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(dayDateLabel) · 漫游手账连载")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(MoMoPalette.ink)
                    Text("\(interval.title)一幅 · 共记录 \(chapters.count) 个生活切片")
                        .phoneText(.caption)
                        .foregroundStyle(MoMoPalette.muted)
                }
                Spacer()
                PhoneBrandIcon(size: 26)
            }

            ForEach(chapters) { chapter in
                let cover = coordinator.currentCover(for: chapter.chapterInput, style: style)
                let brief = cover.metadata.brief
                VStack(alignment: .leading, spacing: 10) {
                    DailyJournalArtworkFrame(
                        input: chapter.chapterInput,
                        cover: cover,
                        cornerRadius: 14
                    )
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)

                    HStack(spacing: 6) {
                        Text(chapter.timeRangeLabel)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(paletteAccent(brief.palette))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(paletteAccent(brief.palette).opacity(0.12), in: Capsule())
                        if let place = chapter.place?.shortLabel ?? brief.placeLabel, !place.isEmpty {
                            Text("📍 \(place)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(MoMoPalette.muted)
                        }
                        Spacer()
                    }
                    Text(brief.headline)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(MoMoPalette.ink)
                    Text(brief.note)
                        .phoneText(.caption)
                        .foregroundStyle(MoMoPalette.ink.opacity(0.84))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(MoMoPalette.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(MoMoPalette.line, lineWidth: 0.75)
                }
            }

            if forExport {
                HStack {
                    Text("MoMo Agent · 吉伊风位置联动手账")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MoMoPalette.muted)
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(MoMoPalette.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.journal.comicStrip")
    }
}

// MARK: - ImagePlayground Conditional Modifiers

private struct ImagePlaygroundTriggerButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        #if canImport(ImagePlayground)
        if #available(iOS 18.1, macOS 15.1, *) {
            ImagePlaygroundSupportedButton(isPresented: $isPresented)
        }
        #endif
    }
}

#if canImport(ImagePlayground)
@available(iOS 18.1, macOS 15.1, *)
private struct ImagePlaygroundSupportedButton: View {
    @Binding var isPresented: Bool
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground

    var body: some View {
        if supportsImagePlayground {
            Button {
                isPresented = true
            } label: {
                Label("图乐园微调", systemImage: "wand.and.sparkles")
                    .phoneText(.metadata)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(MoMoPalette.ink)
            .foregroundStyle(MoMoPalette.canvas)
            .accessibilityIdentifier("timeline.journal.playground")
        }
    }
}
#endif

private struct ImagePlaygroundSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let brief: DailyJournalBrief
    let existingCGImage: CGImage?
    let onCreated: (URL) -> Void

    func body(content: Content) -> some View {
        #if canImport(ImagePlayground)
        if #available(iOS 18.1, macOS 15.1, *) {
            let concepts: [ImagePlaygroundConcept] = [
                .extracted(from: brief.safeExtractionSummary, title: brief.headline)
            ] + brief.sceneConcepts.map { .text($0) }
            let sourceImg = existingCGImage.map { Image(decorative: $0, scale: 2.0, orientation: .up) }
            content.imagePlaygroundSheet(
                isPresented: $isPresented,
                concepts: concepts,
                sourceImage: sourceImg,
                onCompletion: onCreated
            )
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - Single Chapter Postcard View

struct DailyJournalPostcardView: View {
    let input: DailyJournalInput
    let cover: DailyMemoryJournalCoordinator.LoadedCover
    var place: DailyJournalPlaceVisit? = nil
    var timeSlotLabel: String? = nil
    let isGenerating: Bool
    var forExport = false

    var body: some View {
        let brief = cover.metadata.brief
        let resolvedPlace = place?.shortLabel ?? brief.placeLabel
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                DailyJournalArtworkFrame(
                    input: input,
                    cover: cover,
                    cornerRadius: 16
                )
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)

                if isGenerating && !forExport {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在绘制手账…").phoneText(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 6) {
                    Text(input.dateLabel)
                        .phoneText(.caption)
                        .foregroundStyle(MoMoPalette.muted)
                    if let resolvedPlace, !resolvedPlace.isEmpty {
                        Text("📍\(resolvedPlace)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.72, green: 0.35, blue: 0.42))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color(red: 1.0, green: 0.89, blue: 0.92), in: Capsule())
                    }
                    Spacer()
                    Text(sourceBadgeTitle(cover: cover))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(paletteAccent(brief.palette))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(paletteAccent(brief.palette).opacity(0.12), in: Capsule())
                }

                Text(brief.headline)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(MoMoPalette.ink)

                Text(brief.note)
                    .phoneText(.body)
                    .foregroundStyle(MoMoPalette.ink.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)

                if !brief.tags.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(brief.tags, id: \.self) { tag in
                                Text(tag.hasPrefix("📍") ? tag : "#\(tag)")
                                    .phoneText(.caption)
                                    .foregroundStyle(MoMoPalette.muted)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(MoMoPalette.surface, in: Capsule())
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }

                DailyJournalRhythmStrip(
                    bins: input.wakingHourBins,
                    dayStartHour: input.dayStartHour,
                    accent: paletteAccent(brief.palette)
                )
                .padding(.top, 2)

                if forExport {
                    HStack {
                        PhoneBrandIcon(size: 18)
                        Text("MoMo Agent · 吉伊风记忆手账")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MoMoPalette.muted)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(MoMoPalette.line, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.journal.postcard")
    }

    private func sourceBadgeTitle(cover: DailyMemoryJournalCoordinator.LoadedCover) -> String {
        switch cover.metadata.source {
        case .appleImagePlaygroundSheet: String(localized: "Apple 图乐园定制")
        case .appleImageCreator: String(localized: "Apple 图乐园插画")
        case .proceduralHandDrawn:
            cover.metadata.style == .chiikawa
                ? String(localized: "Momo 吉伊手绘")
                : String(localized: "Momo 水彩手绘")
        }
    }
}

private struct DailyJournalRhythmStrip: View {
    let bins: [Double]
    let dayStartHour: Int
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(bins.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(level > 0.05 ? accent.opacity(0.35 + 0.65 * level) : MoMoPalette.line.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: CGFloat(4 + 14 * level))
                }
            }
            .frame(height: 18, alignment: .bottom)
            HStack {
                Text(DayStartBoundary.label(for: dayStartHour))
                Spacer()
                Text(DayStartBoundary.label(for: (dayStartHour + 12) % 24))
                Spacer()
                Text("次日 \(DayStartBoundary.label(for: dayStartHour))")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(MoMoPalette.muted)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Artwork Frame Dispatcher

struct DailyJournalArtworkFrame: View {
    let input: DailyJournalInput
    let cover: DailyMemoryJournalCoordinator.LoadedCover
    let cornerRadius: CGFloat

    var body: some View {
        let seed = input.deterministicSeed &+ UInt64(max(0, cover.metadata.variationIndex) * 7919)
        Group {
            if let cgImage = cover.cgImage {
                GeometryReader { proxy in
                    Image(decorative: cgImage, scale: 2.0, orientation: .up)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            } else if cover.metadata.style == .chiikawa {
                ChiikawaDoodleCanvas(
                    seed: seed,
                    palette: cover.metadata.brief.palette,
                    motifs: cover.metadata.brief.motifs,
                    placeLabel: cover.metadata.brief.placeLabel ?? input.placeLabel,
                    timeSlotLabel: input.timeSlotLabel
                )
            } else {
                DailyJournalHandDrawnCanvas(
                    seed: seed,
                    palette: cover.metadata.brief.palette,
                    motifs: cover.metadata.brief.motifs,
                    style: cover.metadata.style,
                    bins: input.wakingHourBins
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.black.opacity(0.08), lineWidth: 0.75)
        }
    }
}

private func paletteAccent(_ palette: DailyJournalPalette) -> Color {
    switch palette {
    case .morningAmber: Color(red: 0.82, green: 0.45, blue: 0.24)
    case .studioSage: Color(red: 0.30, green: 0.54, blue: 0.43)
    case .breezeSky: Color(red: 0.27, green: 0.50, blue: 0.72)
    case .twilightApricot: Color(red: 0.76, green: 0.39, blue: 0.49)
    case .lampNight: Color(red: 0.72, green: 0.52, blue: 0.28)
    }
}

// MARK: - Bespoke Chiikawa-Inspired Kawaii Picture-Book Doodle Canvas

struct ChiikawaDoodleCanvas: View {
    let seed: UInt64
    let palette: DailyJournalPalette
    let motifs: [DailyJournalMotif]
    let placeLabel: String?
    let timeSlotLabel: String?

    private struct PastelMood {
        let paper: Color
        let skyBlobA: Color
        let skyBlobB: Color
        let meadow: Color
        let meadowLine: Color
        let ink: Color
        let cheekPink: Color
        let companionAccent: Color
        let starAccent: Color
        let isNight: Bool
    }

    private var mood: PastelMood {
        let cocoaInk = Color(red: 0.25, green: 0.18, blue: 0.16)
        let blush = Color(red: 1.0, green: 0.67, blue: 0.74)
        switch palette {
        case .morningAmber:
            return PastelMood(
                paper: Color(red: 1.0, green: 0.99, blue: 0.96),
                skyBlobA: Color(red: 1.0, green: 0.92, blue: 0.70).opacity(0.68),
                skyBlobB: Color(red: 1.0, green: 0.84, blue: 0.88).opacity(0.60),
                meadow: Color(red: 0.91, green: 0.96, blue: 0.84),
                meadowLine: Color(red: 0.75, green: 0.86, blue: 0.66),
                ink: cocoaInk,
                cheekPink: blush,
                companionAccent: Color(red: 0.62, green: 0.80, blue: 0.95),
                starAccent: Color(red: 0.98, green: 0.75, blue: 0.32),
                isNight: false
            )
        case .studioSage:
            return PastelMood(
                paper: Color(red: 0.99, green: 0.99, blue: 0.96),
                skyBlobA: Color(red: 0.83, green: 0.95, blue: 0.88).opacity(0.72),
                skyBlobB: Color(red: 1.0, green: 0.93, blue: 0.76).opacity(0.58),
                meadow: Color(red: 0.90, green: 0.95, blue: 0.87),
                meadowLine: Color(red: 0.71, green: 0.84, blue: 0.70),
                ink: cocoaInk,
                cheekPink: blush,
                companionAccent: Color(red: 0.63, green: 0.81, blue: 0.95),
                starAccent: Color(red: 0.96, green: 0.73, blue: 0.35),
                isNight: false
            )
        case .breezeSky:
            return PastelMood(
                paper: Color(red: 0.99, green: 0.99, blue: 0.98),
                skyBlobA: Color(red: 0.81, green: 0.92, blue: 0.99).opacity(0.74),
                skyBlobB: Color(red: 1.0, green: 0.86, blue: 0.90).opacity(0.55),
                meadow: Color(red: 0.90, green: 0.96, blue: 0.86),
                meadowLine: Color(red: 0.72, green: 0.86, blue: 0.69),
                ink: cocoaInk,
                cheekPink: blush,
                companionAccent: Color(red: 1.0, green: 0.89, blue: 0.64),
                starAccent: Color(red: 0.98, green: 0.74, blue: 0.36),
                isNight: false
            )
        case .twilightApricot:
            return PastelMood(
                paper: Color(red: 1.0, green: 0.97, blue: 0.95),
                skyBlobA: Color(red: 1.0, green: 0.82, blue: 0.78).opacity(0.72),
                skyBlobB: Color(red: 0.89, green: 0.83, blue: 0.96).opacity(0.65),
                meadow: Color(red: 0.95, green: 0.90, blue: 0.86),
                meadowLine: Color(red: 0.84, green: 0.74, blue: 0.72),
                ink: cocoaInk,
                cheekPink: blush,
                companionAccent: Color(red: 0.66, green: 0.81, blue: 0.95),
                starAccent: Color(red: 0.99, green: 0.76, blue: 0.38),
                isNight: false
            )
        case .lampNight:
            return PastelMood(
                paper: Color(red: 0.20, green: 0.23, blue: 0.35),
                skyBlobA: Color(red: 0.32, green: 0.36, blue: 0.54).opacity(0.75),
                skyBlobB: Color(red: 0.98, green: 0.82, blue: 0.52).opacity(0.28),
                meadow: Color(red: 0.26, green: 0.30, blue: 0.43),
                meadowLine: Color(red: 0.38, green: 0.43, blue: 0.58),
                ink: Color(red: 0.23, green: 0.17, blue: 0.16),
                cheekPink: blush,
                companionAccent: Color(red: 0.66, green: 0.82, blue: 0.96),
                starAccent: Color(red: 1.0, green: 0.86, blue: 0.46),
                isNight: true
            )
        }
    }

    var body: some View {
        let m = mood
        let primaryMotif = motifs.first ?? .notebook
        let jitterA = CGFloat(seed % 29) / 29.0
        let jitterB = CGFloat((seed >> 6) % 31) / 31.0

        Canvas { context, size in
            let w = size.width, h = size.height
            guard w > 8, h > 8 else { return }
            let unit = min(w, h)
            let lineW = max(1.4, unit * 0.0115)
            let stroke = StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round)

            // 1. Cream sketchbook paper base
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(m.paper))

            // 2. Soft Chiikawa-style watercolor pastel blobs in the sky
            let blob1 = CGRect(x: w * (0.04 + 0.08 * jitterA), y: h * 0.05, width: w * 0.58, height: h * 0.50)
            let blob2 = CGRect(x: w * (0.38 + 0.06 * jitterB), y: h * 0.10, width: w * 0.56, height: h * 0.48)
            context.fill(Path(ellipseIn: blob1), with: .color(m.skyBlobA))
            context.fill(Path(ellipseIn: blob2), with: .color(m.skyBlobB))

            // Puffy white doodle cloud or starry night crescent moon
            if m.isNight {
                let cx = w * 0.80, cy = h * 0.20, mr = unit * 0.09
                var moon = Path()
                moon.addArc(center: CGPoint(x: cx, y: cy), radius: mr, startAngle: .degrees(30), endAngle: .degrees(320), clockwise: false)
                moon.addArc(center: CGPoint(x: cx + mr * 0.42, y: cy - mr * 0.18), radius: mr * 0.80, startAngle: .degrees(320), endAngle: .degrees(30), clockwise: true)
                moon.closeSubpath()
                context.fill(moon, with: .color(m.starAccent))
            } else {
                drawPuffyCloud(
                    at: CGPoint(x: w * (0.76 - 0.08 * jitterA), y: h * 0.20),
                    scale: unit * 0.11,
                    context: &context,
                    stroke: StrokeStyle(lineWidth: lineW * 0.8, lineCap: .round)
                )
            }

            // 3. Gentle hand-drawn pastel meadow arc
            var meadow = Path()
            meadow.move(to: CGPoint(x: 0, y: h * 0.66))
            meadow.addQuadCurve(
                to: CGPoint(x: w, y: h * 0.68),
                control: CGPoint(x: w * 0.52, y: h * 0.57)
            )
            meadow.addLine(to: CGPoint(x: w, y: h))
            meadow.addLine(to: CGPoint(x: 0, y: h))
            meadow.closeSubpath()
            context.fill(meadow, with: .color(m.meadow))

            var horizon = Path()
            horizon.move(to: CGPoint(x: w * 0.04, y: h * 0.66))
            horizon.addQuadCurve(
                to: CGPoint(x: w * 0.96, y: h * 0.68),
                control: CGPoint(x: w * 0.52, y: h * 0.575)
            )
            context.stroke(horizon, with: .color(m.meadowLine), style: StrokeStyle(lineWidth: lineW * 0.9, lineCap: .round, dash: [unit * 0.03, unit * 0.018]))

            // 4. Wooden Kawaii Location Signpost (when placeLabel or compact card > 120pt wide)
            if w >= 140, let place = placeLabel, !place.isEmpty {
                drawWoodenSignpost(
                    place: place,
                    at: CGPoint(x: w * 0.18, y: h * 0.63),
                    unit: unit,
                    context: &context,
                    ink: m.ink,
                    stroke: stroke
                )
            }

            // 5. Soft ground shadow ovals beneath our two little mochi pals
            let mainAnchor = CGPoint(x: w * (w >= 140 ? 0.47 : 0.40), y: h * 0.69)
            let palAnchor = CGPoint(x: w * (w >= 140 ? 0.75 : 0.72), y: h * 0.71)
            let mainR = unit * 0.175
            let palR = unit * 0.145

            let shadowColor = Color.black.opacity(m.isNight ? 0.25 : 0.07)
            context.fill(
                Path(ellipseIn: CGRect(x: mainAnchor.x - mainR * 0.95, y: mainAnchor.y + mainR * 0.78, width: mainR * 1.9, height: mainR * 0.34)),
                with: .color(shadowColor)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: palAnchor.x - palR * 0.90, y: palAnchor.y + palR * 0.78, width: palR * 1.8, height: palR * 0.32)),
                with: .color(shadowColor)
            )

            // 6. Main White Mochi Bear-Hamster Cutie (Chiikawa chibi silhouette!)
            drawMochiCutie(
                center: mainAnchor,
                radius: mainR,
                earTipColor: nil,
                bodyFill: .white,
                ink: m.ink,
                blush: m.cheekPink,
                motif: primaryMotif,
                isCompanion: false,
                seed: seed,
                context: &context,
                stroke: stroke
            )

            // 7. Companion Blue/Cream Ear-Tipped Mochi Pal + Little Momo Pebble Badge!
            drawMochiCutie(
                center: palAnchor,
                radius: palR,
                earTipColor: m.companionAccent,
                bodyFill: Color(red: 1.0, green: 0.99, blue: 0.97),
                ink: m.ink,
                blush: m.cheekPink,
                motif: primaryMotif,
                isCompanion: true,
                seed: seed &+ 17,
                context: &context,
                stroke: stroke
            )

            // 8. Foreground Miniature Kawaii Scene Prop between the two pals
            drawKawaiiCenterProp(
                motif: primaryMotif,
                at: CGPoint(x: (mainAnchor.x + palAnchor.x) * 0.51, y: h * 0.81),
                unit: unit * 0.135,
                context: &context,
                ink: m.ink,
                accent: m.starAccent,
                pink: m.cheekPink,
                stroke: stroke
            )

            // 9. Signature Nagano/Chiikawa Floating Sparkles (✦), Music Note (♪), Wiggle Lines & Tiny Clovers!
            drawKawaiiSparklesAndClovers(
                w: w,
                h: h,
                unit: unit,
                mainAnchor: mainAnchor,
                mainR: mainR,
                palAnchor: palAnchor,
                palR: palR,
                starColor: m.starAccent,
                ink: m.isNight ? Color(red: 0.98, green: 0.94, blue: 0.86) : m.ink,
                seed: seed,
                context: &context,
                stroke: StrokeStyle(lineWidth: max(1.1, lineW * 0.78), lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func drawPuffyCloud(
        at c: CGPoint,
        scale s: CGFloat,
        context: inout GraphicsContext,
        stroke: StrokeStyle
    ) {
        var cloud = Path()
        cloud.addEllipse(in: CGRect(x: c.x - s * 1.1, y: c.y - s * 0.35, width: s * 1.1, height: s * 0.75))
        cloud.addEllipse(in: CGRect(x: c.x - s * 0.55, y: c.y - s * 0.65, width: s * 1.15, height: s * 0.95))
        cloud.addEllipse(in: CGRect(x: c.x + s * 0.15, y: c.y - s * 0.30, width: s * 0.95, height: s * 0.70))
        context.fill(cloud, with: .color(.white.opacity(0.88)))
    }

    private func drawWoodenSignpost(
        place: String,
        at base: CGPoint,
        unit: CGFloat,
        context: inout GraphicsContext,
        ink: Color,
        stroke: StrokeStyle
    ) {
        let postW = unit * 0.026
        let postH = unit * 0.25
        let postRect = CGRect(x: base.x - postW * 0.5, y: base.y - postH, width: postW, height: postH)
        let woodPost = Path(roundedRect: postRect, cornerRadius: postW * 0.4)
        context.fill(woodPost, with: .color(Color(red: 0.82, green: 0.67, blue: 0.50)))
        context.stroke(woodPost, with: .color(ink), style: stroke)

        let concisePlace = place
            .components(separatedBy: "·")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? place
        let displayPlace = String((concisePlace.isEmpty ? place : concisePlace).prefix(6))

        let boardW = max(unit * 0.31, unit * (0.14 + CGFloat(displayPlace.count) * 0.042))
        let boardH = unit * 0.105
        let boardRect = CGRect(x: base.x - boardW * 0.44, y: base.y - postH - boardH * 0.65, width: boardW, height: boardH)
        let board = Path(roundedRect: boardRect, cornerRadius: unit * 0.024)
        context.fill(board, with: .color(Color(red: 1.0, green: 0.97, blue: 0.89)))
        context.stroke(board, with: .color(ink), style: stroke)

        // Tiny cute two-leaf sprout perched right on top of the signpost
        let topPt = CGPoint(x: boardRect.midX + unit * 0.02, y: boardRect.minY)
        var stem = Path()
        stem.move(to: topPt)
        stem.addLine(to: CGPoint(x: topPt.x, y: topPt.y - unit * 0.018))
        context.stroke(stem, with: .color(ink), style: StrokeStyle(lineWidth: stroke.lineWidth * 0.75, lineCap: .round))

        let sproutTip = CGPoint(x: topPt.x, y: topPt.y - unit * 0.016)
        var leafL = Path(ellipseIn: CGRect(x: sproutTip.x - unit * 0.036, y: sproutTip.y - unit * 0.020, width: unit * 0.036, height: unit * 0.021))
        leafL = leafL.applying(
            CGAffineTransform(translationX: sproutTip.x, y: sproutTip.y)
                .rotated(by: 0.36)
                .translatedBy(x: -sproutTip.x, y: -sproutTip.y)
        )
        var leafR = Path(ellipseIn: CGRect(x: sproutTip.x, y: sproutTip.y - unit * 0.020, width: unit * 0.036, height: unit * 0.021))
        leafR = leafR.applying(
            CGAffineTransform(translationX: sproutTip.x, y: sproutTip.y)
                .rotated(by: -0.36)
                .translatedBy(x: -sproutTip.x, y: -sproutTip.y)
        )
        let sproutGreen = Color(red: 0.56, green: 0.82, blue: 0.49)
        context.fill(leafL, with: .color(sproutGreen))
        context.fill(leafR, with: .color(sproutGreen))
        context.stroke(leafL, with: .color(ink), style: StrokeStyle(lineWidth: stroke.lineWidth * 0.75, lineCap: .round))
        context.stroke(leafR, with: .color(ink), style: StrokeStyle(lineWidth: stroke.lineWidth * 0.75, lineCap: .round))

        let label = Text("📍\(displayPlace)")
            .font(.system(size: max(9, unit * 0.041), weight: .bold, design: .rounded))
            .foregroundStyle(ink)
        context.draw(label, at: CGPoint(x: boardRect.midX, y: boardRect.midY), anchor: .center)
    }

    private func drawMochiCutie(
        center c: CGPoint,
        radius r: CGFloat,
        earTipColor: Color?,
        bodyFill: Color,
        ink: Color,
        blush: Color,
        motif: DailyJournalMotif,
        isCompanion: Bool,
        seed: UInt64,
        context: inout GraphicsContext,
        stroke: StrokeStyle
    ) {
        // 1. Round bear/cat ears
        let earR = r * 0.31
        let leftEarCenter = CGPoint(x: c.x - r * 0.62, y: c.y - r * 0.78)
        let rightEarCenter = CGPoint(x: c.x + r * 0.62, y: c.y - r * 0.78)
        let leftEar = Path(ellipseIn: CGRect(x: leftEarCenter.x - earR, y: leftEarCenter.y - earR, width: earR * 2, height: earR * 2))
        let rightEar = Path(ellipseIn: CGRect(x: rightEarCenter.x - earR, y: rightEarCenter.y - earR, width: earR * 2, height: earR * 2))

        context.fill(leftEar, with: .color(earTipColor ?? bodyFill))
        context.fill(rightEar, with: .color(earTipColor ?? bodyFill))
        context.stroke(leftEar, with: .color(ink), style: stroke)
        context.stroke(rightEar, with: .color(ink), style: stroke)

        // 2. Stubby little legs at bottom
        let footW = r * 0.28, footH = r * 0.30
        let leftFoot = Path(roundedRect: CGRect(x: c.x - r * 0.46, y: c.y + r * 0.64, width: footW, height: footH), cornerRadius: footW * 0.5)
        let rightFoot = Path(roundedRect: CGRect(x: c.x + r * 0.18, y: c.y + r * 0.64, width: footW, height: footH), cornerRadius: footW * 0.5)
        context.fill(leftFoot, with: .color(bodyFill))
        context.fill(rightFoot, with: .color(bodyFill))
        context.stroke(leftFoot, with: .color(ink), style: stroke)
        context.stroke(rightFoot, with: .color(ink), style: stroke)

        // 3. Squishy unified chubby head + tummy silhouette
        let headW = r * 2.08, headH = r * 1.72
        let bodyRect = CGRect(x: c.x - headW * 0.5, y: c.y - r * 0.92, width: headW, height: headH)
        let mochiBody = Path(roundedRect: bodyRect, cornerRadius: r * 0.86)
        context.fill(mochiBody, with: .color(bodyFill))

        // Companion cute pastel forehead bang patch (Hachiware-inspired subtle triangle accent!)
        if let earTipColor {
            var patch = Path()
            patch.move(to: CGPoint(x: c.x - r * 0.72, y: c.y - r * 0.66))
            patch.addQuadCurve(to: CGPoint(x: c.x - r * 0.06, y: c.y - r * 0.88), control: CGPoint(x: c.x - r * 0.45, y: c.y - r * 0.92))
            patch.addLine(to: CGPoint(x: c.x - r * 0.36, y: c.y - r * 0.42))
            patch.closeSubpath()
            context.fill(patch, with: .color(earTipColor.opacity(0.85)))

            var patchR = Path()
            patchR.move(to: CGPoint(x: c.x + r * 0.72, y: c.y - r * 0.66))
            patchR.addQuadCurve(to: CGPoint(x: c.x + r * 0.06, y: c.y - r * 0.88), control: CGPoint(x: c.x + r * 0.45, y: c.y - r * 0.92))
            patchR.addLine(to: CGPoint(x: c.x + r * 0.36, y: c.y - r * 0.42))
            patchR.closeSubpath()
            context.fill(patchR, with: .color(earTipColor.opacity(0.85)))
        }

        context.stroke(mochiBody, with: .color(ink), style: stroke)

        // Optional cute pink crossbody pochette bag when strolling/outdoors!
        if !isCompanion && (motif == .leaf || seed % 3 == 1) {
            var strap = Path()
            strap.move(to: CGPoint(x: c.x - r * 0.65, y: c.y + r * 0.05))
            strap.addLine(to: CGPoint(x: c.x + r * 0.58, y: c.y + r * 0.58))
            context.stroke(strap, with: .color(Color(red: 0.96, green: 0.58, blue: 0.68)), style: StrokeStyle(lineWidth: stroke.lineWidth * 1.4, lineCap: .round))
            let bagRect = CGRect(x: c.x + r * 0.32, y: c.y + r * 0.38, width: r * 0.38, height: r * 0.30)
            let bag = Path(roundedRect: bagRect, cornerRadius: r * 0.10)
            context.fill(bag, with: .color(Color(red: 1.0, green: 0.74, blue: 0.81)))
            context.stroke(bag, with: .color(ink), style: StrokeStyle(lineWidth: stroke.lineWidth * 0.85, lineCap: .round))
        }

        // 4. Stubby waving paws!
        let waveUp = (isCompanion && seed % 2 == 0) || (!isCompanion && motif == .sparkles)
        let leftArm = Path(roundedRect: CGRect(x: c.x - r * 1.12, y: c.y + (waveUp ? -r * 0.18 : r * 0.08), width: r * 0.34, height: r * 0.24), cornerRadius: r * 0.12)
        let rightArm = Path(roundedRect: CGRect(x: c.x + r * 0.78, y: c.y + (isCompanion ? -r * 0.16 : r * 0.08), width: r * 0.34, height: r * 0.24), cornerRadius: r * 0.12)
        context.fill(leftArm, with: .color(bodyFill))
        context.fill(rightArm, with: .color(bodyFill))
        context.stroke(leftArm, with: .color(ink), style: stroke)
        context.stroke(rightArm, with: .color(ink), style: stroke)

        // 5. Rosy pink oval blush cheeks + "//" Chiikawa ink blush ticks!
        let cheekW = r * 0.38, cheekH = r * 0.22
        let cheekY = c.y - r * 0.06
        let leftCheekRect = CGRect(x: c.x - r * 0.76, y: cheekY, width: cheekW, height: cheekH)
        let rightCheekRect = CGRect(x: c.x + r * 0.38, y: cheekY, width: cheekW, height: cheekH)
        context.fill(Path(ellipseIn: leftCheekRect), with: .color(blush.opacity(0.68)))
        context.fill(Path(ellipseIn: rightCheekRect), with: .color(blush.opacity(0.68)))

        var blushTicks = Path()
        for cx in [leftCheekRect.midX, rightCheekRect.midX] {
            for dx in [-r * 0.05, r * 0.05] {
                blushTicks.move(to: CGPoint(x: cx + dx + r * 0.02, y: cheekY + cheekH * 0.28))
                blushTicks.addLine(to: CGPoint(x: cx + dx - r * 0.02, y: cheekY + cheekH * 0.72))
            }
        }
        context.stroke(blushTicks, with: .color(ink.opacity(0.55)), style: StrokeStyle(lineWidth: max(1.0, stroke.lineWidth * 0.65), lineCap: .round))

        // 6. Eyes & cute mouth expression
        let eyeY = c.y - r * 0.22
        let leftEyeX = c.x - r * 0.36
        let rightEyeX = c.x + r * 0.36
        let eyeR = r * 0.105

        if motif == .coffee && !isCompanion {
            // Happy closed savoring eyes (∩ ∩) while enjoying coffee/food!
            var happyEyes = Path()
            happyEyes.addArc(center: CGPoint(x: leftEyeX, y: eyeY + eyeR * 0.3), radius: eyeR * 1.05, startAngle: .degrees(195), endAngle: .degrees(345), clockwise: false)
            happyEyes.move(to: CGPoint(x: rightEyeX - eyeR * 1.0, y: eyeY + eyeR * 0.3))
            happyEyes.addArc(center: CGPoint(x: rightEyeX, y: eyeY + eyeR * 0.3), radius: eyeR * 1.05, startAngle: .degrees(195), endAngle: .degrees(345), clockwise: false)
            context.stroke(happyEyes, with: .color(ink), style: stroke)
        } else {
            // Classic shiny dark-cocoa eyes with tiny white upper-left catchlights!
            let le = CGRect(x: leftEyeX - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2.15)
            let re = CGRect(x: rightEyeX - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2.15)
            context.fill(Path(ellipseIn: le), with: .color(ink))
            context.fill(Path(ellipseIn: re), with: .color(ink))

            let catchR = eyeR * 0.38
            context.fill(Path(ellipseIn: CGRect(x: leftEyeX - eyeR * 0.45, y: eyeY - eyeR * 0.55, width: catchR * 2, height: catchR * 2)), with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: rightEyeX - eyeR * 0.45, y: eyeY - eyeR * 0.55, width: catchR * 2, height: catchR * 2)), with: .color(.white))

            // Determined cute eyebrows when working/coding!
            if motif == .laptop && !isCompanion {
                var brows = Path()
                brows.move(to: CGPoint(x: leftEyeX - eyeR * 0.9, y: eyeY - eyeR * 1.65))
                brows.addLine(to: CGPoint(x: leftEyeX + eyeR * 0.7, y: eyeY - eyeR * 1.25))
                brows.move(to: CGPoint(x: rightEyeX + eyeR * 0.9, y: eyeY - eyeR * 1.65))
                brows.addLine(to: CGPoint(x: rightEyeX - eyeR * 0.7, y: eyeY - eyeR * 1.25))
                context.stroke(brows, with: .color(ink), style: StrokeStyle(lineWidth: stroke.lineWidth * 0.85, lineCap: .round))
            }
        }

        // Cute little "ω" kitty-smile mouth right between the eyes/cheeks!
        let mouthY = c.y - r * 0.08
        var mouth = Path()
        mouth.move(to: CGPoint(x: c.x - r * 0.13, y: mouthY))
        mouth.addQuadCurve(to: CGPoint(x: c.x, y: mouthY - r * 0.02), control: CGPoint(x: c.x - r * 0.065, y: mouthY + r * 0.09))
        mouth.addQuadCurve(to: CGPoint(x: c.x + r * 0.13, y: mouthY), control: CGPoint(x: c.x + r * 0.065, y: mouthY + r * 0.09))
        context.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: stroke.lineWidth * 0.88, lineCap: .round, lineJoin: .round))
    }

    private func drawKawaiiCenterProp(
        motif: DailyJournalMotif,
        at c: CGPoint,
        unit u: CGFloat,
        context: inout GraphicsContext,
        ink: Color,
        accent: Color,
        pink: Color,
        stroke: StrokeStyle
    ) {
        switch motif {
        case .laptop:
            let table = Path(roundedRect: CGRect(x: c.x - u * 0.95, y: c.y - u * 0.05, width: u * 1.9, height: u * 0.32), cornerRadius: u * 0.10)
            context.fill(table, with: .color(Color(red: 0.91, green: 0.76, blue: 0.58)))
            context.stroke(table, with: .color(ink), style: stroke)
            let screen = Path(roundedRect: CGRect(x: c.x - u * 0.55, y: c.y - u * 0.68, width: u * 1.1, height: u * 0.68), cornerRadius: u * 0.12)
            context.fill(screen, with: .color(Color(red: 0.95, green: 0.97, blue: 1.0)))
            context.stroke(screen, with: .color(ink), style: stroke)
            let heart = Path(ellipseIn: CGRect(x: c.x - u * 0.12, y: c.y - u * 0.42, width: u * 0.24, height: u * 0.20))
            context.fill(heart, with: .color(pink))

        case .coffee:
            let bowl = Path(roundedRect: CGRect(x: c.x - u * 0.62, y: c.y - u * 0.42, width: u * 1.24, height: u * 0.72), cornerRadius: u * 0.30)
            context.fill(bowl, with: .color(Color(red: 1.0, green: 0.90, blue: 0.74)))
            context.stroke(bowl, with: .color(ink), style: stroke)
            var steam = Path()
            for dx in [-u * 0.20, u * 0.20] {
                steam.move(to: CGPoint(x: c.x + dx, y: c.y - u * 0.54))
                steam.addQuadCurve(to: CGPoint(x: c.x + dx + u * 0.06, y: c.y - u * 0.92), control: CGPoint(x: c.x + dx - u * 0.14, y: c.y - u * 0.74))
            }
            context.stroke(steam, with: .color(ink.opacity(0.65)), style: StrokeStyle(lineWidth: stroke.lineWidth * 0.8, lineCap: .round))

        default:
            // Open stitched cream handbook with little star sticker!
            let bookL = Path(roundedRect: CGRect(x: c.x - u * 0.78, y: c.y - u * 0.46, width: u * 0.78, height: u * 0.80), cornerRadius: u * 0.10)
            let bookR = Path(roundedRect: CGRect(x: c.x, y: c.y - u * 0.46, width: u * 0.78, height: u * 0.80), cornerRadius: u * 0.10)
            context.fill(bookL, with: .color(.white))
            context.fill(bookR, with: .color(.white))
            context.stroke(bookL, with: .color(ink), style: stroke)
            context.stroke(bookR, with: .color(ink), style: stroke)
            let sticker = Path(ellipseIn: CGRect(x: c.x + u * 0.24, y: c.y - u * 0.20, width: u * 0.28, height: u * 0.28))
            context.fill(sticker, with: .color(accent))
        }
    }

    private func drawKawaiiSparklesAndClovers(
        w: CGFloat,
        h: CGFloat,
        unit: CGFloat,
        mainAnchor: CGPoint,
        mainR: CGFloat,
        palAnchor: CGPoint,
        palR: CGFloat,
        starColor: Color,
        ink: Color,
        seed: UInt64,
        context: inout GraphicsContext,
        stroke: StrokeStyle
    ) {
        // 4-point sparkles (✦)
        let starCenters = [
            CGPoint(x: mainAnchor.x - mainR * 1.25, y: mainAnchor.y - mainR * 0.95),
            CGPoint(x: palAnchor.x + palR * 1.05, y: palAnchor.y - palR * 1.08),
            CGPoint(x: (mainAnchor.x + palAnchor.x) * 0.5, y: mainAnchor.y - mainR * 1.28)
        ]
        for (idx, sc) in starCenters.enumerated() {
            let sr = unit * (idx == 2 ? 0.036 : 0.028)
            var star = Path()
            star.move(to: CGPoint(x: sc.x, y: sc.y - sr))
            star.addQuadCurve(to: CGPoint(x: sc.x + sr, y: sc.y), control: CGPoint(x: sc.x + sr * 0.2, y: sc.y - sr * 0.2))
            star.addQuadCurve(to: CGPoint(x: sc.x, y: sc.y + sr), control: CGPoint(x: sc.x + sr * 0.2, y: sc.y + sr * 0.2))
            star.addQuadCurve(to: CGPoint(x: sc.x - sr, y: sc.y), control: CGPoint(x: sc.x - sr * 0.2, y: sc.y + sr * 0.2))
            star.addQuadCurve(to: CGPoint(x: sc.x, y: sc.y - sr), control: CGPoint(x: sc.x - sr * 0.2, y: sc.y - sr * 0.2))
            star.closeSubpath()
            context.fill(star, with: .color(starColor))
        }

        // Cute wiggle motion arcs near companion's ear ("(( ")
        var wiggle = Path()
        let wx = palAnchor.x + palR * 0.95, wy = palAnchor.y - palR * 0.62
        wiggle.addArc(center: CGPoint(x: wx, y: wy), radius: unit * 0.028, startAngle: .degrees(-45), endAngle: .degrees(45), clockwise: false)
        wiggle.move(to: CGPoint(x: wx + unit * 0.018, y: wy - unit * 0.025))
        wiggle.addArc(center: CGPoint(x: wx + unit * 0.012, y: wy), radius: unit * 0.042, startAngle: .degrees(-40), endAngle: .degrees(40), clockwise: false)
        context.stroke(wiggle, with: .color(ink.opacity(0.65)), style: stroke)

        // Musical note ♪ when cheerful
        if w >= 140 {
            let noteText = Text("♪")
                .font(.system(size: max(11, unit * 0.065), weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.94, green: 0.52, blue: 0.64))
            context.draw(noteText, at: CGPoint(x: mainAnchor.x + mainR * 0.95, y: mainAnchor.y - mainR * 1.05), anchor: .center)
        }

        // Little meadow grass tufts ("w")
        var grass = Path()
        for gx in [w * 0.14, w * 0.88] {
            let gy = h * 0.86
            let gw = unit * 0.018
            grass.move(to: CGPoint(x: gx - gw, y: gy))
            grass.addLine(to: CGPoint(x: gx - gw * 0.4, y: gy - gw * 1.1))
            grass.addLine(to: CGPoint(x: gx, y: gy - gw * 0.2))
            grass.addLine(to: CGPoint(x: gx + gw * 0.5, y: gy - gw * 1.2))
            grass.addLine(to: CGPoint(x: gx + gw, y: gy))
        }
        context.stroke(grass, with: .color(Color(red: 0.55, green: 0.76, blue: 0.52)), style: stroke)
    }
}

// MARK: - Bespoke Procedural Watercolor / Sketch / 3D-Pebble Canvas (Secondary Styles)

private struct DailyJournalHandDrawnCanvas: View {
    let seed: UInt64
    let palette: DailyJournalPalette
    let motifs: [DailyJournalMotif]
    let style: DailyJournalStyleChoice
    let bins: [Double]

    private struct ThemeColors {
        let paperTop: Color
        let paperBottom: Color
        let washPrimary: Color
        let washSecondary: Color
        let hillBack: Color
        let hillFront: Color
        let ink: Color
        let highlight: Color
    }

    private var colors: ThemeColors {
        if style == .sketch {
            return ThemeColors(
                paperTop: Color(red: 0.97, green: 0.95, blue: 0.91),
                paperBottom: Color(red: 0.93, green: 0.90, blue: 0.84),
                washPrimary: Color(red: 0.76, green: 0.72, blue: 0.65).opacity(0.32),
                washSecondary: Color(red: 0.65, green: 0.60, blue: 0.54).opacity(0.24),
                hillBack: Color(red: 0.80, green: 0.76, blue: 0.70),
                hillFront: Color(red: 0.68, green: 0.64, blue: 0.58),
                ink: Color(red: 0.20, green: 0.18, blue: 0.16),
                highlight: Color(red: 0.85, green: 0.56, blue: 0.30)
            )
        }
        switch palette {
        case .morningAmber:
            return ThemeColors(
                paperTop: Color(red: 0.99, green: 0.95, blue: 0.88),
                paperBottom: Color(red: 0.97, green: 0.88, blue: 0.76),
                washPrimary: Color(red: 0.95, green: 0.68, blue: 0.36).opacity(0.35),
                washSecondary: Color(red: 0.90, green: 0.49, blue: 0.33).opacity(0.25),
                hillBack: Color(red: 0.91, green: 0.74, blue: 0.53),
                hillFront: Color(red: 0.80, green: 0.55, blue: 0.35),
                ink: Color(red: 0.26, green: 0.19, blue: 0.14),
                highlight: Color(red: 0.98, green: 0.80, blue: 0.42)
            )
        case .studioSage:
            return ThemeColors(
                paperTop: Color(red: 0.95, green: 0.96, blue: 0.92),
                paperBottom: Color(red: 0.87, green: 0.91, blue: 0.84),
                washPrimary: Color(red: 0.52, green: 0.72, blue: 0.58).opacity(0.34),
                washSecondary: Color(red: 0.82, green: 0.74, blue: 0.54).opacity(0.28),
                hillBack: Color(red: 0.68, green: 0.79, blue: 0.69),
                hillFront: Color(red: 0.46, green: 0.62, blue: 0.50),
                ink: Color(red: 0.18, green: 0.24, blue: 0.20),
                highlight: Color(red: 0.92, green: 0.79, blue: 0.48)
            )
        case .breezeSky:
            return ThemeColors(
                paperTop: Color(red: 0.93, green: 0.96, blue: 0.99),
                paperBottom: Color(red: 0.85, green: 0.91, blue: 0.96),
                washPrimary: Color(red: 0.48, green: 0.72, blue: 0.89).opacity(0.34),
                washSecondary: Color(red: 0.94, green: 0.82, blue: 0.62).opacity(0.28),
                hillBack: Color(red: 0.68, green: 0.81, blue: 0.90),
                hillFront: Color(red: 0.44, green: 0.64, blue: 0.78),
                ink: Color(red: 0.17, green: 0.23, blue: 0.30),
                highlight: Color(red: 0.97, green: 0.83, blue: 0.50)
            )
        case .twilightApricot:
            return ThemeColors(
                paperTop: Color(red: 0.97, green: 0.90, blue: 0.89),
                paperBottom: Color(red: 0.88, green: 0.80, blue: 0.86),
                washPrimary: Color(red: 0.92, green: 0.58, blue: 0.49).opacity(0.36),
                washSecondary: Color(red: 0.58, green: 0.50, blue: 0.72).opacity(0.28),
                hillBack: Color(red: 0.77, green: 0.63, blue: 0.73),
                hillFront: Color(red: 0.55, green: 0.44, blue: 0.60),
                ink: Color(red: 0.23, green: 0.17, blue: 0.25),
                highlight: Color(red: 0.98, green: 0.76, blue: 0.52)
            )
        case .lampNight:
            return ThemeColors(
                paperTop: Color(red: 0.17, green: 0.20, blue: 0.28),
                paperBottom: Color(red: 0.25, green: 0.26, blue: 0.35),
                washPrimary: Color(red: 0.94, green: 0.71, blue: 0.36).opacity(0.30),
                washSecondary: Color(red: 0.42, green: 0.52, blue: 0.74).opacity(0.28),
                hillBack: Color(red: 0.27, green: 0.31, blue: 0.42),
                hillFront: Color(red: 0.20, green: 0.23, blue: 0.33),
                ink: Color(red: 0.95, green: 0.91, blue: 0.83),
                highlight: Color(red: 0.98, green: 0.79, blue: 0.42)
            )
        }
    }

    var body: some View {
        let theme = colors
        Canvas { context, size in
            let w = size.width, h = size.height
            guard w > 4, h > 4 else { return }

            let bgRect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(bgRect),
                with: .linearGradient(
                    Gradient(colors: [theme.paperTop, theme.paperBottom]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: w * 0.3, y: h)
                )
            )

            let shiftA = CGFloat((seed % 37)) / 37.0
            let shiftB = CGFloat(((seed >> 8) % 41)) / 41.0
            let bloom1 = CGRect(x: w * (0.08 + 0.22 * shiftA), y: h * (0.06 + 0.14 * shiftB), width: w * 0.54, height: h * 0.54)
            let bloom2 = CGRect(x: w * (0.42 + 0.18 * shiftB), y: h * (0.18 + 0.16 * shiftA), width: w * 0.50, height: h * 0.48)
            context.fill(Path(ellipseIn: bloom1), with: .color(theme.washPrimary))
            context.fill(Path(ellipseIn: bloom2), with: .color(theme.washSecondary))

            let celestialX = w * (0.74 - 0.12 * shiftA)
            let celestialY = h * 0.24
            let r = min(w, h) * 0.10
            if palette == .lampNight || motifs.contains(.moon) {
                var moon = Path()
                moon.addArc(center: CGPoint(x: celestialX, y: celestialY), radius: r, startAngle: .degrees(35), endAngle: .degrees(315), clockwise: false)
                moon.addArc(center: CGPoint(x: celestialX + r * 0.42, y: celestialY - r * 0.18), radius: r * 0.82, startAngle: .degrees(315), endAngle: .degrees(35), clockwise: true)
                moon.closeSubpath()
                context.fill(moon, with: .color(theme.highlight))
            } else {
                let sunRect = CGRect(x: celestialX - r, y: celestialY - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: sunRect), with: .color(theme.highlight.opacity(style == .animation ? 0.95 : 0.82)))
                var rays = Path()
                for i in 0..<8 {
                    let angle = Double(i) * (.pi / 4.0) + Double(shiftA) * 0.3
                    let p1 = CGPoint(x: celestialX + CGFloat(cos(angle)) * r * 1.32, y: celestialY + CGFloat(sin(angle)) * r * 1.32)
                    let p2 = CGPoint(x: celestialX + CGFloat(cos(angle)) * r * 1.68, y: celestialY + CGFloat(sin(angle)) * r * 1.68)
                    rays.move(to: p1)
                    rays.addLine(to: p2)
                }
                context.stroke(rays, with: .color(theme.ink.opacity(0.45)), style: StrokeStyle(lineWidth: max(1.2, w * 0.005), lineCap: .round))
            }

            func hillPath(baseY: CGFloat, amplitude: CGFloat, phaseOffset: Double) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: h))
                let sampleCount = 24
                for idx in 0...sampleCount {
                    let x = w * CGFloat(idx) / CGFloat(sampleCount)
                    let binVal = bins.isEmpty ? 0.25 : bins[min(idx, bins.count - 1)]
                    let wave = sin(Double(idx) * 0.55 + phaseOffset) * 0.5 + 0.5
                    let lift = amplitude * CGFloat(0.35 * wave + 0.65 * binVal)
                    p.addLine(to: CGPoint(x: x, y: baseY - lift))
                }
                p.addLine(to: CGPoint(x: w, y: h))
                p.closeSubpath()
                return p
            }

            let backHill = hillPath(baseY: h * 0.74, amplitude: h * 0.16, phaseOffset: Double(shiftA) * 4.0)
            let frontHill = hillPath(baseY: h * 0.85, amplitude: h * 0.13, phaseOffset: Double(shiftB) * 5.2 + 1.3)
            if style == .sketch {
                context.fill(backHill, with: .color(theme.hillBack.opacity(0.45)))
                context.stroke(backHill, with: .color(theme.ink.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                context.fill(frontHill, with: .color(theme.hillFront.opacity(0.55)))
                context.stroke(frontHill, with: .color(theme.ink.opacity(0.75)), style: StrokeStyle(lineWidth: 1.4))
            } else {
                context.fill(backHill, with: .color(theme.hillBack))
                context.fill(frontHill, with: .color(theme.hillFront))
            }

            let strokeW = max(1.4, min(w, h) * 0.011)
            let stroke = StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round)

            let momoR = min(w, h) * 0.115
            let momoCenter = CGPoint(x: w * 0.78, y: h * 0.76)
            let momoBody = Path(roundedRect: CGRect(x: momoCenter.x - momoR, y: momoCenter.y - momoR * 0.92, width: momoR * 2.0, height: momoR * 1.84), cornerRadius: momoR * 0.88)
            context.fill(momoBody, with: .color(Color(red: 0.16, green: 0.16, blue: 0.18)))
            if style == .animation {
                let sheen = Path(ellipseIn: CGRect(x: momoCenter.x - momoR * 0.55, y: momoCenter.y - momoR * 0.68, width: momoR * 0.7, height: momoR * 0.32))
                context.fill(sheen, with: .color(.white.opacity(0.22)))
            }
            let eyeW = momoR * 0.22, eyeH = momoR * 0.34
            let leftEye = Path(roundedRect: CGRect(x: momoCenter.x - momoR * 0.44, y: momoCenter.y - momoR * 0.22, width: eyeW, height: eyeH), cornerRadius: eyeW * 0.5)
            let rightEye = Path(roundedRect: CGRect(x: momoCenter.x + momoR * 0.20, y: momoCenter.y - momoR * 0.22, width: eyeW, height: eyeH), cornerRadius: eyeW * 0.5)
            context.fill(leftEye, with: .color(Color(red: 0.98, green: 0.96, blue: 0.92)))
            context.fill(rightEye, with: .color(Color(red: 0.98, green: 0.96, blue: 0.92)))

            let primaryMotif = motifs.first ?? .notebook
            let anchor = CGPoint(x: w * 0.30, y: h * 0.73)
            let unit = min(w, h) * 0.16
            drawMotif(primaryMotif, at: anchor, unit: unit, context: &context, ink: theme.ink, fill: theme.paperTop, highlight: theme.highlight, stroke: stroke)
        }
    }

    private func drawMotif(
        _ motif: DailyJournalMotif,
        at c: CGPoint,
        unit u: CGFloat,
        context: inout GraphicsContext,
        ink: Color,
        fill: Color,
        highlight: Color,
        stroke: StrokeStyle
    ) {
        switch motif {
        case .coffee:
            let cupRect = CGRect(x: c.x - u * 0.55, y: c.y - u * 0.35, width: u * 1.1, height: u * 0.82)
            let cup = Path(roundedRect: cupRect, cornerRadius: u * 0.22)
            context.fill(cup, with: .color(fill))
            context.stroke(cup, with: .color(ink), style: stroke)
        case .laptop:
            let screenRect = CGRect(x: c.x - u * 0.72, y: c.y - u * 0.62, width: u * 1.44, height: u * 0.92)
            let screen = Path(roundedRect: screenRect, cornerRadius: u * 0.12)
            context.fill(screen, with: .color(fill))
            context.stroke(screen, with: .color(ink), style: stroke)
        default:
            let leftPage = CGRect(x: c.x - u * 0.82, y: c.y - u * 0.48, width: u * 0.80, height: u * 0.96)
            let rightPage = CGRect(x: c.x - u * 0.02, y: c.y - u * 0.48, width: u * 0.80, height: u * 0.96)
            let lp = Path(roundedRect: leftPage, cornerRadius: u * 0.08)
            let rp = Path(roundedRect: rightPage, cornerRadius: u * 0.08)
            context.fill(lp, with: .color(fill))
            context.fill(rp, with: .color(fill))
            context.stroke(lp, with: .color(ink), style: stroke)
            context.stroke(rp, with: .color(ink), style: stroke)
        }
    }
}
