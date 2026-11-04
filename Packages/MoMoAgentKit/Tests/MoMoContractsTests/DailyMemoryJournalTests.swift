import Foundation
import Testing
@testable import MoMoContracts

@Suite struct DailyMemoryJournalTests {
    @Test func extractsGroundedThemesWakingHourRhythmAndPersonFreeSceneConcepts() {
        let input = DailyJournalInput(
            dayKey: "2026-11-04",
            dateLabel: "今天 · 11月4日",
            dayStartHour: 8,
            placeLabel: "三里屯",
            segments: [
                DailyJournalSegment(
                    hour: 15,
                    duration: 360,
                    text: "录音主要讨论向数据库写入链路以及 GitHub Actions 评测回归。",
                    isSummary: true
                ),
                DailyJournalSegment(
                    hour: 18,
                    duration: 1920,
                    text: "[我] 傍晚喝杯咖啡，把律所合同方案和 benchmark 维度再顺一遍。",
                    isSummary: false
                ),
                DailyJournalSegment(
                    hour: 1,
                    duration: 300,
                    text: "[我] 深夜收尾把产品交互细节记一笔。",
                    isSummary: false
                ),
            ]
        )

        #expect(input.hasReadableContent)
        let bins = input.wakingHourBins
        #expect(bins.count == 24)
        #expect(bins[10] == 1.0)
        #expect(bins[17] > 0)

        let brief = DailyJournalConceptExtractor.extract(from: input, style: .chiikawa)
        #expect(brief.headline.contains("三里屯"))
        #expect(brief.placeLabel == "三里屯")
        #expect(brief.note.contains("三里屯"))
        #expect(brief.note.contains("43 分钟"))
        #expect(brief.tags.contains("📍三里屯"))
        #expect(brief.motifs.contains(.laptop) || brief.motifs.contains(.coffee) || brief.motifs.contains(.notebook))
        #expect(brief.sceneConcepts.count >= 2)
        #expect(brief.sceneConcepts.joined(separator: " ").lowercased().contains("marshmallow") || brief.sceneConcepts.joined(separator: " ").lowercased().contains("mochi"))
        for concept in brief.sceneConcepts {
            let lower = concept.lowercased()
            #expect(!lower.contains("person"))
            #expect(!lower.contains("portrait"))
            #expect(!lower.contains("face"))
        }
    }

    @Test func chapterBuilderSplitsByHourlyIntervalAndLinksLocationVisits() {
        let baseTS: Double = 1_793_760_000 // arbitrary day anchor
        let dayInput = DailyJournalInput(
            dayKey: "2026-11-04",
            dateLabel: "今天 · 11月4日",
            dayStartHour: 8,
            segments: [
                DailyJournalSegment(hour: 9, duration: 480, text: "早上过一遍数据库设计", isSummary: true, timestamp: baseTS + 9 * 3600),
                DailyJournalSegment(hour: 14, duration: 900, text: "下午在星巴克和大家脑暴手账插画", isSummary: false, timestamp: baseTS + 14 * 3600),
                DailyJournalSegment(hour: 15, duration: 600, text: "继续对齐 API 细节", isSummary: false, timestamp: baseTS + 15 * 3600),
                DailyJournalSegment(hour: 20, duration: 420, text: "晚上复盘待办事项", isSummary: true, timestamp: baseTS + 20 * 3600),
            ]
        )
        let visits = [
            DailyJournalPlaceVisit(
                id: "v1",
                name: "北京市 朝阳区 望京SOHO",
                startTimestamp: baseTS + 8.5 * 3600,
                endTimestamp: baseTS + 11.5 * 3600
            ),
            DailyJournalPlaceVisit(
                id: "v2",
                name: "北京市 海淀区 五道口",
                startTimestamp: baseTS + 19.5 * 3600,
                endTimestamp: baseTS + 22.0 * 3600
            ),
        ]

        let chapters = DailyJournalChapterBuilder.buildChapters(
            from: dayInput,
            interval: .threeHours,
            visits: visits
        )
        #expect(chapters.count == 3)
        // Slot 0: 08:00–11:00 matched GPS visit 望京SOHO
        #expect(chapters[0].timeRangeLabel == "08:00–11:00")
        #expect(chapters[0].place?.shortLabel.contains("望京") == true)
        #expect(chapters[0].place?.isLiveLocation == true)
        // Slot 2: 14:00–17:00 inferred 星巴克 from transcript since no GPS visit overlapped
        #expect(chapters[1].timeRangeLabel == "14:00–17:00")
        #expect(chapters[1].place?.shortLabel == "星巴克")
        #expect(chapters[1].place?.isLiveLocation == false)
        // Slot 4: 20:00–23:00 matched GPS visit 五道口
        #expect(chapters[2].timeRangeLabel == "20:00–23:00")
        #expect(chapters[2].place?.shortLabel.contains("五道口") == true)
    }

