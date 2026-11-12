import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct VoiceprintTests {
    @Test func mergedReadingTurnCorrectsAndPlaysAllItsMembersAtomically() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await append(vector(), fixture: fixture, store: store, index: 0)
        let document = try await append(vector(), fixture: fixture, store: store, index: 1)
        let locations = try await store.transcriptLocations(document: document)
        let turn = try #require(document.readingTurns(locations: locations).first)
        #expect(document.readingTurns(locations: locations).count == 1)
        #expect(turn.sources.count == 2)
        let playback = try await store.playbackTimeline(sessionID: fixture.sessionID, expectedGeneration: document.generation,
            source: turn.source, additionalSources: Array(turn.sources.dropFirst()))
        #expect(playback.parts.map(\.frames.count).reduce(0, +) == 128_000)
        try await store.correctSpeakers(turn.sources, feedback: .owner)
        let corrected = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(corrected.spans.allSatisfy { $0.attribution?.isUser == true && $0.attribution?.confirmed == true })
        #expect(corrected.version == document.version + 1)
        await #expect(throws: ArchiveError.staleSource) {
            try await store.correctSpeakers(turn.sources, feedback: .notOwner)
        }
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).version == corrected.version)
    }

    private let revision = ContentHash.sha256(Data("speaker-v1".utf8))
    private func vector(_ x: Float = 1, _ y: Float = 0, _ z: Float = 0) -> [Float] {
        let norm = sqrt(x * x + y * y + z * z)
        return [x / norm, y / norm, z / norm] + Array(repeating: 0, count: 253)
    }

    @Test func datedExclusionSurvivesRestartAndRematchAtExactSpanTime() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await append(vector(), fixture: fixture, store: store, index: 0)
        try await store.correctSpeaker(first.source(for: first.spans[0]), feedback: .person("Alex"))
        let second = try await append(vector(), fixture: fixture, store: store, index: 1)
        #expect(second.spans[1].speaker == "Alex")
        let locations = try await store.transcriptLocations(document: second)
        let cutoff = try #require(locations[second.spans[1].id]?.recordedAt)
        try await store.excludeSpeaker(named: "Alex", from: cutoff)
        let reopened = try fixture.store()
        _ = try await reopened.rematchAllSpeakers()
        let third = try await append(vector(), fixture: fixture, store: reopened, index: 2)
        #expect(third.spans[0].speaker == "Alex")
        #expect(third.spans.dropFirst().allSatisfy { $0.attribution?.personID == nil })
    }

    @Test func exclusionDeliverySurvivesLostReceiptAndDoesNotEnrollReplacement() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await append(vector(), fixture: fixture, store: store, index: 0)
        try await store.correctSpeaker(first.source(for: first.spans[0]), feedback: .person("Alex"))
        let second = try await append(vector(), fixture: fixture, store: store, index: 1)
        let refs = [second.source(for: second.spans[1])]
        try await store.excludeSpeaker(named: "Alex", sources: refs, deliveryID: "sample-command")
        let reopened = try fixture.store()
        try await reopened.excludeSpeaker(named: "Alex", sources: refs, deliveryID: "sample-command")
        let result = try await reopened.readTranscript(sessionID: fixture.sessionID)
        #expect(result.spans[0].speaker == "Alex")
        #expect(result.spans[1].attribution?.personID == nil)
        #expect(try await reopened.speakerProfiles().map(\.name) == ["Alex"])
    }

    @Test func feedbackSurvivesRestartAndCorrectsBothFalsePositiveAndFalseNegative() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await append(vector(), fixture: fixture, store: store, index: 0)
        #expect(first.spans.last?.attribution?.isUser == false)
        try await store.correctSpeaker(first.source(for: first.spans.last!), feedback: .owner)
        let second = try await append(vector(0.8, 0.6), fixture: fixture, store: store, index: 1)
        #expect(second.spans.last?.attribution?.isUser == true)
        #expect(second.spans.last?.attribution?.confirmed == false)
        try await store.correctSpeaker(second.source(for: second.spans.last!), feedback: .notOwner)
        let corrected = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(corrected.spans.last?.attribution?.isUser == false)
        #expect(corrected.spans.first?.attribution?.isUser == true)
        let reopened = try fixture.store()
        let third = try await append(vector(0.8, 0.6), fixture: fixture, store: reopened, index: 2)
        #expect(third.spans.last?.attribution?.isUser == false)
        // A contradictory correction replaces the old negative exemplar for that exact source.
        let negative = third.spans[1]
        try await reopened.correctSpeaker(third.source(for: negative), feedback: .owner)
        let repaired = try await reopened.readTranscript(sessionID: fixture.sessionID)
        #expect(repaired.spans[1].attribution?.confirmed == true)
        #expect(repaired.spans.last?.attribution?.isUser == true)
        // Remove the original clean anchor. Only the user's second confirmation remains.
        try await reopened.correctSpeaker(repaired.source(for: repaired.spans[0]), feedback: .clear)
        let current = try await reopened.readTranscript(sessionID: fixture.sessionID)
        let ownerID = try #require(current.spans[1].attribution?.personID)
        try await reopened.forgetVoiceprint(personID: ownerID)
        #expect(try await reopened.readTranscript(sessionID: fixture.sessionID).spans.allSatisfy { $0.attribution?.personID == nil })
    }

    @Test func inferredSpeechNeverBecomesAnAnchorAndModelRevisionsDoNotMix() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await append(vector(), fixture: fixture, store: store, index: 0)
        try await store.correctSpeaker(first.source(for: first.spans[0]), feedback: .owner)
        _ = try await append(vector(0.8, 0.6), fixture: fixture, store: store, index: 1)
        let third = try await append(vector(0.6, 0.8), fixture: fixture, store: store, index: 2)
        #expect(third.spans.last?.attribution?.personID == nil)
        let fourth = try await append(vector(), fixture: fixture, store: store, index: 3, model: ContentHash.sha256(Data("v2".utf8)))
        #expect(fourth.spans.last?.attribution?.personID == nil)
        await #expect(throws: ArchiveError.staleSource) {
            try await store.correctSpeaker(first.source(for: first.spans[0]), feedback: .notOwner)
        }
    }

    @Test func deletingEvidenceRemovesItsLearningAndShortSpeechCannotTrain() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let other = try Fixture(); defer { other.remove() }
        let store = try fixture.store()
        let first = try await append(vector(), fixture: fixture, store: store, index: 0)
        try await store.correctSpeaker(first.source(for: first.spans[0]), feedback: .owner)
        let second = try await append(vector(), fixture: other, store: store, index: 0)
        #expect(second.spans[0].attribution?.isUser == true)
        _ = try await store.deleteSession(id: fixture.sessionID)
        #expect(try await store.readTranscript(sessionID: other.sessionID).spans[0].attribution?.isUser == false)
        let short = try await append(vector(), fixture: other, store: store, index: 1, seconds: 0.4)
        try await store.correctSpeaker(short.source(for: short.spans.last!), feedback: .owner)
        #expect(try await store.readTranscript(sessionID: other.sessionID).spans.last?.attribution?.confirmed == true)
        let following = try await append(vector(), fixture: other, store: store, index: 2)
        #expect(following.spans.last?.attribution?.isUser == false)
    }

    @Test func ambiguousPeopleAndKnownNegativeStayUnknown() {
        let a = UUID(), b = UUID()
        #expect(VoiceprintMatcher.match(vector(), examples: [
            .init(person: a, embedding: vector(), positive: true),
            .init(person: b, embedding: vector(0.99, 0.1), positive: true)]) == nil)
        #expect(VoiceprintMatcher.match(vector(), examples: [
            .init(person: a, embedding: vector(), positive: true),
            .init(person: a, embedding: vector(), positive: false)]) == nil)
    }

    @Test func shortSpeechReusesItsGroupWithoutMovingAnAnonymousAnchor() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let short = try await append(vector(), fixture: fixture, store: store, index: 0, seconds: 1.5)
        let long = try await append(vector(), fixture: fixture, store: store, index: 1)
        #expect(short.spans[0].attribution?.clusterID == long.spans[1].attribution?.clusterID)
        let inherited = try await append(vector(0.8, 0.6), fixture: fixture, store: store, index: 2, seconds: 0)
        #expect(inherited.spans[2].attribution?.clusterID == long.spans[1].attribution?.clusterID)
        #expect(inherited.spans[2].attribution?.canLearn == false)
    }

    @Test func unknownWithoutVoiceprintCanBeCorrectedWithoutTraining() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let unknown = try await append([], fixture: fixture, store: store, index: 0)
        #expect(unknown.spans[0].attribution == nil)
        try await store.correctSpeaker(unknown.source(for: unknown.spans[0]), feedback: .owner)
        let marked = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(marked.spans[0].attribution?.isUser == true)
        #expect(marked.spans[0].attribution?.confirmed == true)
        #expect(marked.spans[0].attribution?.canLearn == false)
        #expect(marked.generation == unknown.generation)
        let reopened = try fixture.store()
        let following = try await append(vector(), fixture: fixture, store: reopened, index: 1)
        #expect(following.spans[0].attribution?.isUser == true)
        #expect(following.spans[1].attribution?.personID == nil)
        await #expect(throws: ArchiveError.staleSource) {
            try await reopened.correctSpeaker(unknown.source(for: unknown.spans[0]), feedback: .notOwner)
        }
        try await reopened.correctSpeaker(following.source(for: following.spans[0]), feedback: .notOwner)
        let rejected = try await reopened.readTranscript(sessionID: fixture.sessionID)
        #expect(rejected.spans[0].attribution?.isUser == false)
        try await reopened.correctSpeaker(rejected.source(for: rejected.spans[0]), feedback: .person("小林"))
        let named = try await reopened.readTranscript(sessionID: fixture.sessionID)
        #expect(named.spans[0].speaker == "小林")
        try await reopened.correctSpeaker(named.source(for: named.spans[0]), feedback: .notOwner)
        let stillNamed = try await reopened.readTranscript(sessionID: fixture.sessionID)
        #expect(stillNamed.spans[0].speaker == "小林")
        try await reopened.correctSpeaker(stillNamed.source(for: stillNamed.spans[0]), feedback: .clear)
        let cleared = try await reopened.readTranscript(sessionID: fixture.sessionID)
        #expect(cleared.spans[0].attribution?.personID == nil)
        try await reopened.correctSpeaker(cleared.source(for: cleared.spans[0]), feedback: .owner)
        let owner = try await reopened.readTranscript(sessionID: fixture.sessionID)
        try await reopened.forgetVoiceprint(personID: #require(owner.spans[0].attribution?.personID))
        #expect(try await reopened.readTranscript(sessionID: fixture.sessionID).spans[0].attribution?.personID == nil)
    }

    @Test func namedPeopleMatchAcrossRecordingsRenameAndForget() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let other = try Fixture(); defer { other.remove() }
        let store = try fixture.store()
        let first = try await append(vector(), fixture: fixture, store: store, index: 0)
        try await store.correctSpeaker(first.source(for: first.spans[0]), feedback: .person("小林"))
        let profile = try #require(await store.speakerProfiles().first)
        #expect(profile.name == "小林" && profile.sampleCount == 1)
        await #expect(throws: VoiceprintError.self) { try await store.renameVoiceprint(personID: profile.id, name: "我") }
        #expect(try await store.speakerProfiles().first?.name == "小林")
        let reopened = try fixture.store()
        let second = try await append(vector(0.9, 0.1), fixture: other, store: reopened, index: 0)
        #expect(second.spans[0].speaker == "小林")
        #expect(second.spans[0].attribution?.confirmed == false)
        #expect(try await reopened.speakerProfiles().first?.sampleCount == 1)
        try await reopened.renameVoiceprint(personID: profile.id, name: "林老师")
        #expect(try await reopened.readTranscript(sessionID: other.sessionID).spans[0].speaker == "林老师")
        let document = try await reopened.readTranscript(sessionID: other.sessionID)
        try await reopened.correctSpeaker(document.source(for: document.spans[0]), feedback: .knownPerson(profile.id))
        #expect(try await reopened.speakerProfiles().first?.sampleCount == 2)
        try await reopened.forgetVoiceprint(personID: profile.id)
        #expect(try await reopened.speakerProfiles().isEmpty)
        #expect(try await reopened.readTranscript(sessionID: other.sessionID).spans[0].attribution?.personID == nil)
    }

    @Test func correctingAnyPersonChangesFutureMatchingAndCanBeReversed() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await append(vector(), fixture: fixture, store: store, index: 0)
        try await store.correctSpeaker(first.source(for: first.spans[0]), feedback: .person("甲"))
        let person = try #require(await store.speakerProfiles().first?.id)
        let second = try await append(vector(0.8, 0.6), fixture: fixture, store: store, index: 1)
        #expect(second.spans[1].attribution?.personID == person)
        try await store.correctSpeaker(second.source(for: second.spans[1]), feedback: .notPerson(person))
        let third = try await append(vector(0.8, 0.6), fixture: fixture, store: store, index: 2)
        #expect(third.spans[2].attribution?.personID == nil)
        #expect(try await store.speakerProfiles().first?.correctionCount == 1)
        try await store.correctSpeaker(third.source(for: third.spans[1]), feedback: .person("乙"))
        let repaired = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(repaired.spans[2].speaker == "乙")
        // The negative is removed when that exact observation is corrected back to A.
        try await store.correctSpeaker(repaired.source(for: repaired.spans[1]), feedback: .knownPerson(person))
        let profiles = try await store.speakerProfiles()
        #expect(profiles.first { $0.id == person }?.correctionCount == 0)
        #expect(profiles.first { $0.id == person }?.sampleCount == 2)
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).spans[2].speaker == "甲")
    }

    @Test func explicitGroupConfirmationTeachesCleanMembersAndSelectionCorrectionStaysLocal() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await append(vector(), fixture: fixture, store: store, index: 0, seconds: 0.4)
        let current = try await append(vector(), fixture: fixture, store: store, index: 1)
        let preview = try await store.speakerFeedbackPreview([current.source(for: current.spans[0])])
        #expect(preview.count == 2 && preview.learnableCount == 1 && preview.selectionLearnableCount == 0)
        try await store.correctSpeakers([current.source(for: current.spans[0])], feedback: .owner, scope: .cluster)
        let owned = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(owned.spans.allSatisfy { $0.attribution?.isUser == true && $0.attribution?.confirmed == true })
        #expect(try await store.speakerProfiles().first?.sampleCount == 1)
        let next = try await append(vector(), fixture: fixture, store: store, index: 2)
        #expect(next.spans.last?.speaker == "我")
        let locations = try await store.transcriptLocations(document: next)
        #expect(next.readingTurns(locations: locations).count == 1)
        try await store.correctSpeakers([next.source(for: next.spans[0])], feedback: .person("另一位"), scope: .selection)
        let corrected = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(corrected.spans[0].speaker == "另一位")
        #expect(corrected.spans[0].attribution?.clusterID != corrected.spans[1].attribution?.clusterID)
        #expect(corrected.spans[1].speaker == "我")
        #expect(corrected.spans[2].speaker == "我")
    }

    @Test func ineligibleLabelsCannotCrowdOutVoiceprintBank() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        var doc = try await append(vector(), fixture: fixture, store: store, index: 0)
        // More ultra-short (< 0.8 s) labels than either bank slice used to hide a valid middle anchor.
        for i in 1...70 { doc = try await append(vector(), fixture: fixture, store: store, index: i, seconds: i == 35 ? 4 : 0.4) }
        try await store.correctSpeakers(doc.spans.map { doc.source(for: $0) }, feedback: .owner)
        #expect(try await store.speakerProfiles().first?.sampleCount == 2)
        let next = try await append(vector(), fixture: fixture, store: store, index: 71)
        #expect(next.spans.last?.attribution?.isUser == true)
    }

    @Test func oldOwnerRejectionsMigrateAndLabelUpgradeIsIdempotent() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await append(vector(), fixture: fixture, store: store, index: 0)
        try await store.correctSpeaker(first.source(for: first.spans[0]), feedback: .owner)
        let second = try await append(vector(0.8, 0.6), fixture: fixture, store: store, index: 1)
        try await store.correctSpeaker(second.source(for: second.spans[1]), feedback: .notOwner)
        try await store.makeVoiceSchemaThirteen()
        let reopened = try fixture.store()
        #expect(try await reopened.speakerProfiles().first?.correctionCount == 1)
        try await reopened.upgradeSpeakerProfilesIfNeeded()
        let current = try await reopened.readTranscript(sessionID: fixture.sessionID)
        try await reopened.upgradeSpeakerProfilesIfNeeded()
        #expect(try await reopened.readTranscript(sessionID: fixture.sessionID).version == current.version)
        let next = try await append(vector(0.8, 0.6), fixture: fixture, store: reopened, index: 2)
        #expect(next.spans.last?.attribution?.isUser == false)
        #expect(next.spans.first?.attribution?.confirmed == true)
    }

    @Test func localDiarizationCannotLinkSurvivesLaterShortClipAbsorption() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await append(vector(), fixture: fixture, store: store, index: 0)
        try await store.checkCannotLink(session: fixture.sessionID, revision: revision, vector: vector())
        #expect(first.spans.count == 1)
    }

    @Test(arguments: [2, 5]) func localSpeakerNumbersConflictOnlyInTheSameSegmentationWindow(secondLocalID: Int) async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let doc = try await append(vector(), fixture: fixture, store: store, index: 0, seconds: 1.5, secondLocalID: secondLocalID)
        #expect(doc.spans.count == 2)
        #expect((doc.spans[0].attribution?.clusterID == doc.spans[1].attribution?.clusterID) == (secondLocalID == 5))
        #expect(doc.spans[1].startsNewSpeakerTurn == (secondLocalID != 5))
    }

    @Test func shortConversationalLabelsLearnAndMultiPrototypeSubcentersBridgeChannels() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let other = try Fixture(); defer { other.remove() }
        let store = try fixture.store()
        // Two 1.1 s conversational turns learn a reliable weighted prototype even when < 3 s each.
        _ = try await append(vector(1, 0.05), fixture: fixture, store: store, index: 0, seconds: 1.1)
        let d1 = try await append(vector(0.98, 0.15), fixture: fixture, store: store, index: 1, seconds: 1.2)
        try await store.correctSpeakers(d1.spans.map { d1.source(for: $0) }, feedback: .person("子然"))
        #expect(try await store.speakerProfiles().first(where: { $0.name == "子然" })?.sampleCount == 2)

        // Add a far-field Watch channel mode for the same speaker; sub-centers preserve both modes!
        let farField = try await append(vector(0.25, 0.968), fixture: fixture, store: store, index: 2, seconds: 3.5)
        try await store.correctSpeaker(farField.source(for: farField.spans[2]), feedback: .person("子然"))
        let prototypes = try await store.enrolledSpeakerPrototypes()
        #expect(prototypes.count >= 2)

        let nearQuery = try await append(vector(0.99, 0.08), fixture: other, store: store, index: 0, seconds: 1.8)
        let farQuery = try await append(vector(0.28, 0.96), fixture: other, store: store, index: 1, seconds: 1.8)
        #expect(nearQuery.spans[0].speaker == "子然")
        #expect(farQuery.spans[1].speaker == "子然")
    }

    @Test func nonOwnerLabelNeverPoisonsOwnerAndClusterAssistsNoisyShortUtterance() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let other = try Fixture(); defer { other.remove() }
        let store = try fixture.store()
        let first = try await append(vector(1, 0), fixture: fixture, store: store, index: 0, seconds: 4.0)
        try await store.correctSpeaker(first.source(for: first.spans[0]), feedback: .owner)

        // Labeling a contaminated mixed turn (~0.88 similar to owner) as another speaker must NOT
        // insert a voice_rejection against owner that cripples future owner recognition.
        let mixed = try await append(vector(0.88, 0.475, 0), fixture: fixture, store: store, index: 1, seconds: 3.2)
        try await store.correctSpeaker(mixed.source(for: mixed.spans[1]), feedback: .person("明樟"))
        let profiles = try await store.speakerProfiles()
        #expect(profiles.first(where: \.isUser)?.correctionCount == 0)

        // Build a strong owner cluster in a new session, then append a noisy short 0.9 s turn
        // (cos = 0.71 to owner in orthogonal z-noise, below standalone 0.74 threshold, but 0.865 to cluster).
        _ = try await append(vector(0.96, 0, 0.28), fixture: other, store: store, index: 0, seconds: 4.0)
        let assisted = try await append(vector(0.71, 0, 0.704), fixture: other, store: store, index: 1, seconds: 0.9)
        #expect(assisted.spans[1].attribution?.isUser == true)
    }

    @Test func constrainedClusterReconciliationAndV3UpgradeCollapseFragmentedSessionClusters() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await append(vector(1, 0.02), fixture: fixture, store: store, index: 0, seconds: 3.5)
        _ = try await append(vector(0.99, 0.08), fixture: fixture, store: store, index: 1, seconds: 3.2)
        let third = try await append(vector(0.98, 0.12), fixture: fixture, store: store, index: 2, seconds: 2.1)
        try await store.simulateLegacyFragmentationAndOwnerPoisoning(session: fixture.sessionID, spans: third.spans, revision: revision)
        try await store.upgradeSpeakerProfilesIfNeeded()
        let upgraded = try await store.readTranscript(sessionID: fixture.sessionID)
        let clusterIDs = Set(upgraded.spans.compactMap { $0.attribution?.clusterID })
        #expect(clusterIDs.count == 1)
        #expect(upgraded.spans.allSatisfy { $0.attribution?.isUser == true })
    }

    @Test func chimeraExemplarIsSanitizedAndBuild16UnconfirmedSessionIsRequeuedSafely() async throws {
        let enrollment = try Fixture(); defer { enrollment.remove() }
        let unconfirmedBuild16 = try Fixture(); defer { unconfirmedBuild16.remove() }
        let confirmedBuild16 = try Fixture(); defer { confirmedBuild16.remove() }
        let store = try enrollment.store()

        // 1. Enroll owner ("我") cleanly and "明樟" with two clean turns plus a 10 s mixed [我 + 明樟] chimera exemplar.
        _ = try await append(vector(1, 0, 0), fixture: enrollment, store: store, index: 0, seconds: 4.0)
        _ = try await append(vector(0, 1, 0), fixture: enrollment, store: store, index: 1, seconds: 3.5)
        _ = try await append(vector(0.05, 0.998, 0), fixture: enrollment, store: store, index: 2, seconds: 3.5)
        var enrolledDoc = try await append(vector(0.86, 0.51, 0), fixture: enrollment, store: store, index: 3, seconds: 10.0)
        try await store.correctSpeakers([enrolledDoc.source(for: enrolledDoc.spans[0])], feedback: .owner, scope: .selection)
        enrolledDoc = try await store.readTranscript(sessionID: enrollment.sessionID)
        try await store.correctSpeakers([enrolledDoc.source(for: enrolledDoc.spans[1])], feedback: .person("明樟"), scope: .selection)
        enrolledDoc = try await store.readTranscript(sessionID: enrollment.sessionID)
        try await store.correctSpeakers([enrolledDoc.source(for: enrolledDoc.spans[2])], feedback: .person("明樟"), scope: .selection)
        enrolledDoc = try await store.readTranscript(sessionID: enrollment.sessionID)
        try await store.correctSpeakers([enrolledDoc.source(for: enrolledDoc.spans[3])], feedback: .person("明樟"), scope: .selection)

        let profiles = try await store.speakerProfiles()
        let mingID = try #require(profiles.first(where: { $0.name == "明樟" })?.id)
        let prototypes = try await store.enrolledSpeakerPrototypes()
        let mingProtos = prototypes.filter { $0.personID == mingID }
        #expect(!mingProtos.isEmpty)
        for proto in mingProtos {
            let leakToOwner = proto.embedding[0]
            #expect(leakToOwner < 0.35)
        }

        // 2. Build 16/17 unconfirmed session vs confirmed session under speaker_profiles_v5 upgrade.
        let unconfirmedInitial = try await append(vector(0.90, 0.25, 0.35), fixture: unconfirmedBuild16, store: store, index: 0, seconds: 3.8)
        #expect(unconfirmedInitial.spans[0].attribution?.isUser == true)

        let confirmedInitial = try await append(vector(0.14, 0.96, 0.24), fixture: confirmedBuild16, store: store, index: 0, seconds: 3.8)
        #expect(confirmedInitial.spans[0].speaker == "明樟")
        try await store.correctSpeaker(confirmedInitial.source(for: confirmedInitial.spans[0]), feedback: .knownPerson(mingID))

        try await store.simulateBuild16PreV4State(sessions: [unconfirmedBuild16.sessionID, confirmedBuild16.sessionID])
        try await store.upgradeSpeakerProfilesIfNeeded()
        try await replanAndAnalyze(fixture: unconfirmedBuild16, store: store)

        // Confirmed Build 16 session keeps 100% of its spans and labels untouched.
        let preserved = try await store.readTranscript(sessionID: confirmedBuild16.sessionID)
        #expect(preserved.spans.count == 1)
        #expect(preserved.spans[0].speaker == "明樟")
        #expect(preserved.spans[0].attribution?.confirmed == true)

        // Unconfirmed Build 16 session is cleanly reset and its window re-queued for split re-diarization.
        let resetDoc = try await store.readTranscript(sessionID: unconfirmedBuild16.sessionID)
        #expect(resetDoc.spans.isEmpty)
        let fingerprint = ContentHash.sha256(Data("voiceprint-window".utf8))
        let ticket = try #require(await store.claimTranscriptionWindow(
            configurationFingerprint: fingerprint,
            sessionID: unconfirmedBuild16.sessionID,
            expectedGeneration: resetDoc.generation))
        let frames = ticket.window.coreFrames
        let splitDoc = try await store.commitWindowTranscript(ticket: ticket, text: "前半句后半句", rawResult: Data(), speakerParts: [
            .init(text: "前半句", frames: try FrameRange(start: frames.start, count: 32_000),
                  evidence: .init(start: 0, end: 2, localSpeaker: 1, embedding: vector(0.90, 0.25, 0.35), cleanSeconds: 2.0, modelRevision: revision)),
            .init(text: "后半句", frames: try FrameRange(start: frames.start + 32_000, count: 32_000),
                  evidence: .init(start: 2, end: 4, localSpeaker: 2, embedding: vector(0.14, 0.96, 0.24), cleanSeconds: 2.0, modelRevision: revision))
        ])
        #expect(splitDoc.spans.count == 2)
        #expect(splitDoc.spans[0].speaker == "我")
        #expect(splitDoc.spans[1].speaker == "明樟")
    }

    @Test func reverberantRoomConeAndBulkClusterContaminationAreDecontaminated() {
        func coneVec(cone: Float = 0.90, coneAxis: Int = 0, spkAxis: Int, spkAmp: Float = 0.435, jitterAxis: Int = 10, jitter: Float = 0.0) -> [Float] {
            var v = Array(repeating: Float(0), count: 256)
            v[coneAxis] = cone
            v[spkAxis] = spkAmp
            v[jitterAxis] = jitter
            return VoiceprintPolicy.normalized(v)!
        }
        let owner = UUID(), ming = UUID(), ziran = UUID(), shuya = UUID()
        var bank: [VoiceprintExample] = [
            // 3 careful per-turn confirmations for owner (axis 1)
            .init(person: owner, embedding: coneVec(spkAxis: 1, jitterAxis: 11, jitter: 0.03), positive: true, cleanSeconds: 3.0, spanDuration: 3.0, batchKey: "s1:1"),
            .init(person: owner, embedding: coneVec(spkAxis: 1, jitterAxis: 12, jitter: -0.02), positive: true, cleanSeconds: 3.2, spanDuration: 3.2, batchKey: "s1:2"),
            .init(person: owner, embedding: coneVec(spkAxis: 1, jitterAxis: 13, jitter: 0.02), positive: true, cleanSeconds: 2.8, spanDuration: 2.8, batchKey: "s2:1"),
            // Colleagues on axes 2, 3, 4
            .init(person: ming, embedding: coneVec(spkAxis: 2, jitterAxis: 14, jitter: 0.02), positive: true, cleanSeconds: 3.5, spanDuration: 3.5, batchKey: "s3:1"),
            .init(person: ming, embedding: coneVec(spkAxis: 2, jitterAxis: 15, jitter: -0.02), positive: true, cleanSeconds: 3.1, spanDuration: 3.1, batchKey: "s3:2"),
            .init(person: ziran, embedding: coneVec(spkAxis: 3, jitterAxis: 16, jitter: 0.01), positive: true, cleanSeconds: 2.5, spanDuration: 2.5, batchKey: "s4:1"),
            .init(person: shuya, embedding: coneVec(spkAxis: 4, jitterAxis: 17, jitter: 0.01), positive: true, cleanSeconds: 3.6, spanDuration: 3.6, batchKey: "s5:1")
        ]
        // Inject 18 contaminated bulk-cluster spans (axis 2 & 3 = ming & ziran!) stamped onto owner in a single batch!
        for k in 0..<18 {
            let wrongAxis = (k % 2 == 0) ? 2 : 3
            bank.append(.init(person: owner, embedding: coneVec(spkAxis: wrongAxis, jitterAxis: 20 + k, jitter: 0.03),
                              positive: true, cleanSeconds: 3.0, spanDuration: 3.0, batchKey: "contaminatedBatch:99"))
        }

        let sanitized = VoiceprintMatcher.sanitizedExamples(bank)
        let ownerKept = sanitized.filter { $0.person == owner && $0.positive }
        #expect(ownerKept.count == 3)

        // Simulate a new session with a shifted gain/AGC cone (blending axis 0 and axis 5)
        func newSessionVec(spkAxis: Int) -> [Float] {
            var v = Array(repeating: Float(0), count: 256)
            v[0] = 0.72
            v[5] = 0.50
            v[spkAxis] = 0.47
            return VoiceprintPolicy.normalized(v)!
        }
        let sessionSamples = [1, 2, 3, 4].map(newSessionVec)
        var sessMean = Array(repeating: Float(0), count: 256)
        for s in sessionSamples {
            for d in 0..<256 { sessMean[d] += s[d] * 0.25 }
        }
        let sessNorm = sqrt(sessMean.reduce(Float(0)) { $0 + $1 * $1 })
        let sessCone = VoiceprintCone(mean: sessMean, strength: min(0.90, (sessNorm - 0.72) / 0.20 * 0.90))

        #expect(VoiceprintMatcher.match(newSessionVec(spkAxis: 1), sessionCone: sessCone, examples: bank) == owner)
        #expect(VoiceprintMatcher.match(newSessionVec(spkAxis: 2), sessionCone: sessCone, examples: bank) == ming)
        #expect(VoiceprintMatcher.match(newSessionVec(spkAxis: 3), sessionCone: sessCone, examples: bank) == ziran)
        #expect(VoiceprintMatcher.match(newSessionVec(spkAxis: 4), sessionCone: sessCone, examples: bank) == shuya)
        // Unknown 5th speaker on axis 6 must stay nil rather than false-matching!
        #expect(VoiceprintMatcher.match(newSessionVec(spkAxis: 6), sessionCone: sessCone, examples: bank) == nil)
    }

    @Test func v6MigratesLegacyWeSpeakerSeeds192DimAndDecontaminatesBulkClusterConfirmations() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let legacyRev = VoiceprintPolicy.legacyWeSpeakerRevision
        let eresRev = ContentHash.sha256(Data("eres2netv2-192d".utf8))
        func vec192(_ x: Float, _ y: Float, _ z: Float = 0) -> [Float] {
            var v = Array(repeating: Float(0), count: 192)
            v[0] = x; v[1] = y; v[2] = z
            return VoiceprintPolicy.normalized(v)!
        }

        // Window 0: careful single-turn confirmation of "我" (originally unsplit 4s span that actually had [我 + haoyu])
        _ = try await append(vector(1, 0, 0), fixture: fixture, store: store, index: 0, model: legacyRev, seconds: 4.0)
        // Window 1: careful single-turn confirmation of "haoyu"
        _ = try await append(vector(0, 1, 0), fixture: fixture, store: store, index: 1, model: legacyRev, seconds: 3.6)
        // Windows 2..5: 4 turns in one cluster bulk-confirmed as "mingjue" (where Window 5 was actually haoyu!)
        _ = try await append(vector(0, 0, 1), fixture: fixture, store: store, index: 2, model: legacyRev, seconds: 3.5)
        _ = try await append(vector(0.02, 0, 0.999), fixture: fixture, store: store, index: 3, model: legacyRev, seconds: 3.5)
        _ = try await append(vector(-0.02, 0, 0.999), fixture: fixture, store: store, index: 4, model: legacyRev, seconds: 3.5)
        var doc = try await append(vector(0, 0.03, 0.999), fixture: fixture, store: store, index: 5, model: legacyRev, seconds: 3.5)

        try await store.correctSpeaker(doc.source(for: doc.spans[0]), feedback: .owner)
        doc = try await store.readTranscript(sessionID: fixture.sessionID)
        try await store.correctSpeaker(doc.source(for: doc.spans[1]), feedback: .person("haoyu"))
        doc = try await store.readTranscript(sessionID: fixture.sessionID)
        try await store.correctSpeakers([doc.source(for: doc.spans[2])], feedback: .person("mingjue"), scope: .cluster)

        let preProfiles = try await store.speakerProfiles()
        let ownerID = try #require(preProfiles.first(where: \.isUser)?.id)
        let haoyuID = try #require(preProfiles.first(where: { $0.name == "haoyu" })?.id)
        let mingjueID = try #require(preProfiles.first(where: { $0.name == "mingjue" })?.id)

        // Trigger v6 upgrade: snapshots anchors and re-queues all 6 windows of the retained legacy session.
        try await store.simulatePreV6State()
        try await store.upgradeSpeakerProfilesIfNeeded()
        try await replanAndAnalyze(fixture: fixture, store: store)
        let afterReset = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(afterReset.spans.isEmpty)

        // Drain seed candidates into 192-dim ERes2NetV2 seeds (Window 0 is impure multi-speaker -> returns nil!).
        var seededCount = 0
        while let candidate = try await store.claimNextVoiceprintSeedCandidate(modelRevision: eresRev) {
            let seed: (embedding: [Float], cleanSeconds: Double)?
            if candidate.frames.start == 0 {
                // Impure multi-speaker span rejected by MoMoExtractCleanVoiceprint!
                seed = nil
            } else if candidate.personID == ownerID {
                seed = (vec192(1, 0, 0), 3.2)
            } else if candidate.personID == haoyuID {
                seed = (vec192(0, 1, 0), 3.4)
            } else if candidate.frames.start == 5 * 64_000 {
                // Window 5 was actually haoyu's voice inside mingjue's bulk cluster!
                seed = (vec192(0.04, 0.999, 0), 3.1)
            } else {
                seed = (vec192(0, 0, 1), 3.3)
            }
            try await store.completeVoiceprintSeedCandidate(candidate, modelRevision: eresRev, extracted: seed)
            if seed != nil { seededCount += 1 }
        }
        #expect(seededCount == 5)

        // Prototypes are immediately available BEFORE Window 0 is re-transcribed, and contaminated seed is sanitized!
        let seededPrototypes = try await store.enrolledSpeakerPrototypes().filter { $0.modelRevision == eresRev }
        #expect(seededPrototypes.contains { $0.personID == haoyuID && $0.embedding.count == 192 })
        #expect(seededPrototypes.contains { $0.personID == mingjueID && $0.embedding.count == 192 })
        for p in seededPrototypes where p.personID == mingjueID {
            #expect(p.embedding[1] < 0.25)
        }

        let fingerprint = ContentHash.sha256(Data("voiceprint-window".utf8))
        // Re-transcribe Window 0 as a newly SPLIT 2-speaker window: [我 (0..2s) + haoyu (2..4s)]!
        let t0 = try #require(await store.claimTranscriptionWindow(
            configurationFingerprint: fingerprint, sessionID: fixture.sessionID, expectedGeneration: afterReset.generation))
        _ = try await store.commitWindowTranscript(ticket: t0, text: "前半我后半浩宇", rawResult: Data(), speakerParts: [
            .init(text: "前半我", frames: try FrameRange(start: 0, count: 32_000),
                  evidence: .init(start: 0, end: 2, localSpeaker: 1, embedding: vec192(1, 0.05, 0), cleanSeconds: 1.9, modelRevision: eresRev)),
            .init(text: "后半浩宇", frames: try FrameRange(start: 32_000, count: 32_000),
                  evidence: .init(start: 2, end: 4, localSpeaker: 2, embedding: vec192(0.04, 0.999, 0), cleanSeconds: 1.9, modelRevision: eresRev))
        ])

        // Re-transcribe Window 1 (single-turn unsplit confirmation of haoyu): restores confirmed=true & retires seed without double-counting!
        let t1 = try #require(await store.claimTranscriptionWindow(
            configurationFingerprint: fingerprint, sessionID: fixture.sessionID, expectedGeneration: afterReset.generation))
        _ = try await store.commitWindowTranscript(ticket: t1, text: "浩宇单句", rawResult: Data(), speakerParts: [
            .init(text: "浩宇单句", frames: t1.window.coreFrames,
                  evidence: .init(start: 0, end: 4, localSpeaker: 2, embedding: vec192(0.02, 0.999, 0), cleanSeconds: 3.4, modelRevision: eresRev))
        ])

        // Re-transcribe Windows 2..5 (formerly bulk-confirmed as mingjue, where Window 5 is actually haoyu!):
        for idx in 2...5 {
            let tk = try #require(await store.claimTranscriptionWindow(
                configurationFingerprint: fingerprint, sessionID: fixture.sessionID, expectedGeneration: afterReset.generation))
            let emb = (idx == 5) ? vec192(0.03, 0.999, 0) : vec192(0, 0.02, 0.999)
            let localSpk = (idx == 5) ? 2 : 3
            _ = try await store.commitWindowTranscript(ticket: tk, text: "测试\(idx)", rawResult: Data(), speakerParts: [
                .init(text: "测试\(idx)", frames: tk.window.coreFrames,
                      evidence: .init(start: 0, end: 4, localSpeaker: localSpk, embedding: emb, cleanSeconds: 3.3, modelRevision: eresRev))
            ])
        }

        let finalDoc = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(finalDoc.spans.count == 7)
        // Window 0's second half is cleanly attributed to haoyu, NOT poisoned by Window 0's old unsplit owner label!
        #expect(finalDoc.spans[1].speaker == "haoyu")
        #expect(finalDoc.spans[1].attribution?.confirmed == false)
        // Window 1's single-turn label is restored as confirmed!
        #expect(finalDoc.spans[2].speaker == "haoyu")
        #expect(finalDoc.spans[2].attribution?.confirmed == true)
        // Windows 2..4 keep mingjue, while Window 5 (contaminated bulk item) is rescued as haoyu!
        #expect(finalDoc.spans[3].speaker == "mingjue")
        #expect(finalDoc.spans[4].speaker == "mingjue")
        #expect(finalDoc.spans[5].speaker == "mingjue")
        #expect(finalDoc.spans[6].speaker == "haoyu")
        #expect(finalDoc.spans[6].attribution?.confirmed == false)
        // Single-turn seed for haoyu was retired onto the live observation so sampleCount is 1, not 2!
        #expect(try await store.speakerProfiles().first(where: { $0.id == haoyuID })?.sampleCount == 1)
    }

    @Test func confirmingSingleShort192DimTurnPropagatesAcrossCurrentAndHistoricalRecordings() async throws {
        let current = try Fixture(), history = try Fixture()
        defer { current.remove(); history.remove() }
        let store = try current.store()
        let eresRev = ContentHash.sha256(Data("momo-speakers-2/pyannote-seg3+3dspeaker-eres2netv2/v1".utf8))
        func unit192(_ a: Float, _ b: Float, _ c: Float) -> [Float] {
            let norm = sqrt(a * a + b * b + c * c)
            return [a / norm, b / norm, c / norm] + Array(repeating: 0, count: 189)
        }

        // Historical recording: two turns of Alice (realistic ERes2NetV2 cosine ~0.46 to confirmed clip, plus a short 0.50s sibling)
        // and one turn of Bob (impostor cosine ~0.10).
        _ = try await append(unit192(0.47, 0.8827, 0), fixture: history, store: store, index: 0, model: eresRev, seconds: 1.6)
        _ = try await append(unit192(0.38, 0.9250, 0), fixture: history, store: store, index: 1, model: eresRev, seconds: 0.50)
        _ = try await append(unit192(0.10, 0, 0.9950), fixture: history, store: store, index: 2, model: eresRev, seconds: 2.0)

        // Current recording: user taps ONLY ONE short (0.50s) turn of Alice, while a second turn of Alice in the same recording
        // has conversational acoustic drift (cosine ~0.45).
        _ = try await append(unit192(1.0, 0, 0), fixture: current, store: store, index: 0, model: eresRev, seconds: 0.50)
        let currentBefore = try await append(unit192(0.45, 0.8930, 0), fixture: current, store: store, index: 1, model: eresRev, seconds: 1.4)
        #expect(currentBefore.spans.count == 2)

        try await store.correctSpeaker(currentBefore.source(for: currentBefore.spans[0]), feedback: .person("小陈"))
        let updatedCurrent = try await store.readTranscript(sessionID: current.sessionID)
        // Both turns in the current recording are labeled "小陈" after 1 click!
        #expect(updatedCurrent.spans.map(\.speaker) == ["小陈", "小陈"])
        // And the short 0.50s confirmed turn immediately registered a voiceprint exemplar + enqueued seed extraction!
        let profile = try #require(await store.speakerProfiles().first(where: { $0.name == "小陈" }))
        #expect(profile.sampleCount >= 1)

        // Historical recording automatically gets both Alice turns matched (including the 0.50s sibling via cluster coherence + transductive bridging)
        // while Bob remains unmatched!
        let updatedHistory = try await store.readTranscript(sessionID: history.sessionID)
        #expect(updatedHistory.spans[0].speaker == "小陈")
        #expect(updatedHistory.spans[1].speaker == "小陈")
        #expect(updatedHistory.spans[2].speaker != "小陈")

        // Explicit global rematch remains fast and idempotent.
        _ = try await store.rematchAllSpeakers()
        let rematchedHistory = try await store.readTranscript(sessionID: history.sessionID)
        #expect(rematchedHistory.spans[0].speaker == "小陈")
        #expect(rematchedHistory.spans[1].speaker == "小陈")
        #expect(rematchedHistory.spans[2].speaker != "小陈")
    }

    /// A requeued session is re-planned from audio; stand in for the analysis pass with one window per chunk.
    private func replanAndAnalyze(fixture: Fixture, store: ArchiveStore) async throws {
        let fingerprint = ContentHash.sha256(Data("voiceprint-window".utf8))
        _ = try await store.replanRequestedAnalysis(configurationFingerprint: fingerprint)
        let generation = try await store.readTranscript(sessionID: fixture.sessionID).generation
        var replayed = false
        while let ticket = try await store.claimEpochAnalysis(configurationFingerprint: fingerprint,
                                                              sessionID: fixture.sessionID, expectedGeneration: generation) {
            if !replayed { #expect(ticket.checkpoint == nil) }
            replayed = true
            let lower = ticket.checkpoint?.sourceFrame ?? 0
            let upper = min(try #require(ticket.inputs.last).envelope.manifest.frames.end, ticket.boundary.endFrame ?? .max)
            let windows = try ticket.inputs.filter { $0.envelope.manifest.frames.start >= lower && $0.envelope.manifest.frames.end <= upper }.map { input in
                let manifest = input.envelope.manifest, frames = manifest.frames
                // One window per chunk, anchored at its own chunk like the original append.
                let model = try FrameRange(start: 0, count: frames.count)
                return ArchiveAnalysisWindow(id: ContentHash.sha256(Data("\(fixture.sessionID)-\(frames.start / 64_000)".utf8)),
                    sessionID: fixture.sessionID, epochID: fixture.epochID, analysisAnchor: frames.start, coreFrames: frames, contextFrames: frames,
                    modelCoreFrames: model, modelContextFrames: model,
                    sources: [.init(chunkID: manifest.chunkID, manifestSHA256: input.envelope.manifestSHA256,
                                    audioSHA256: manifest.audioSHA256, sourceFrames: frames)],
                    configurationFingerprint: fingerprint)
            }
            try await store.commitAnalysisBatch(ticket: ticket, windows: windows,
                analyzedCoverage: [try FrameRange(start: lower, count: upper - lower)], noSpeechCoverage: [],
                checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID, epochID: fixture.epochID,
                    sourceFrame: upper, configurationFingerprint: fingerprint), waitingForMoreAudio: true)
        }
        #expect(replayed)
    }

    private func append(_ embedding: [Float], fixture: Fixture, store: ArchiveStore, index: Int,
                        model: String? = nil, seconds: Double = 4, secondLocalID: Int? = nil) async throws -> TranscriptDocument {
        let fingerprint = ContentHash.sha256(Data("voiceprint-window".utf8))
        let envelope = try fixture.envelope(startFrame: Int64(index) * 64_000, frameCount: 64_000, sequence: Int64(index))
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let manifest = envelope.manifest, frames = manifest.frames
        let window = ArchiveAnalysisWindow(id: ContentHash.sha256(Data("\(fixture.sessionID)-\(index)".utf8)), sessionID: fixture.sessionID,
            epochID: fixture.epochID, analysisAnchor: ticket.checkpoint?.sourceFrame ?? 0, coreFrames: frames, contextFrames: frames,
            modelCoreFrames: try FrameRange(start: frames.start - (ticket.checkpoint?.sourceFrame ?? 0), count: frames.count),
            modelContextFrames: try FrameRange(start: frames.start - (ticket.checkpoint?.sourceFrame ?? 0), count: frames.count),
            sources: [.init(chunkID: manifest.chunkID, manifestSHA256: envelope.manifestSHA256, audioSHA256: manifest.audioSHA256, sourceFrames: frames)],
            configurationFingerprint: fingerprint)
        try await store.commitAnalysisBatch(ticket: ticket, windows: [window], analyzedCoverage: [frames], noSpeechCoverage: [],
            checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID, epochID: fixture.epochID, sourceFrame: frames.end,
                configurationFingerprint: fingerprint), waitingForMoreAudio: true)
        let recognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        var parts = [SpeakerTranscriptPart(text: "声纹测试 \(index)", frames: frames,
            evidence: .init(start: 0, end: 4, localSpeaker: 1, embedding: embedding, cleanSeconds: seconds, modelRevision: model ?? revision))]
        if let secondLocalID {
            parts = [
                .init(text: "声纹", frames: try FrameRange(start: frames.start, count: 32_000),
                      evidence: .init(start: 0, end: 2, localSpeaker: 1, embedding: embedding, cleanSeconds: seconds, modelRevision: model ?? revision)),
                .init(text: "测试 \(index)", frames: try FrameRange(start: frames.start + 32_000, count: 32_000),
                      evidence: .init(start: 2, end: 4, localSpeaker: secondLocalID, embedding: embedding, cleanSeconds: seconds, modelRevision: model ?? revision))]
        }
        return try await store.commitWindowTranscript(ticket: recognition, text: "声纹测试 \(index)", rawResult: Data(), speakerParts: parts)
    }
}

