import Darwin
import Foundation
import XCTest
@testable import MoMoAgentClient

final class AgentClientTests: XCTestCase, @unchecked Sendable {
    private func client(transport: (any AgentTransport)? = nil) throws -> AgentClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIStub.self]
        return try AgentClient(baseURL: URL(string: "http://127.0.0.1:8765")!, credential: "test-secret",
                               assistantID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                               configuration: configuration, transport: transport)
    }

    func testExplicitRetryKeepsOperationAndAssistantIdentity() async throws {
        APIStub.state.reset(status: 202, body: #"{"run_id":"r1","session_id":"s1","status":"queued"}"#)
        let client = try client()
        let operation = UUID()
        _ = try await client.submit(input: "继续昨天的会议", sessionID: "s1", operationID: operation)
        _ = try await client.submit(input: "继续昨天的会议", sessionID: "s1", operationID: operation)
        let requests = APIStub.state.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Idempotency-Key"), operation.uuidString.lowercased())
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Idempotency-Key"), requests[0].value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-MoMo-Session-Key"), "momo:00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        XCTAssertEqual(requests[0].url?.path, "/v1/runs")
        XCTAssertEqual(requests[0].httpMethod, "POST")
    }

    func testCapabilitiesAcceptsTheMixedUpstreamFeatureContract() async throws {
        APIStub.state.reset(status: 200, body: #"{"features":{"run_submission":true,"run_status":true,"run_stop":false,"session_key_header":"X-MoMo-Session-Key","runs_idempotency":{"supported":true,"retention_seconds":86400},"browser_extension_control":{"enabled":false}}}"#)
        let features = try await client().capabilities().features
        XCTAssertEqual(features.runSubmission, true)
        XCTAssertEqual(features.runStatus, true)
        XCTAssertEqual(features.runStop, false)
    }

    func testUnknownOutcomeDoesNotBecomeCompletionOrTriggerAnotherRequest() async throws {
        APIStub.state.reset(status: 200, body: #"{"run_id":"r1","status":"unknown","error":"owner restarted"}"#)
        let run = try await client().run(id: "r1")
        XCTAssertFalse(run.isTerminal)
        XCTAssertEqual(run.error, "owner restarted")
        XCTAssertEqual(APIStub.state.requests().count, 1)
        XCTAssertEqual(APIStub.state.requests().first?.httpMethod, "GET")
    }

    func testConflictIsSurfacedWithoutAutomaticRetry() async throws {
        APIStub.state.reset(status: 409, body: #"{"error":{"code":"admission_conflict","message":"already claimed"}}"#)
        do {
            _ = try await client().submit(input: "different input", sessionID: "s1", operationID: UUID())
            XCTFail("Expected conflict")
        } catch AgentClientError.http(let status, let code, _, _) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(code, "admission_conflict")
        }
        XCTAssertEqual(APIStub.state.requests().count, 1)
    }

    func testStopAcceptsEmptyAcknowledgement() async throws {
        APIStub.state.reset(status: 204, body: "")
        try await client().requestStop(runID: "r1")
        XCTAssertEqual(APIStub.state.requests().first?.url?.path, "/v1/runs/r1/stop")
        XCTAssertEqual(APIStub.state.requests().first?.httpMethod, "POST")
    }

    func testRejectsPlaintextRemoteEndpointAndEmbeddedCredentials() {
        for value in ["http://192.168.1.2:8765", "https://user:pass@example.com", "https://example.com?key=secret"] {
            XCTAssertThrowsError(try AgentClient(baseURL: URL(string: value)!, credential: "test", assistantID: UUID()))
        }
    }

    func testAlternateBytesUseSameStatusAndDecodeContract() async throws {
        APIStub.state.reset(status: 500, body: "unused")
        let transport = ByteStub(status: 409, chunks: [Data(#"{"error":{"code":"admission_conflict","message":"claimed"}}"#.utf8)])
        do { _ = try await client(transport: transport).submit(input: "task", sessionID: "s1", operationID: UUID()); XCTFail("Expected conflict") }
        catch AgentClientError.http(let status, let code, _, _) { XCTAssertEqual(status, 409); XCTAssertEqual(code, "admission_conflict") }
        XCTAssertTrue(APIStub.state.requests().isEmpty)
    }

    func testAlternateFailureAfterDispatchDoesNotReplayWriteOnHTTP() async throws {
        APIStub.state.reset(status: 202, body: #"{"run_id":"r1","status":"queued"}"#)
        let transport = ByteStub(status: 202, chunks: [], fails: true)
        let client = try client(transport: transport), operation = UUID()
        do { _ = try await client.submit(input: "task", sessionID: "s1", operationID: operation); XCTFail("Expected disconnect") }
        catch URLError.networkConnectionLost { }
        XCTAssertTrue(APIStub.state.requests().isEmpty)
        await transport.useHTTP()
        let resumed = try await client.submit(input: "task", sessionID: "s1", operationID: operation)
        XCTAssertEqual(resumed.runID, "r1")
        XCTAssertEqual(APIStub.state.requests().first?.value(forHTTPHeaderField: "Idempotency-Key"), operation.uuidString.lowercased())
    }

    func testAlternateSSEParsesFragmentedUTF8AndPreservesCursor() async throws {
        let bytes = Data("data: {\"event\":\"message.delta\",\"run_id\":\"r1\",\"seq\":8,\"delta\":\"你好\"}\n\n".utf8)
        let transport = ByteStub(status: 200, chunks: bytes.map { Data([$0]) }, contentType: "text/event-stream")
        let events = EventCapture()
        try await client(transport: transport).observe(runID: "r1", after: 7) { await events.add($0) }
        let values = await events.values
        XCTAssertEqual(values.map(\.delta), ["你好"])
        let request = await transport.request
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Last-Event-ID"), "7")
    }

    func testDesktopUsesTheSameTransportAndRequiresExplicitControl() async throws {
        let status = #"{"approved":true,"screen":true,"input":true,"owner":"agent","active":false,"epoch":1}"#
        APIStub.state.reset(status: 500, body: "unused")
        let transport = ByteStub(status: 200, chunks: [Data(status.utf8)])
        let client = try client(transport: transport)
        let initial = try await client.desktopStatus()
        XCTAssertEqual(initial.owner, "agent")
        let preview = await transport.request
        XCTAssertEqual(preview?.httpMethod, "GET")
        XCTAssertEqual(preview?.url?.path, "/desktop/v1/status")
        let requestID = UUID()
        _ = try await client.desktopControl("claim", requestID: requestID)
        let claim = await transport.request
        XCTAssertEqual(claim?.httpMethod, "POST")
        let body = try XCTUnwrap(claim?.httpBody)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: body)["request_id"], requestID.uuidString)
        XCTAssertTrue(APIStub.state.requests().isEmpty)
    }

    func testRemotePointerAndKeyboardPreserveCoordinatesModifiersAndOrdering() async throws {
        let transport = ByteStub(status: 200, chunks: [Data("{}".utf8)])
        let api = try client(transport: transport)
        var event = DesktopInput(kind: "mouse_move", x: 0.25, y: 0.75, modifiers: ["shift"])
        event.sequence = 12
        try await api.desktopInput(event, session: "current")
        let sent = await transport.request
        let data = try XCTUnwrap(sent?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try XCTUnwrap(body["event"] as? [String: Any])
        XCTAssertEqual(input["sequence"] as? Int, 12)
        XCTAssertEqual(input["x"] as? Double, 0.25)
        XCTAssertEqual(input["modifiers"] as? [String], ["shift"])
        let old = try JSONDecoder().decode(DesktopStatus.self, from: Data(#"{"approved":true,"screen":true,"input":true,"owner":"agent","active":false,"epoch":1}"#.utf8))
        XCTAssertNil(old.input_sequence)
    }

    func testDesktopInputFailureIsNotAutomaticallyReplayed() async throws {
        APIStub.state.reset(status: 200, body: "{}")
        let transport = ByteStub(status: 200, chunks: [], fails: true)
        let eventID = UUID()
        do {
            try await client(transport: transport).desktopInput(.init(kind: "click", x: 0.2, y: 0.5), session: "owned-session", eventID: eventID)
            XCTFail("Expected disconnect")
        } catch URLError.networkConnectionLost { }
        let request = await transport.request
        let body = try XCTUnwrap(request?.httpBody)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(value["event_id"] as? String, eventID.uuidString)
        XCTAssertEqual(value["session"] as? String, "owned-session")
        XCTAssertEqual(request?.url?.path, "/desktop/v1/input")
        XCTAssertTrue(APIStub.state.requests().isEmpty)
    }

    func testAlternateResponseLimitFailsExplicitly() async throws {
        let transport = ByteStub(status: 200, chunks: [Data(repeating: 32, count: 8 * 1024 * 1024 + 1)])
        do { _ = try await client(transport: transport).capabilities(); XCTFail("Expected size limit") }
        catch AgentClientError.responseTooLarge { }
    }

    func testPrivateTransportNeverFallsBackForTasksSyncOrSSE() async throws {
        APIStub.state.reset(status: 200, body: "{}")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIStub.self]
        let endpoint = URL(string: "http://100.64.0.1:8767")!
        XCTAssertThrowsError(try AgentClient(baseURL: endpoint, credential: "secret", assistantID: UUID()))
        for url in ["http://example.com:8767", "http://192.168.1.1:8767", "http://100.128.0.1:8767"] {
            XCTAssertThrowsError(try AgentClient(baseURL: URL(string: url)!, credential: "secret", assistantID: UUID(), transport: UnavailablePrivateRoute()))
        }
        let client = try AgentClient(baseURL: endpoint, credential: "secret", assistantID: UUID(), configuration: configuration, transport: UnavailablePrivateRoute())
        do { _ = try await client.submit(input: "task", sessionID: "s1", operationID: UUID()); XCTFail("Private route unavailable") }
        catch URLError.notConnectedToInternet { }
        do { _ = try await client.contextStatus(); XCTFail("Private route unavailable") }
        catch URLError.notConnectedToInternet { }
        do { try await client.observe(runID: "r1", after: 1) { _ in }; XCTFail("Private route unavailable") }
        catch URLError.notConnectedToInternet { }
        let invitation = try PairingInvitation.parse("""
        {"version":1,"application":"MoMoAgent","invitation_id":"\(UUID())","instance_id":"\(UUID())","endpoint":"\(endpoint)","expires":\(Date().timeIntervalSince1970 + 120),"network":"tailscale"}
        """)
        do { _ = try await PairingClient(invitation: invitation, configuration: configuration, transport: UnavailablePrivateRoute()).request(name: "Fixture"); XCTFail("Private route unavailable") }
        catch PairingError.unavailable { }
        XCTAssertTrue(APIStub.state.requests().isEmpty, "No credential may enter the default session")
    }

    func testPerTaskRedirectBlockingAndCustomSessionInvalidation() async throws {
        let server = try LoopbackRedirectServer()
        defer { server.stop() }
        let endpoint = URL(string: "http://127.0.0.1:\(server.port)")!

        do {
            let client = try AgentClient(baseURL: endpoint, credential: "secret", assistantID: UUID(), configuration: .ephemeral)
            _ = try await client.capabilities()
            XCTFail("302 redirect must not be followed")
        } catch let AgentClientError.http(status, _, _, _) {
            XCTAssertEqual(status, 302)
        }
        XCTAssertEqual(server.acceptedCount, 1)

        let invitation = try PairingInvitation.parse("""
        {"version":1,"application":"MoMoAgent","invitation_id":"\(UUID())","instance_id":"\(UUID())","endpoint":"\(endpoint.absoluteString)","expires":\(Date().timeIntervalSince1970 + 120)}
        """)
        do {
            let pairing = PairingClient(invitation: invitation, configuration: .ephemeral)
            _ = try await pairing.request(name: "iPhone")
            XCTFail("Pairing 302 redirect must not be followed")
        } catch PairingError.unavailable { }
        XCTAssertEqual(server.acceptedCount, 2)
    }
}

private struct UnavailablePrivateRoute: AgentTransport {
    let requiresExclusiveRouting = true
    func open(_ request: URLRequest) async throws -> AgentByteStream? { nil }
}

private actor EventCapture {
    var values: [AgentRunEvent] = []
    func add(_ event: AgentRunEvent) { values.append(event) }
}

private actor ByteStub: AgentTransport {
    let status: Int
    let chunks: [Data]
    let contentType: String
    let fails: Bool
    var request: URLRequest?
    var http = false
    init(status: Int, chunks: [Data], contentType: String = "application/json", fails: Bool = false) {
        self.status = status; self.chunks = chunks; self.contentType = contentType; self.fails = fails
    }
    func useHTTP() { http = true }
    func open(_ request: URLRequest) async throws -> AgentByteStream? {
        self.request = request
        if http { return nil }
        return AgentByteStream(status: status, contentType: contentType, chunks: AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish(throwing: fails ? URLError(.networkConnectionLost) : nil)
        })
    }
}

private final class APIStub: URLProtocol, @unchecked Sendable {
    static let state = StubState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.state.receive(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 200
    private var body = Data()
    private var received: [URLRequest] = []
    func reset(status: Int, body: String) {
        lock.withLock { self.status = status; self.body = Data(body.utf8); received = [] }
    }
    func receive(_ request: URLRequest) -> (Int, Data) {
        lock.withLock { received.append(request); return (status, body) }
    }
    func requests() -> [URLRequest] { lock.withLock { received } }
}

private final class LoopbackRedirectServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var accepted = 0
    private var worker: Thread?

    var acceptedCount: Int { lock.withLock { accepted } }

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { Darwin.close(fd); throw POSIXError(.EIO) }
        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &len) }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: assigned.sin_port)
        let thread = Thread { [weak self] in self?.serve() }
        self.worker = thread
        thread.start()
    }

    private func serve() {
        let response = Array("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9/redirected\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8)
        while true {
            let client = Darwin.accept(listenFD, nil, nil)
            if client < 0 { break }
            lock.withLock { accepted += 1 }
            var buf = [UInt8](repeating: 0, count: 2048)
            _ = Darwin.recv(client, &buf, buf.count, 0)
            _ = response.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
            Darwin.close(client)
        }
    }

    func stop() {
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
    }
}
