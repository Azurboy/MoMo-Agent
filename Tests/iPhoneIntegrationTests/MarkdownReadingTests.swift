import Foundation
import SwiftUI
import XCTest
import MoMoArchive
import MoMoContracts
import MoMoRecording
@testable import MoMoAgent

@MainActor
final class MarkdownReadingTests: XCTestCase {
    func testBlocksPreserveInlineEmphasisAndLinksWithoutExposingMarkup() throws {
        let source = """
        ## Visit plan

        Confirm **the time** and *the place*.

        - Read [the source](https://example.com/source).

        > The date remains unconfirmed.
        """
        let document = try MarkdownDocument(source)
        XCTAssertEqual(document.blocks.map(\.plainText), ["Visit plan", "Confirm the time and the place.",
            "Read the source.", "The date remains unconfirmed."])
        XCTAssertEqual(document.blocks.first?.headingLevel, 2)
        let paragraph = try XCTUnwrap(document.blocks.first { $0.plainText.hasPrefix("Confirm") })
        XCTAssertTrue(paragraph.text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(paragraph.text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        let item = try XCTUnwrap(document.blocks.first { $0.listMarker != nil })
        XCTAssertEqual(item.listMarker, "•")
        XCTAssertEqual(item.text.runs.compactMap(\.link), [URL(string: "https://example.com/source")!])
        XCTAssertTrue(try XCTUnwrap(document.blocks.last).isQuote)
        XCTAssertEqual(Set(document.blocks.map(\.id)).count, document.blocks.count)
    }

    func testNestedListsAndContinuationParagraphsKeepTheirStructure() throws {
        let document = try MarkdownDocument("""
        3. First item.

           Another paragraph in the same item.

           - Nested detail.
        4. Last item.
        """)
        XCTAssertEqual(document.blocks.map(\.plainText), ["First item.", "Another paragraph in the same item.",
            "Nested detail.", "Last item."])
        XCTAssertEqual(document.blocks.map(\.listMarker), ["3.", nil, "•", "4."])
        XCTAssertEqual(document.blocks.map(\.listDepth), [1, 1, 2, 1])
    }

    func testIncompleteStreamingMarkdownKeepsTheAvailableWords() throws {
        for source in ["## Plan\n\n**Confirm", "## Plan\n\n**Confirm** the [source](momoagent://source/",
                       "## Plan\n\n**Confirm** the source."] {
            let text = try MarkdownDocument(source).blocks.map(\.plainText).joined(separator: "\n\n")
            XCTAssertTrue(text.contains("Plan"))
            XCTAssertTrue(text.contains("Confirm"))
        }
    }

    func testEscapedMarkersCodeAndSeparateParagraphsKeepLiteralContent() throws {
        let document = try MarkdownDocument("""
        Literal \\*asterisks\\* and `## code`.

        Next paragraph.

        ```text
        **not emphasis**
        ```
        """)
        XCTAssertEqual(document.blocks.count, 3)
        XCTAssertEqual(document.blocks[0].plainText, "Literal *asterisks* and ## code.")
        XCTAssertEqual(document.blocks[1].plainText, "Next paragraph.")
        XCTAssertTrue(document.blocks[2].isCode)
        XCTAssertTrue(document.blocks[2].plainText.contains("**not emphasis**"))
    }

    func testLongDocumentRetainsAllParagraphsAndStableBlockIdentities() throws {
        let markdown = (1...300).map { "Paragraph \($0): original words." }.joined(separator: "\n\n")
        let first = try MarkdownDocument(markdown)
        let restored = try MarkdownDocument(markdown)
        XCTAssertEqual(first.blocks.count, 300)
        XCTAssertEqual(first.blocks.map(\.id), restored.blocks.map(\.id))
        XCTAssertEqual(first.blocks.map(\.plainText), restored.blocks.map(\.plainText))
        XCTAssertEqual(first.blocks.last?.plainText, "Paragraph 300: original words.")
    }

    func testSourceURLPreservesVersionWithoutDependingOnTheLatestSyncCache() throws {
        let source = SourceReference(sessionID: UUID(), spanID: UUID(), transcriptVersion: 2, generation: 3)
        let base = "momoagent://source/\(source.sessionID)/\(source.spanID)"
        let valid = try XCTUnwrap(URL(string: base + "?version=2&generation=3"))
        XCTAssertEqual(RecordingSourceURL.source(for: valid), source)
        for suffix in ["?version=0&generation=3", "?version=2&generation=-1", "?version=2",
                       "?version=2&version=2", "?version=2&generation=3&generation=3",
                       "/extra?version=2&generation=3", "/?version=2&generation=3",
                       "?version=2&generation=3#fragment", "?version=two&generation=3",
                       "?version=02&generation=3", "?version=+2&generation=3"] {
            let url = try XCTUnwrap(URL(string: base + suffix))
            XCTAssertNil(RecordingSourceURL.source(for: url), suffix)
        }
        let malformed = try XCTUnwrap(URL(string: "momoagent://source/not-a-uuid/\(source.spanID)?version=2&generation=3"))
        XCTAssertNil(RecordingSourceURL.source(for: malformed))
    }

    func testOnlyModelAuthoredInlineCitationsBecomeLinks() throws {
        let used = SourceReference(sessionID: UUID(), spanID: UUID(), transcriptVersion: 2, generation: 3)
        let readButUnused = SourceReference(sessionID: UUID(), spanID: UUID(), transcriptVersion: 1, generation: 0)
        let markdown = "周五讨论方案。[录音1](\(used.citationURL))\n\n负责人待确认。[录音1](\(used.citationURL))"
        let document = try MarkdownDocument(markdown)
        XCTAssertEqual(document.blocks.map(\.plainText), ["周五讨论方案。录音1", "负责人待确认。录音1"])
        let links = document.blocks.flatMap { $0.text.runs.compactMap(\.link) }
        XCTAssertEqual(links.count, 2)
        for link in links {
            XCTAssertEqual(RecordingSourceURL.source(for: link), used)
        }
        XCTAssertFalse(links.contains { $0.absoluteString == readButUnused.citationURL })
        XCTAssertTrue(try MarkdownDocument("这是我的建议，未采用录音资料。").blocks
            .flatMap { $0.text.runs.compactMap(\.link) }.isEmpty)
    }

    func testNativeReadingProducesInspectableAssistantAndUserRendering() throws {
        let markdown = "## Visit plan\n\nConfirm **the time**.\n\n1. Read the source.\n2. Confirm the date.\n\n> Still unconfirmed."
        let view = VStack(alignment: .leading, spacing: 24) {
            AssistantMessageView(text: markdown, isUser: false, accessibilityID: "render.assistant")
            Divider()
            AssistantMessageView(text: "## literal **user input**", isUser: true, accessibilityID: "render.user")
        }
        .padding(24)
        .frame(width: 390)
        .background(.white).foregroundStyle(.black)
        let defaultRenderer = ImageRenderer(content: view.environment(\.dynamicTypeSize, .large))
        let defaultImage = try XCTUnwrap(defaultRenderer.uiImage)
        XCTAssertGreaterThan(defaultImage.size.height, 0)
        let attachment = XCTAttachment(image: defaultImage)
        attachment.name = "markdown-assistant-and-literal-user-default-type"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOnlyWebOrWellFormedSourceLinksReachTheArchiveResolver() throws {
        let source = SourceReference(sessionID: UUID(), spanID: UUID(), transcriptVersion: 1, generation: 0)
        let sourceURL = try XCTUnwrap(URL(string:
            "momoagent://source/\(source.sessionID)/\(source.spanID)?version=1&generation=0"))
        XCTAssertEqual(RecordingSourceURL.destination(for: sourceURL), .source(source))
        for value in ["https://example.com", "http://example.com/path"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(RecordingSourceURL.destination(for: url), .web)
        }
        for value in ["tel:123", "mailto:test@example.com", "file:///tmp/test.txt",
                      "custom://open", "javascript:alert(1)", "https:relative", "/relative"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(RecordingSourceURL.destination(for: url), .unavailable, value)
        }
    }

    func testHistoricalCitationResolvesOfflineAfterAppendButNotAfterEditOrDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SourceLink-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let sessionID = UUID()
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("fixture"),
            sessionID: sessionID, epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "source-link-test",
            sourceKind: .fixture, targetFrames: 1600, wallClockAnchor: Date(), timezoneOffset: 28800)
        var first: SourceReference?
        for index in 0..<2 {
            let chunk = try XCTUnwrap(writer.append([Int16](repeating: 0, count: 1600)).first)
            let item = try archive.inbox.preserve(fileURL: chunk.audioURL, envelope: chunk.envelope)
            _ = try await archive.commitReceivedChunk(item)
            let job = try await archive.claimAnalysisJob(configurationHash: "source-link-test")
            let ticket = try XCTUnwrap(job)
            let document = try await archive.commitTranscript(ticket: ticket, spans: [
                TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames, text: "讨论原文 \(index)")
            ])
            if index == 0 { first = document.source(for: try XCTUnwrap(document.spans.first)) }
        }
        let cited = try XCTUnwrap(first)
        let url = try XCTUnwrap(URL(string: cited.citationURL))
        guard case .source(let resolved) = RecordingSourceURL.destination(for: url) else {
            return XCTFail("The old reference must reach archive validation without a connection or sync cache")
        }
        XCTAssertEqual(resolved, cited)
        try await archive.validateSources([resolved])
        let current = try await archive.readTranscript(sessionID: sessionID)
        XCTAssertGreaterThan(current.version, resolved.transcriptVersion)
        XCTAssertEqual(current.spans.first(where: { $0.id == resolved.spanID })?.text, "讨论原文 0")
        let audio = try await archive.acquireAudioTimeline(source: resolved)
        XCTAssertFalse(audio.isEmpty)
        for part in audio { await archive.releaseAudioLease(id: part.lease.id) }

        let invented = SourceReference(sessionID: sessionID, spanID: UUID(), transcriptVersion: current.version, generation: current.generation)
        do { try await archive.validateSources([invented]); XCTFail("Unknown spans must not open") }
        catch ArchiveError.staleSource { }
        _ = try await archive.reviseTranscript(sessionID: sessionID, expectedVersion: current.version, spans: current.spans)
        do { try await archive.validateSources([resolved]); XCTFail("Edited sources must not be silently retargeted") }
        catch ArchiveError.staleSource { }
        _ = try await archive.deleteSession(id: sessionID)
        do { try await archive.validateSources([resolved]); XCTFail("Deleted sources must not open") }
        catch ArchiveError.sessionDeleted { }
    }

    func testTimelineSummaryRendersMarkdownAndPreviewStripsSyntax() throws {
        let summary = """
        本周对齐了产品首发节奏。

        ### 核心结论

        - 确认 **周五下午** 完成联调
        - 跟进手表的跨版本无感同步
        """
        let preview = MarkdownDocument.plainTextPreview(summary)
        XCTAssertEqual(preview, "本周对齐了产品首发节奏。  核心结论  确认 周五下午 完成联调  跟进手表的跨版本无感同步")
        XCTAssertFalse(preview.contains("###"))
        XCTAssertFalse(preview.contains("**"))

        let renderer = ImageRenderer(
            content: TimelineSummaryView(text: summary)
                .frame(width: 350)
                .padding(16)
                .background(.white)
                .environment(\.dynamicTypeSize, .large)
        )
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertGreaterThan(image.size.height, 80)
    }
}