private extension ArchiveStore {
    func checkCannotLink(session: UUID, revision: String, vector: [Float]) throws {
        let evidence = SpeakerEvidence(start: 0, end: 2, localSpeaker: 1, embedding: vector, cleanSeconds: 1.5, modelRevision: revision)
        let a = try attributeSpeaker(spanID: UUID(), sessionID: session, evidence: evidence)
        let aID = try #require(a.1?.clusterID)
        let b = try attributeSpeaker(spanID: UUID(), sessionID: session, evidence: evidence, excluding: [aID])
        let bID = try #require(b.1?.clusterID)
        #expect(aID != bID)
        _ = try reconcileSpeakerClusters(sessionID: session)
        let clusters = try database.rows("SELECT DISTINCT cluster_id FROM speaker_observations WHERE session_id=?", [.text(session.uuidString)])
        #expect(clusters.count == 2)
    }
    func makeVoiceSchemaThirteen() throws {
        try database.execute("DROP TABLE speaker_cluster_conflicts")
        try database.execute("DROP TABLE voice_rejections")
        try database.execute("PRAGMA user_version=13")
    }
    func simulateLegacyFragmentationAndOwnerPoisoning(session: UUID, spans: [TranscriptSpan], revision: String) throws {
        let ownerID = UUID(), otherID = UUID(), poisonedSpanID = UUID()
        try database.execute("INSERT INTO voice_profiles(id,name,is_owner) VALUES(?,?,1)", [.text(ownerID.uuidString), .text("我")])
        try database.execute("INSERT INTO voice_profiles(id,name,is_owner) VALUES(?,?,0)", [.text(otherID.uuidString), .text("明樟")])
        // Split every span into its own duplicate cluster as the old 0.08 ambiguity rule used to do.
        for (i, span) in spans.enumerated() {
            let dup = UUID()
            let row = try #require(try database.rows("SELECT evidence FROM speaker_observations WHERE span_id=?", [.text(span.id.uuidString)]).first)
            let data = try row.requireData(0)
            let ev = try #require(try WireJSON.decode(SpeakerEvidence?.self, from: data))
            try database.execute("INSERT INTO speaker_clusters(id,session_id,model_revision,centroid,sample_count) VALUES(?,?,?,?,1)",
                [.text(dup.uuidString), .text(session.uuidString), .text(revision), .blob(try WireJSON.encode(ev.embedding))])
            try database.execute("UPDATE speaker_observations SET cluster_id=?,confirmed_person=? WHERE span_id=?",
                [.text(dup.uuidString), i == 0 ? .text(ownerID.uuidString) : .null, .text(span.id.uuidString)])
        }
        // Simulate a legacy mixed span labeled as 明樟 that auto-inserted an owner rejection (0.99 similar to owner!).
        let poisonedCluster = UUID()
        let ownerVec: [Float] = [1] + Array(repeating: 0, count: 255)
        let poisonedEv = SpeakerEvidence(start: 0, end: 4, localSpeaker: 2, embedding: ownerVec, cleanSeconds: 4, modelRevision: revision)
        try database.execute("INSERT INTO speaker_clusters(id,session_id,model_revision,centroid,sample_count) VALUES(?,?,?,?,1)",
            [.text(poisonedCluster.uuidString), .text(session.uuidString), .text(revision), .blob(try WireJSON.encode([Float]([0, 1] + Array(repeating: 0, count: 254))))])
        try database.execute("INSERT INTO speaker_observations(span_id,session_id,cluster_id,model_revision,evidence,confirmed_person,rejected_owner,updated_at) VALUES(?,?,?,?,?,?,1,1)",
            [.text(poisonedSpanID.uuidString), .text(session.uuidString), .text(poisonedCluster.uuidString), .text(revision),
             .blob(try WireJSON.encode(poisonedEv)), .text(otherID.uuidString)])
        try database.execute("INSERT INTO voice_rejections(span_id,person_id) VALUES(?,?)",
            [.text(poisonedSpanID.uuidString), .text(ownerID.uuidString)])
        try database.execute("DELETE FROM metadata WHERE key='speaker_profiles_v3'")
    }
    func simulateBuild16PreV4State(sessions: [UUID]) throws {
        for session in sessions {
            try database.execute("UPDATE sessions SET recorded_at=1793337788 WHERE id=?", [.text(session.uuidString)])
        }
        try database.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('speaker_profiles_v4','1')")
        try database.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('speaker_profiles_v6','1')")
        try database.execute("DELETE FROM metadata WHERE key='speaker_profiles_v5'")
    }
    func simulatePreV6State() throws {
        try database.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('speaker_profiles_v2','1')")
        try database.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('speaker_profiles_v3','1')")
        try database.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('speaker_profiles_v4','1')")
        try database.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('speaker_profiles_v5','1')")
        try database.execute("DELETE FROM metadata WHERE key='speaker_profiles_v6'")
    }
}
