"""Exercise the real EmbeddedTailnet lifecycle with a deterministic, offline SDK double."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
import json
import os
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
SDK = r'''
import Foundation
public let kDefaultControlURL = "https://fixture.invalid"
public struct Configuration: Sendable {
    public init(hostName: String, path: String, authKey: String?, controlURL: String, ephemeral: Bool) {}
}
public enum Probe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var created = 0
    nonisolated(unsafe) private static var live = 0
    nonisolated(unsafe) private static var maximum = 0
    nonisolated(unsafe) private static var closing = false
    nonisolated(unsafe) private static var healthyProxy = false
    nonisolated(unsafe) private static var loginState = "Running"
    nonisolated(unsafe) private static var loginDelay: Duration?
    nonisolated(unsafe) private static var loginStarted: ContinuousClock.Instant?
    nonisolated(unsafe) private static var loginRequests = 0
    nonisolated(unsafe) private static var upCalls = 0
    nonisolated(unsafe) private static var resumeRunningOnUp = false
    nonisolated(unsafe) private static var mappedPeers: [String] = []
    nonisolated(unsafe) private static var protocolOverride: AnyClass?
    public static func setProtocolOverride(_ cls: AnyClass?) {
        lock.withLock { protocolOverride = cls }
    }
    public static var currentProtocolOverride: AnyClass? {
        lock.withLock { protocolOverride }
    }
    public static func configureLogin(state: String = "NeedsLogin", delay: Duration? = nil) {
        lock.withLock { loginState = state; loginDelay = delay; loginStarted = nil; loginRequests = 0 }
    }
    public static func configureState(_ state: String, resumeOnUp: Bool = false, peers: [String] = []) {
        lock.withLock { loginState = state; resumeRunningOnUp = resumeOnUp; mappedPeers = peers }
    }
    public static func setMappedPeers(_ peers: [String]) {
        lock.withLock { mappedPeers = peers }
    }
    public static var ups: Int { lock.withLock { upCalls } }
    static func recordUp() {
        lock.withLock {
            upCalls += 1
            if resumeRunningOnUp { loginState = "Running" }
        }
    }
    public static func requestLogin() { lock.withLock { loginRequests += 1; loginStarted = .now } }
    public static var requests: Int { lock.withLock { loginRequests } }
    public static var status: Data {
        lock.withLock {
            var peerMap: [String: Any] = [:]
            for (index, ip) in mappedPeers.enumerated() {
                peerMap["peer-\(index)"] = ["InNetworkMap": true, "TailscaleIPs": [ip]]
            }
            var object: [String: Any] = ["BackendState": loginState, "TailscaleIPs": ["100.64.0.1"], "Peer": peerMap]
            if let delay = loginDelay, let start = loginStarted, start.duration(to: .now) >= delay {
                object["AuthURL"] = "https://login.tailscale.com/a/fixture"
            }
            return try! JSONSerialization.data(withJSONObject: object)
        }
    }
    public static func useHealthyProxy(_ value: Bool) { lock.withLock { healthyProxy = value } }
    public static var proxyAddress: String {
        lock.withLock { healthyProxy ? ProcessInfo.processInfo.environment["MOMO_TEST_PROXY"]! : "127.0.0.1:9" }
    }
    public static var counts: (Int, Int, Int, Bool) { lock.withLock { (created, live, maximum, closing) } }
    static func opened() { lock.withLock { created += 1; live += 1; maximum = max(maximum, live) } }
    static func beginClose() { lock.withLock { closing = true } }
    static func closed() { lock.withLock { live -= 1; closing = false } }
}
public actor TailscaleNode {
    public nonisolated static func configureProxy(mode: String, address: String = "") throws {}
    private var closed = false
    public init(config: Configuration, logger: String?) throws { Probe.opened() }
    public func up() async throws { Probe.recordUp() }
    public func close() async throws {
        guard !closed else { return }; closed = true; Probe.beginClose()
        try await Task.sleep(for: .milliseconds(30)); Probe.closed()
    }
    public func logout() async throws {}
    public func statusJSON() throws -> Data { Probe.status }
}
public struct LocalAPIClient {
    public init(localNode: TailscaleNode, logger: String?) {}
    public func startLoginInteractive() async throws { Probe.requestLogin() }
}
public struct Loopback: Sendable {
    public var address: String { Probe.proxyAddress }
    public let localAPIKey = "fixture"
}
public extension URLSessionConfiguration {
    static func tailscaleSession(_ node: TailscaleNode) async throws -> (URLSessionConfiguration, Loopback) {
        try await Task.sleep(for: .milliseconds(20))
        let config = URLSessionConfiguration.ephemeral
        if let cls = Probe.currentProtocolOverride {
            config.protocolClasses = [cls]
        }
        return (config, Loopback())
    }
}
'''
HARNESS = r'''
import Foundation
import TailscaleKit
import MoMoAgentClient
@main struct RecoveryTests {
    @MainActor static func main() async throws {
        let peer: [String: Any] = ["Active": true, "Online": true, "TailscaleIPs": ["100.64.0.2"],
            "CurAddr": "192.168.1.2:41641", "Relay": "fixture-region", "HostName": "private-name"]
        let direct = TailnetDiagnostics.routeSummary(["Peer": ["private-key": peer]], target: "100.64.0.2")
        precondition(direct == [["route": "direct", "online": "yes"]], "Home DERP is not proof of relay traffic")
        var relayed = peer; relayed["CurAddr"] = ""
        precondition(TailnetDiagnostics.routeSummary(["Peer": ["key": relayed]], target: "100.64.0.2").first?["route"] == "derp")
        relayed["PeerRelay"] = "private-peer"
        precondition(TailnetDiagnostics.routeSummary(["Peer": ["key": relayed]], target: nil).first?["route"] == "peer-relay")
        relayed["Active"] = false
        precondition(TailnetDiagnostics.routeSummary(["Peer": ["key": relayed]], target: nil).isEmpty)
        precondition(TailnetDiagnostics.routeSummary(["Peer": ["key": relayed]], target: "100.64.0.2").first?["route"] == "idle")
        precondition(TailnetDiagnostics.routeSummary(["Peer": ["key": peer]], target: "100.64.0.3").isEmpty)
        let safe = String(data: try JSONSerialization.data(withJSONObject: direct), encoding: .utf8)!
        precondition(!safe.contains("private") && !safe.contains("192.168") && !safe.contains("100.64"))
        precondition(TailnetDiagnostics.category(URL(string: "http://100.64.0.2/v1/runs/private-id/events?token=secret")) == "events")
        precondition(TailnetDiagnostics.category(URL(string: "http://100.64.0.2/private/path")) == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnosticsDir = directory.appendingPathComponent("incident")
        try FileManager.default.createDirectory(at: diagnosticsDir, withIntermediateDirectories: true)
        let log = diagnosticsDir.appendingPathComponent("network-timing.json")
        try Data(#"{"schema":1,"requests":[{"category":"messages"}],"routes":[]}"#.utf8).write(to: log)
        let failure = AgentClientError.http(status: 503, code: "private-code", message: "private-message")
        let recorder = TailnetDiagnostics(directory: diagnosticsDir)
        recorder.recordChat("conversationSubscription", state: .retrying, error: failure, retryAt: Date())
        recorder.recordChat("conversationSubscription", state: .retrying, error: failure, retryAt: Date())
        let reopened = TailnetDiagnostics(directory: diagnosticsDir)
        reopened.recordChat("liveConnectionConfirmed", state: .ready, error: nil, retryAt: nil)
        reopened.recordChat("liveConnectionConfirmed", state: .ready, error: nil, retryAt: nil)
        let recorded = try Data(contentsOf: log)
        let saved = try JSONSerialization.jsonObject(with: recorded) as! [String: Any]
        let incidents = saved["chat"] as! [[String: Any]]
        precondition(incidents.count == 2 && incidents[0]["code"] as? Int == 503)
        precondition(incidents[0]["count"] as? Int == 2 && incidents[1]["state"] as? String == "ready")
        precondition((saved["requests"] as? [[String: String]])?.first?["category"] == "messages")
        precondition(!String(decoding: recorded, as: UTF8.self).contains("private-"))
        let network = EmbeddedTailnet(directory: directory, device: "fixture")
        async let a = network.connectedSession()
        async let b = network.connectedSession()
        let (first, same) = try await (a, b)
        precondition(first === same, "Concurrent readers must share one cached session")
        async let chatA = network.connectedSession(interactive: true)
        async let chatB = network.connectedSession(interactive: true)
        let (chat, sameChat) = try await (chatA, chatB)
        precondition(chat === sameChat && chat !== first, "Chat reuses its own pool independently of sync")
        precondition(Probe.counts.0 == 1)
        var current = first
        for code in [URLError.badURL, .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet] {
            network.failedRequest(URLError(code), session: current)
            async let c = network.connectedSession()
            async let d = network.connectedSession()
            let (recovered, duplicate) = try await (c, d)
            precondition(recovered === duplicate && recovered !== current)
            precondition(Probe.counts.2 == 1, "Never open a node while its predecessor is closing")
            network.failedRequest(URLError(.badURL), session: current)
            let unchanged = try await network.connectedSession()
            precondition(unchanged === recovered, "An old in-flight error cannot invalidate the replacement")
            current = recovered
        }
        network.failedRequest(URLError(.cancelled), session: current)
        let uncancelled = try await network.connectedSession()
        precondition(uncancelled === current, "Reader cancellation is not a broken node")
        Probe.useHealthyProxy(true)
        let nodesBefore = Probe.counts.0
        network.failedRequest(URLError(.timedOut), session: current)
        let slowPeer = try await network.connectedSession()
        precondition(Probe.counts.0 == nodesBefore, "A slow peer must not restart the healthy local node")
        current = slowPeer
        let otherPool = try await network.connectedSession(interactive: true)
        network.failedRequest(URLError(.badURL), session: current)
        let repairedPool = try await network.connectedSession()
        let preservedPool = try await network.connectedSession(interactive: true)
        do {
            let stale = URLRequest(url: URL(string: "http://100.64.0.2:8767/")!)
            _ = try await TailnetChunkStream.open(stale, session: current, network: network)
            preconditionFailure("A late request must not start on a retired pool")
        } catch let error as URLError where error.code == .networkConnectionLost {}
        precondition(repairedPool !== current, "A healthy probe must not retain a failed URLSession pool")
        precondition(preservedPool === otherPool && Probe.counts.0 == nodesBefore, "Repair only the failed pool, not the node or active chat")
        let control = try await network.connectedSession(desktopControl: true)
        let media = try await network.connectedSession(media: true)
        precondition(control !== media && control !== preservedPool && media !== repairedPool)
        network.failedRequest(URLError(.badURL), session: media)
        let newMedia = try await network.connectedSession(media: true)
        let preservedControl = try await network.connectedSession(desktopControl: true)
        precondition(newMedia !== media && preservedControl === control)
        current = repairedPool
        Probe.useHealthyProxy(false)
        network.prepareForForeground()
        let resumed = try await network.connectedSession()
        precondition(resumed !== current, "Foreground replaces the potentially reclaimed SOCKS listener")
        let closing = Task { await network.close() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !Probe.counts.3 {
            precondition(ContinuousClock.now < deadline, "Close never started")
            await Task.yield()
        }
        let restarted = try await network.connectedSession()
        await closing.value
        precondition(restarted !== resumed && Probe.counts.2 == 1)
        await network.close()
        precondition(Probe.counts.1 == 0)
        print("PASS: concurrent pools, automatic recovery, healthy-proxy badURL repair, peer timeouts, stale errors, cancellation and resume")

        Probe.configureLogin(delay: .seconds(5))
        let delayed = try await network.loginURL()
        precondition(delayed?.host == "login.tailscale.com", "Login must survive the old 4.5-second deadline")
        let reused = try await network.loginURL()
        precondition(reused == delayed && Probe.requests == 1, "Reopening login must reuse the issued URL")
        await network.close()

        Probe.configureLogin()
        do { _ = try await network.loginURL(timeout: .milliseconds(100)); preconditionFailure("Expected timeout") }
        catch TailnetError.loginTimedOut { }
        await network.close()

        Probe.configureLogin(state: "Running")
        let loggedIn = try await network.loginURL()
        precondition(loggedIn == nil && Probe.requests == 0, "A logged-in node must not request another login")
        await network.close()

        Probe.configureLogin(state: "NeedsMachineAuth")
        do { _ = try await network.loginURL(); preconditionFailure("Expected approval requirement") }
        catch TailnetError.approvalRequired { }
        precondition(Probe.requests == 0)
        await network.close()

        Probe.configureLogin()
        let cancelled = Task { try await network.loginURL() }
        while Probe.requests == 0 { await Task.yield() }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError { }
        await network.close()

        Probe.configureLogin()
        let stale = Task { try await network.loginURL() }
        while Probe.requests == 0 { await Task.yield() }
        await network.close()
        Probe.configureLogin(state: "Running")
        try await network.start()
        do { _ = try await stale.value; preconditionFailure("Old login must not consume replacement node status") }
        catch is CancellationError { }
        await network.close()
        print("PASS: delayed login, URL reuse, timeout, existing login, machine approval, cancellation and replaced node")

        Probe.configureLogin(state: "Running")
        try await network.start()
        let oldNode = network.node
        let name = try String(contentsOf: directory.appendingPathComponent("node-name"), encoding: .utf8)
        let policy = TailnetProxySettings(mode: .manual, address: " http://127.0.0.1:7890/ ")
        try await network.updateProxy(policy)
        precondition(network.node == nil)
        try await network.start()
        precondition(network.node !== oldNode)
        let restoredName = try String(contentsOf: directory.appendingPathComponent("node-name"), encoding: .utf8)
        let restoredPolicy = try TailnetProxySettings.read(from: directory)
        precondition(restoredName == name)
        precondition(restoredPolicy.address == "http://127.0.0.1:7890")
        let currentNode = network.node
        do {
            try await network.updateProxy(TailnetProxySettings(mode: .manual, address: "http://secret@proxy:80"))
            preconditionFailure("Invalid proxy must not replace working configuration")
        } catch TailnetProxySettings.ValidationError.invalidAddress {}
        precondition(network.node === currentNode)
        try await network.updateProxy(TailnetProxySettings())
        try await network.start()
        precondition(network.proxySettings.mode == .system)
        await network.close()
        try Data("broken".utf8).write(to: directory.appendingPathComponent("connection-proxy.json"))
        let corrupt = EmbeddedTailnet(directory: directory, device: "fixture")
        precondition(corrupt.proxySettingsError != nil)
        do { try await corrupt.start(); preconditionFailure("Corrupt settings must not silently select direct") }
        catch TailnetError.unavailable {}
        try await corrupt.updateProxy(TailnetProxySettings())
        try await corrupt.start(); await corrupt.close()
        print("PASS: proxy persistence, validation, node-only restart, identity retention and corrupt-setting recovery")

        // Regression 1: Zombie "Stopped" node after background wakeup with healthy localapi proxy
        // must re-invoke node.up() and recover in-place without trapping connectedSession forever.
        let recoveryDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: recoveryDir) }
        let zombieNet = EmbeddedTailnet(directory: recoveryDir, device: "fixture")
        zombieNet.startupTimeout = .milliseconds(350)
        zombieNet.peerMapTimeout = .milliseconds(300)
        Probe.useHealthyProxy(true)
        Probe.configureState("Running", resumeOnUp: false, peers: ["100.118.16.18"])
        _ = try await zombieNet.connectedSession(peer: "100.118.16.18")
        let createdBeforeZombie = Probe.counts.0
        let upsBeforeZombie = Probe.ups
        zombieNet.suspendSessions()
        Probe.configureState("Stopped", resumeOnUp: true, peers: ["100.118.16.18"])
        zombieNet.prepareForForeground()
        let recoveredFromStopped = try await zombieNet.connectedSession(peer: "100.118.16.18")
        precondition(zombieNet.state == "Running", "Stopped node must re-up to Running")
        precondition(Probe.ups > upsBeforeZombie, "Stopped node must re-run up()")
        precondition(Probe.counts.0 == createdBeforeZombie, "Recoverable Stopped node re-ups in place")
        _ = recoveredFromStopped

        // Regression 2: A wedged node stuck in "Stopped" past startupTimeout marks needsRestart
        // so the immediate next retry recycles the node instead of looping forever.
        zombieNet.suspendSessions()
        Probe.configureState("Stopped", resumeOnUp: false, peers: ["100.118.16.18"])
        zombieNet.prepareForForeground()
        do {
            _ = try await zombieNet.connectedSession(peer: "100.118.16.18")
            preconditionFailure("Expected timeout while node refuses to leave Stopped")
        } catch let error as URLError where error.code == .notConnectedToInternet {}
        Probe.configureState("Running", resumeOnUp: true, peers: ["100.118.16.18"])
        _ = try await zombieNet.connectedSession(peer: "100.118.16.18")
        precondition(Probe.counts.0 == createdBeforeZombie + 1, "Wedged Stopped node must recycle on next attempt")

        // An unmapped peer cannot be dialed. Its return must reuse the healthy node and existing chat pool.
        Probe.setMappedPeers([])
        zombieNet.prepareForForeground()
        let delayedPeerTask = Task {
            try await Task.sleep(for: .milliseconds(80))
            Probe.setMappedPeers(["100.118.16.18"])
        }
        _ = try await zombieNet.connectedSession(peer: "100.118.16.18")
        try await delayedPeerTask.value
        Probe.setMappedPeers([])
        zombieNet.prepareForForeground()
        let beforePeerTimeoutNodes = Probe.counts.0
        let originalChat = try await zombieNet.connectedSession(interactive: true)
        for _ in 0..<3 {
            do {
                _ = try await zombieNet.connectedSession(peer: "100.118.16.18")
                preconditionFailure("Expected peer map timeout")
            } catch let error as URLError where error.code == .notConnectedToInternet {}
        }
        Probe.setMappedPeers(["100.118.16.18"])
        let resumedChat = try await zombieNet.connectedSession(peer: "100.118.16.18", interactive: true)
        precondition(resumedChat === originalChat && Probe.counts.0 == beforePeerTimeoutNodes,
                     "Waiting for the Mac to reappear must preserve the healthy node and chat pool")

        // Independent failures can accumulate while the Mac is offline, even though LocalAPI still works.
        var failedPool = try await zombieNet.connectedSession(peer: "100.118.16.18")
        for _ in 0..<8 {
            zombieNet.failedRequest(URLError(.timedOut), session: failedPool)
            let replacement = try await zombieNet.connectedSession(peer: "100.118.16.18")
            precondition(replacement !== failedPool, "A failed pool should be renewed")
            failedPool = replacement
        }
        let chatAfterFailures = try await zombieNet.connectedSession(interactive: true)
        precondition(chatAfterFailures === originalChat && Probe.counts.0 == beforePeerTimeoutNodes,
                     "Repeated remote timeouts must not restart a healthy local node")

        // Regression 5: Peer warmup triggers disco + TSMP LocalAPI pings and retries cold TSMP once.
        let proxyAddr = ProcessInfo.processInfo.environment["MOMO_TEST_PROXY"]!
        _ = try await URLSession.shared.data(from: URL(string: "http://\(proxyAddr)/reset-pings?fail_first_tsmp=1")!)
        zombieNet.suspendSessions()
        _ = try await zombieNet.connectedSession(peer: "100.118.16.18")
        let (pingRaw, _) = try await URLSession.shared.data(from: URL(string: "http://\(proxyAddr)/pings")!)
        let pingPayload = try JSONSerialization.jsonObject(with: pingRaw) as! [String: Any]
        let tsmpCount = pingPayload["tsmp"] as? Int ?? 0
        let discoCount = pingPayload["disco"] as? Int ?? 0
        precondition(tsmpCount == 2 && discoCount >= 1, "Cold peer warmup must run disco and retry TSMP once on initial error")
        _ = try await zombieNet.connectedSession(peer: "100.118.16.18")
        let (cachedPingRaw, _) = try await URLSession.shared.data(from: URL(string: "http://\(proxyAddr)/pings")!)
        let cachedPingPayload = try JSONSerialization.jsonObject(with: cachedPingRaw) as! [String: Any]
        precondition((cachedPingPayload["tsmp"] as? Int) == 2, "Steady-state session reuse must not re-ping")

        // Regression 6: EmbeddedTailnetTransport transparently retries safe pre-header socket failures (-1000 badURL) once.
        Probe.setProtocolOverride(TransientPeerProtocol.self)
        defer { Probe.setProtocolOverride(nil) }
        zombieNet.suspendSessions()
        let endpoint = URL(string: "http://100.118.16.18:8767")!
        let transport = EmbeddedTailnetTransport(network: zombieNet, endpoint: endpoint)
        TransientPeerProtocol.reset(failures: 1)
        var getReq = URLRequest(url: endpoint.appendingPathComponent("momo/v1/conversation"))
        getReq.httpMethod = "GET"
        let getStream = try await transport.open(getReq)!
        var body = Data()
        for try await chunk in getStream.chunks { body.append(chunk) }
        precondition(getStream.status == 200 && TransientPeerProtocol.attempts == 2,
                     "GET must transparently recover from one SOCKS5 -1000 cutoff")

        TransientPeerProtocol.reset(failures: 1)
        var unsafePost = URLRequest(url: endpoint.appendingPathComponent("momo/v1/custom"))
        unsafePost.httpMethod = "POST"
        unsafePost.httpBody = Data("{}".utf8)
        do {
            _ = try await transport.open(unsafePost)
            preconditionFailure("Non-idempotent POST without Idempotency-Key must not auto-retry")
        } catch let error as URLError where error.code == .badURL {}
        precondition(TransientPeerProtocol.attempts == 1, "Non-idempotent POST attempted only once")

        await zombieNet.close()
        print("PASS: zombie Stopped recovery, wedged node recycle, missing-peer recovery, repeated remote timeouts, peer warmup and pre-header retry")
    }
}

final class TransientPeerProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var remainingFailures = 0
    nonisolated(unsafe) private static var seenAttempts = 0
    static func reset(failures: Int) {
        lock.withLock { remainingFailures = failures; seenAttempts = 0 }
    }
    static var attempts: Int { lock.withLock { seenAttempts } }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "100.118.16.18"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let shouldFail = Self.lock.withLock { () -> Bool in
            Self.seenAttempts += 1
            if Self.remainingFailures > 0 {
                Self.remainingFailures -= 1
                return true
            }
            return false
        }
        if shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let data = Data("{\"ok\":true}".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
'''


def run(*args):
    subprocess.run(args, check=True, cwd=ROOT)


class HealthyProxy(BaseHTTPRequestHandler):
    lock = threading.Lock()
    pings = {"disco": 0, "tsmp": 0}
    fail_first_tsmp = False

    def _reply(self, payload):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/reset-pings":
            qs = parse_qs(parsed.query)
            with self.lock:
                self.pings["disco"] = 0
                self.pings["tsmp"] = 0
                HealthyProxy.fail_first_tsmp = qs.get("fail_first_tsmp") == ["1"]
            self._reply({"ok": True})
            return
        if parsed.path == "/pings":
            with self.lock:
                snapshot = dict(self.pings)
            self._reply(snapshot)
            return
        self._reply({})

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/localapi/v0/ping":
            qs = parse_qs(parsed.query)
            kind = (qs.get("type") or [""])[0]
            err = ""
            with self.lock:
                if kind == "disco":
                    self.pings["disco"] += 1
                elif kind == "TSMP":
                    self.pings["tsmp"] += 1
                    if HealthyProxy.fail_first_tsmp:
                        HealthyProxy.fail_first_tsmp = False
                        err = "derp waking"
            self._reply({"Err": err})
            return
        self._reply({})

    def log_message(self, *_args): pass


with tempfile.TemporaryDirectory(prefix="momo-tailnet-recovery-") as temporary:
    root = Path(temporary)
    (root / "TailscaleKit.swift").write_text(SDK)
    (root / "RecoveryTests.swift").write_text(HARNESS)
    run("xcrun", "swiftc", "-swift-version", "6", "-emit-library", "-emit-module", "-module-name", "TailscaleKit",
        str(root / "TailscaleKit.swift"), "-emit-module-path", str(root / "TailscaleKit.swiftmodule"), "-o", str(root / "libTailscaleKit.dylib"))
    run("xcrun", "swiftc", "-swift-version", "6", "-emit-library", "-emit-module", "-module-name", "MoMoAgentClient",
        *sorted((ROOT / "Packages/MoMoAgentAgentClient/Sources/MoMoAgentClient").glob("*.swift")),
        "-emit-module-path", str(root / "MoMoAgentClient.swiftmodule"), "-o", str(root / "libMoMoAgentClient.dylib"))
    run("xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-I", str(root), "-L", str(root),
        "-lTailscaleKit", "-lMoMoAgentClient", "-Xlinker", "-rpath", "-Xlinker", str(root),
        str(ROOT / "Apps/ClientUI/Network/TailnetDiagnostics.swift"),
        str(ROOT / "Apps/ClientUI/Network/TailnetProxySettings.swift"),
        str(ROOT / "Apps/ClientUI/Network/EmbeddedTailnet.swift"),
        str(ROOT / "Apps/ClientUI/Network/EmbeddedTailnetTransport.swift"),
        str(root / "RecoveryTests.swift"), "-o", str(root / "test"))
    with ThreadingHTTPServer(("127.0.0.1", 0), HealthyProxy) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
        try:
            subprocess.run([str(root / "test")], check=True, cwd=ROOT,
                           env={**os.environ, "MOMO_TEST_PROXY": f"127.0.0.1:{server.server_port}"})
        finally:
            server.shutdown(); worker.join()