    @Test func sanitizeSceneConceptsRemovesPortraitTermsAndProvidesCozyFallback() {
        let sanitized = DailyJournalConceptExtractor.sanitizeSceneConcepts(
            [
                "A portrait of two people talking in an office",
                "man and woman smiling",
                "steaming ceramic coffee cup beside open notebook"
            ],
            fallbackPalette: .twilightApricot,
            style: .chiikawa
        )
        #expect(sanitized.first == "steaming ceramic coffee cup beside open notebook")
        #expect(sanitized.count >= 2)
        #expect(!sanitized.joined(separator: " ").lowercased().contains("portrait"))
    }

    @Test func coverStoreAndPlaceStorePersistCleanly() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-journal-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let placeStore = DailyJournalPlaceStore(directory: tempDir)
        let now = Date().timeIntervalSince1970
        try placeStore.upsert(
            DailyJournalPlaceVisit(id: "p1", name: "杭州市 西湖区 西溪园区", startTimestamp: now - 600)
        )
        let places = placeStore.load(now: now)
        #expect(places.count == 1)
        #expect(places[0].shortLabel == "西湖 · 西溪园区")

        let store = DailyJournalCoverStore(directory: tempDir)
        let inputV1 = DailyJournalInput(
            dayKey: "2026-11-04-h3-s0",
            dateLabel: "11月4日 · 08:00–11:00",
            placeLabel: "西溪园区",
            segments: [DailyJournalSegment(hour: 10, duration: 120, text: "晨会讨论产品原型", isSummary: true)]
        )
        let brief = DailyJournalConceptExtractor.extract(from: inputV1, style: .chiikawa)
        let pngStub = Data([0x89, 0x50, 0x4E, 0x47])

        let autoCover = DailyJournalStoredCover(
            dayKey: inputV1.dayKey,
            fingerprint: inputV1.fingerprint,
            style: .chiikawa,
            source: .appleImageCreator,
            brief: brief
        )
        try store.save(metadata: autoCover, pngData: pngStub)

        let loaded = try #require(store.load(dayKey: inputV1.dayKey, style: .chiikawa))
        #expect(loaded.metadata.isFresh(for: inputV1))
        #expect(loaded.imageData == pngStub)

        let inputV2 = DailyJournalInput(
            dayKey: "2026-11-04-h3-s0",
            dateLabel: "11月4日 · 08:00–11:00",
            placeLabel: "三里屯",
            segments: [DailyJournalSegment(hour: 10, duration: 120, text: "晨会讨论产品原型", isSummary: true)]
        )
        // Changing location invalidates auto cover so it regenerates with the new place!
        #expect(!loaded.metadata.isFresh(for: inputV2))

        let customCover = DailyJournalStoredCover(
            dayKey: inputV1.dayKey,
            fingerprint: inputV1.fingerprint,
            style: .chiikawa,
            source: .appleImagePlaygroundSheet,
            brief: brief
        )
        try store.save(metadata: customCover, pngData: pngStub)
        let loadedCustom = try #require(store.load(dayKey: inputV1.dayKey, style: .chiikawa))
        #expect(loadedCustom.metadata.isFresh(for: inputV2))
    }
}
