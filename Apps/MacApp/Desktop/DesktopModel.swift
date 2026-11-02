import AppKit
import ApplicationServices
import Foundation
import Observation
import MoMoAgentClient
import Darwin

struct AccessStatus: Decodable {
    struct Tunnel: Decodable {
        let state: String; let endpoint: String?; let mode: String; let provider: String?; let error: String?
        let setupCommand: String?
        let configuredEndpoint: String?
        enum CodingKeys: String, CodingKey { case state, endpoint, mode, provider, error; case setupCommand = "setup_command"; case configuredEndpoint = "configured_endpoint" }
    }
    struct Device: Decodable, Identifiable { let id: String; let name: String; let code: String; let state: String; let expires: Double; let lastSeen: Double?; let endpoint: String?
        enum CodingKeys: String, CodingKey { case id, name, code, state, expires, endpoint; case lastSeen = "last_seen" }
    }
    struct Invitation: Decodable { let id: String; let endpoint: String; let expires: Double; let payload: String }
    let agentOnline: Bool
    let tunnel: Tunnel
    let devices: [Device]
    let invitation: Invitation?
    let pairedDeviceID: String?
    enum CodingKeys: String, CodingKey { case agentOnline = "agent_online"; case pairedDeviceID = "paired_device_id"; case tunnel, devices, invitation }
}

enum DesktopAgentEngine: String, CaseIterable, Identifiable {
    case superagent
    case hermes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .superagent: "DeepSeek SuperAgent"
        case .hermes: "Hermes Agent"
        }
    }
    var summary: String {
        switch self {
        case .superagent: String(localized: "默认引擎 · DeepSeek 开源编排器，自动评估同步录音并派发子智能体执行")
        case .hermes: String(localized: "原生主会话与后台委派引擎")
        }
    }
}

struct DesktopProactiveSnapshot: Sendable {
    let dshReady: Bool
    let activeTickets: Int
    let totalDecisions: Int
    let latestSummary: String?
}

@MainActor @Observable
final class DesktopModel {
    enum SetupStep: String { case welcome, prepare, model, permissions, pair, ready, completed }
    var setupStep = SetupStep.welcome
    var selection = "chat"
    var managingConnection = false
    var isPairingDevice = false
    var isPrepared: Bool { connection != nil }
    var hasBundledRuntime: Bool { FileManager.default.fileExists(atPath: repository.appendingPathComponent("runtime-manifest.json").path) }
    var runtimePython: URL {
        hasBundledRuntime ? repository.appendingPathComponent("python/bin/python3.14")
            : dataDirectory.appendingPathComponent("runtime/venv/bin/python")
    }
    var hasDesktopPermissions: Bool { AXIsProcessTrusted() && CGPreflightScreenCaptureAccess() }
    var hasPairedPhone: Bool {
        guard let status else { return false }
        return status.devices.contains { $0.state == "approved" && $0.lastSeen != nil }
    }
    var pairingAccepted: Bool {
        guard let status, status.tunnel.state == "connected" else { return false }
        return status.devices.contains { $0.id == status.pairedDeviceID && $0.state == "approved" }
            || setupStep == .pair && hasPairedPhone && status.invitation == nil
    }
    var localAccessURL: String { connection?.baseURL.port.map { "http://127.0.0.1:\($0 + 2)" } ?? String(localized: "准备 Mac 后显示") }
    var ownsAgent: Bool { agentProcess?.isRunning == true }
    var readingPosition: ChatReadingPosition?
    var status: AccessStatus?
    var busy: String?
    var preparationPhase: DesktopPreparationPhase?
    var preparationDownload: DesktopDownloadProgress?
    var failure: String?
    var desktopHost: DesktopControlHost?
    var desktopFailure: String?
    var endpoint = ""
    var modelProvider = DesktopModelProvider.codex {
        didSet {
            guard oldValue != modelProvider else { return }
            cancelModelConnection()
            modelDrafts[oldValue] = modelName
            modelName = modelDrafts[modelProvider] ?? ""
            modelAccount = nil
            modelAccountCheckedAt = nil
            failure = nil
        }
    }
    var modelAccount: DesktopModelAccount?
    var loadingModelAccount = false
    @ObservationIgnored var modelAccountCheckedAt: Date?
    @ObservationIgnored var modelAccountRefreshTask: Task<Void, Never>?
    @ObservationIgnored var modelAccountRefreshID: UUID?
    var modelConnectionCancelled = false
    var modelLogin: DesktopModelLogin?
    @ObservationIgnored var modelLoginTask: Task<Void, Never>?
    @ObservationIgnored var modelProcess: Process?
    @ObservationIgnored private var modelDrafts: [DesktopModelProvider: String] = [:]
    var providerURL = ""
    var modelName = ""
    var providerKey = ""
    var runtimeEngine = DesktopAgentEngine.superagent
    var proactiveSnapshot: DesktopProactiveSnapshot?
    var taskStore: RemoteTaskStore?
    var memories: [ContextMemory] = []
    var sources: [ContextSource] = []
    var memoryError: String?
    var memoryReviewStatus: MemoryReviewStatus?
    var transcriptMemoryNeedsReview = 0
    var contextLoading = false
    @ObservationIgnored private var fetchingContext = false
    @ObservationIgnored private var contextRefreshRequested = false
    @ObservationIgnored private var contextRefreshNonSilent = false
    @ObservationIgnored private var lastContextRefreshAt = Date.distantPast
    let repository: URL
    let dataDirectory: URL
    let tailnet: EmbeddedTailnet
    private(set) var tailnetAccessError: String?
    @ObservationIgnored private var lastEmbeddedEndpoint: String?
    @ObservationIgnored private var embeddedProbeFailures = 0
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var accessProcess: Process?
    @ObservationIgnored private var agentProcess: Process?
    @ObservationIgnored private var connection: AgentConnection?
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored private var lastAgentLaunchAttempt = Date.distantPast
    @ObservationIgnored private var cachedBaseClient: (url: URL, key: String, assistantID: UUID, client: AgentClient)?
    @ObservationIgnored private var cachedDataClient: (url: URL, key: String, assistantID: UUID, client: AgentClient)?
    private var resumeKey: String { "agent.resume." + dataDirectory.path }
    @ObservationIgnored private let controlSession = URLSession(configuration: .ephemeral)

    init() {
        let args = ProcessInfo.processInfo.arguments
        func argument(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("AgentRuntime")
        repository = argument("--repository").map { URL(fileURLWithPath: $0) }
            ?? bundled.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("runtime-manifest.json").path) ? $0 : nil }
            ?? URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "MoMoRepositoryRoot") as? String ?? "")
        let dataFolder = Bundle.main.object(forInfoDictionaryKey: "MoMoDataFolder") as? String ?? "MoMoAgent"
        dataDirectory = URL(fileURLWithPath: argument("--data-dir") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(dataFolder)/Agent").path)
        tailnet = EmbeddedTailnet(directory: dataDirectory.appendingPathComponent("tailscale"), device: "mac")
        setupStep = SetupStep(rawValue: UserDefaults.standard.string(forKey: "setup." + dataDirectory.path) ?? "welcome") ?? .welcome
    }

    func load() async {
        guard timer == nil, !loading else { return }
        loading = true; defer { loading = false }
        if FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("connection.json").path) {
            do {
                try await reclaimStaleRuntimeProcesses()
                try loadConnection()
                let pythonPath = runtimePython.path
                let needsSuperAgentPrep = runtimeEngine == .superagent
                    && !FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("runtime/superagent/prepared.json").path)
                if hasBundledRuntime || !FileManager.default.isExecutableFile(atPath: pythonPath) || needsSuperAgentPrep {
                    try await prepareRuntime()
                }
                do { try startAccess() } catch { try await prepareRuntime(); try startAccess() }
                for _ in 0..<12 {
                    await refresh()
                    if status != nil { break }
                    try? await Task.sleep(for: .milliseconds(150))
                }
                if UserDefaults.standard.bool(forKey: resumeKey), status?.agentOnline != true {
                    try launchAgent()
                }
            } catch { failure = error.localizedDescription }
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.shuttingDown else { return }
                    self.embeddedProbeFailures = 0
                    self.tailnet.prepareForForeground()
                    await self.refresh()
                    await self.taskStore?.retryConnection()
                }
            }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }

    private static func openTaskStore(file: URL, connection: AgentConnection, client: AgentClient) throws -> RemoteTaskStore {
        do {
            return try RemoteTaskStore(file: file, connection: connection, client: client)
        } catch {
            struct Header: Decodable { let connection: AgentConnection }
            if let raw = try? Data(contentsOf: file),
               let header = try? JSONDecoder().decode(Header.self, from: raw),
               !header.connection.hasSameIdentity(as: connection) {
                throw error
            }
            let backup = file.deletingLastPathComponent().appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".corrupted.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: file, to: backup)
            return try RemoteTaskStore(file: file, connection: connection, client: client)
        }
    }

    private func baseClient(for connection: AgentConnection) throws -> AgentClient {
        if let cached = cachedBaseClient, cached.url == connection.baseURL, cached.key == key, cached.assistantID == connection.assistantID {
            return cached.client
        }
        let client = try AgentClient(baseURL: connection.baseURL, credential: key, assistantID: connection.assistantID)
        cachedBaseClient = (connection.baseURL, key, connection.assistantID, client)
        return client
    }

    private func dataClient(for connection: AgentConnection, url: URL) throws -> AgentClient {
        if let cached = cachedDataClient, cached.url == url, cached.key == key, cached.assistantID == connection.assistantID {
            return cached.client
        }
        let client = try AgentClient(baseURL: url, credential: key, assistantID: connection.assistantID)
        cachedDataClient = (url, key, connection.assistantID, client)
        return client
    }

    private static func unquoteYAMLScalar(_ raw: Substring) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
            value.removeFirst()
            value.removeLast()
            return value
        }
        if let commentRange = value.range(of: " #") {
            value = String(value[..<commentRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        } else if value.hasPrefix("#") {
            return ""
        }
        return value
    }

    private static func readModelConfiguration(from file: URL) -> [String: String]? {
        guard let raw = try? Data(contentsOf: file) else { return nil }
        if let config = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
           let model = config["model"] as? [String: Any] {
            var values: [String: String] = [:]
            for field in ["provider", "default", "base_url"] {
                if let string = model[field] as? String { values[field] = string }
            }
            return values
        }
        guard let text = String(data: raw, encoding: .utf8) else { return nil }
        var inModelBlock = false
        var modelIndent: Int?
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            if !inModelBlock {
                if indent == 0, trimmed == "model:" || trimmed.hasPrefix("model: #") {
                    inModelBlock = true
                    modelIndent = nil
                }
                continue
            }
            if indent == 0 { break }
            if let expected = modelIndent, indent < expected { break }
            if modelIndent == nil { modelIndent = indent }
            guard indent == modelIndent, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = trimmed[trimmed.index(after: colon)...]
            if ["provider", "default", "base_url"].contains(key) {
                values[key] = unquoteYAMLScalar(rawValue)
            }
        }
        return values.isEmpty ? nil : values
    }

    private func readHermesConfiguration(from file: URL) async -> [String: Any] {
        let fallback: [String: Any] = [
            "memory": ["memory_enabled": true, "user_profile_enabled": true],
            "updates": ["check": false],
            "agent": ["max_turns": 20],
            "platform_toolsets": ["api_server": ["terminal", "file", "memory"]],
            "terminal": ["cwd": dataDirectory.appendingPathComponent("workspace").path],
        ]
        if let raw = try? Data(contentsOf: file),
           let parsed = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
            return parsed
        }
        let python = runtimePython
        let bundled = hasBundledRuntime
        let hermesRoot = repository.appendingPathComponent("Vendor/HermesAgent").path
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: file.path) else { return fallback }
        let loadedData = await Task.detached { () -> Data? in
            let p = Process()
            p.executableURL = python
            let isolation = bundled ? ["-I", "-B"] : []
            let script = """
            import json, sys
            from pathlib import Path
            sys.path.insert(0, sys.argv[1])
            raw = Path(sys.argv[2]).read_text(encoding="utf-8")
            data = None
            for kind in ("yaml", "ruamel"):
                try:
                    if kind == "yaml":
                        import yaml
                        data = yaml.safe_load(raw)
                    else:
                        from ruamel.yaml import YAML
                        data = YAML(typ="safe").load(raw)
                    break
                except Exception:
                    pass
            print(json.dumps(dict(data) if isinstance(data, dict) else {}))
            """
            p.arguments = isolation + ["-c", script, hermesRoot, file.path]
            let out = Pipe()
            p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return data
        }.value
        if let loadedData,
           let dict = (try? JSONSerialization.jsonObject(with: loadedData)) as? [String: Any],
           !dict.isEmpty {
            return dict
        }
        return fallback
    }

    private func loadConnection() throws {
        connection = try JSONDecoder().decode(AgentConnection.self, from: Data(contentsOf: dataDirectory.appendingPathComponent("connection.json")))
        key = try String(contentsOf: dataDirectory.appendingPathComponent("api-key"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        prepareDesktop()
        loadEngineConfiguration()
        if let model = Self.readModelConfiguration(from: dataDirectory.appendingPathComponent("hermes/config.yaml")),
           let name = model["default"], !name.isEmpty {
            modelProvider = switch model["provider"] {
            case "openai-codex": .codex
            case "anthropic": .claude
            default: .api
            }
            providerURL = model["base_url"] ?? ""; modelName = name
        }
        // Restore the local journal before checking network availability.
        if taskStore == nil, let connection {
            let client = try baseClient(for: connection)
            taskStore = try Self.openTaskStore(file: dataDirectory.appendingPathComponent("desktop-tasks.json"), connection: connection, client: client)
            taskStore?.foreground()
        }
    }

    func prepare() async {
        guard busy == nil else { return }
        busy = hasBundledRuntime ? String(localized: "正在准备 MoMo…") : String(localized: "正在下载运行组件…"); failure = nil; preparationPhase = hasBundledRuntime ? .ready : .python; preparationDownload = nil
        defer { busy = nil; preparationPhase = nil; preparationDownload = nil }
        do {
            try await prepareRuntime()
            try loadConnection()
            try startAccess()
            await refresh()
        } catch { failure = error.localizedDescription }
    }

    private func prepareRuntime() async throws {
        let script = repository.appendingPathComponent("Apps/MacApp/Runtime/momo_agent.py").path
        if hasBundledRuntime {
            let prefix = ["-I", "-B", script]
            let port = Bundle.main.object(forInfoDictionaryKey: "MoMoLocalPort") as? String ?? "8765"
            if !FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("connection.json").path) {
                try await command(runtimePython.path, prefix + ["init", "--data-dir", dataDirectory.path, "--port", port])
            }
            try await command(runtimePython.path, prefix + ["prepare", "--data-dir", dataDirectory.path, "--progress"])
            return
        }
        let uv = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let uv else { throw DesktopError.message(String(localized: "未找到 uv，请先安装运行环境。")) }
        if !FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("connection.json").path) {
            let port = Bundle.main.object(forInfoDictionaryKey: "MoMoLocalPort") as? String ?? "8765"
            try await command(uv, ["run", "--no-project", "--python", "3.14", script, "init", "--data-dir", dataDirectory.path, "--port", port])
        }
        try await command(uv, ["run", "--no-project", "--python", "3.14", script, "prepare", "--data-dir", dataDirectory.path, "--progress"])
    }

    func startAccess() throws {
        if accessProcess?.isRunning == true { return }
        accessProcess = try process("Apps/MacApp/Access/access_server.py", [])
    }

    func connectService() async {
        do { try await prepareRuntime(); try loadConnection(); try startAccess(); failure = nil } catch { failure = error.localizedDescription }
        await refresh()
    }

    func startAgent() async {
        guard busy == nil, agentProcess?.isRunning != true, status?.agentOnline != true else { return }
        busy = String(localized: "正在启动 MoMo…"); failure = nil
        defer { busy = nil }
        do {
            modelConnectionCancelled = false
            if modelProvider == .api {
                guard !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let url = URL(string: providerURL), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.host != nil,
                      url.scheme == "https" || (url.scheme == "http" && url.host == "127.0.0.1") else { throw DesktopError.message(String(localized: "请先填写模型名称与 HTTPS API 地址。")) }
                guard !providerKey.contains(where: { $0.isNewline || $0 == "\"" || $0 == "'" }) else { throw DesktopError.message(String(localized: "API 密钥格式不正确。")) }
                let file = dataDirectory.appendingPathComponent("hermes/config.yaml")
                var config = await readHermesConfiguration(from: file)
                config["model"] = ["provider": "custom", "default": modelName, "base_url": providerURL, "context_length": 128000]
                try await verifyModel(url: url)
                try privateWrite(try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), to: file)
                if !providerKey.isEmpty {
                    let envFile = dataDirectory.appendingPathComponent("hermes/.env")
                    let previous = try String(contentsOf: envFile, encoding: .utf8)
                    let lines = previous.components(separatedBy: .newlines).filter { !$0.hasPrefix("OPENAI_API_KEY=") }
                    try privateWrite(Data((lines.joined(separator: "\n") + "\nOPENAI_API_KEY=" + providerKey + "\n").utf8), to: envFile); providerKey = ""
                }
            } else {
                applyModelAccount(try await modelCommand("verify", provider: modelProvider), updateSelection: false)
                guard !modelConnectionCancelled else { return }
            }
            try startAccess()
            try launchAgent()
            UserDefaults.standard.set(true, forKey: resumeKey)
            await refresh()
        } catch { if !modelConnectionCancelled { failure = error.localizedDescription } }
    }

    private func verifyModel(url: URL) async throws {
        var credential = providerKey
        if credential.isEmpty {
            let env = try String(contentsOf: dataDirectory.appendingPathComponent("hermes/.env"), encoding: .utf8)
            credential = env.components(separatedBy: .newlines).first(where: { $0.hasPrefix("OPENAI_API_KEY=") }).map { String($0.dropFirst(15)) } ?? ""
        }
        guard !credential.isEmpty, !credential.contains(where: { $0.isNewline }) else { throw DesktopError.message(String(localized: "请填写模型 API 密钥。")) }
        var request = URLRequest(url: url.appendingPathComponent("chat/completions")); request.timeoutInterval = 30
        request.httpMethod = "POST"; request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model":modelName,"messages":[["role":"user","content":"Reply OK."]],"max_tokens":16])
        let (data, response) = try await controlSession.data(for: request, delegate: ControlNoRedirects.shared)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]], !choices.isEmpty else {
            throw DesktopError.message(String(localized: "模型连接验证失败，请检查地址、模型名称和密钥。"))
        }
    }

    func stopAgent() {
        UserDefaults.standard.set(false, forKey: resumeKey)
        agentProcess?.terminate()
        // Keep ownership until termination. A second start must not race shutdown and the runtime lease.
    }

    private func launchAgent() throws {
        guard agentProcess?.isRunning != true else { return }
        lastAgentLaunchAttempt = Date()
        let running = try process("Apps/MacApp/Runtime/momo_agent.py", ["serve"])
        agentProcess = running
        running.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self, self.agentProcess === process else { return }
                self.agentProcess = nil
                if !self.shuttingDown, UserDefaults.standard.bool(forKey: self.resumeKey) {
                    self.failure = String(localized: "MoMo 已停止，任务记录仍保留。请重新启动；运行详情见 desktop-momo_agent.log。")
                }
                await self.refresh()
            }
        }
        taskStore?.foreground()
    }

    private struct RecordedProcess: Codable {
        let pid: Int32
        let repository: String
    }

    private func pidFile(for script: String) -> URL {
        let name = URL(fileURLWithPath: script).deletingPathExtension().lastPathComponent
        return dataDirectory.appendingPathComponent("runtime/desktop-\(name).pid")
    }

    private func isRuntimeProcess(pid: Int32, script: String) -> Bool {
        guard pid > 1, kill(pid, 0) == 0 else { return false }
        let name = URL(fileURLWithPath: script).lastPathComponent
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return output.contains(name) && output.contains(dataDirectory.path)
    }

    private func reclaimStaleRuntimeProcesses() async throws {
        for script in ["Apps/MacApp/Access/access_server.py", "Apps/MacApp/Runtime/momo_agent.py"] {
            let file = pidFile(for: script)
            guard let data = try? Data(contentsOf: file),
                  let recorded = try? JSONDecoder().decode(RecordedProcess.self, from: data) else { continue }
            if isRuntimeProcess(pid: recorded.pid, script: script), kill(recorded.pid, SIGTERM) == 0 {
                for _ in 0..<700 {
                    if kill(recorded.pid, 0) != 0 { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            if isRuntimeProcess(pid: recorded.pid, script: script) {
                // Recheck identity before escalation; never lose the PID of a surviving owner.
                guard kill(recorded.pid, SIGKILL) == 0 else { throw POSIXError(.EBUSY) }
                for _ in 0..<40 {
                    if kill(recorded.pid, 0) != 0 { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard !isRuntimeProcess(pid: recorded.pid, script: script) else { throw POSIXError(.EBUSY) }
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func process(_ script: String, _ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = runtimePython
        let isolation = hasBundledRuntime ? ["-I", "-B"] : []
        process.arguments = isolation + ["-X", "pycache_prefix=" + dataDirectory.appendingPathComponent("runtime/bytecode").path,
                             repository.appendingPathComponent(script).path] + arguments + ["--data-dir", dataDirectory.path]
        process.environment = ProcessInfo.processInfo.environment.filter {
            ["PATH", "HOME", "USER", "LANG", "TMPDIR", "SHELL", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
             "http_proxy", "https_proxy", "all_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE"].contains($0.key)
        }
        process.environment?["PATH"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
            + ":" + FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/pnpm").path
            + ":" + FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/pnpm").path
            + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.currentDirectoryURL = repository
        let log = dataDirectory.appendingPathComponent("runtime/desktop-" + URL(fileURLWithPath: script).deletingPathExtension().lastPathComponent + ".log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle; process.standardError = handle
        try process.run(); try handle.close()
        if let recorded = try? JSONEncoder().encode(RecordedProcess(pid: process.processIdentifier, repository: repository.resolvingSymlinksInPath().path)) {
            try? privateWrite(recorded, to: pidFile(for: script))
        }
        return process
    }

    private func command(_ executable: String, _ arguments: [String]) async throws {
        let directory = dataDirectory
        let update: @MainActor @Sendable (DesktopPreparationEvents.Event) -> Void = { [weak self] event in
            guard let self, self.preparationPhase != nil else { return }
            switch event {
            case .phase(let phase): self.preparationPhase = phase; self.preparationDownload = nil
            case .download(let name, let received, let total):
                var download = self.preparationDownload ?? DesktopDownloadProgress()
                download.record(name: name, received: received, total: total)
                self.preparationDownload = download
            }
        }
        try await Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
            let log = directory.deletingLastPathComponent().appendingPathComponent("momo-prepare.log")
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
            var master: Int32 = 0, slave: Int32 = 0
            var size = winsize(ws_row: 80, ws_col: 240, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(master) }
            let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
            p.standardInput = FileHandle.nullDevice; p.standardOutput = terminal; p.standardError = terminal
            p.environment = ProcessInfo.processInfo.environment
            p.environment?["TERM"] = "xterm-256color"; p.environment?["COLUMNS"] = "240"
            p.environment?["NO_COLOR"] = nil; p.environment?["RUST_LOG"] = nil
            p.environment?["UV_NO_PROGRESS"] = nil; p.environment?["JPY_SESSION_NAME"] = nil
            try p.run()
            try terminal.close()
            var events = DesktopPreparationEvents()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(master, &buffer, buffer.count)
                if count == 0 || count < 0 && errno == EIO { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    p.terminate(); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let chunk = Data(buffer.prefix(count))
                try handle.write(contentsOf: chunk)
                for event in events.append(chunk) { await update(event) }
            }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw DesktopError.message(String(localized: "运行环境准备失败，请重试。详情见 momo-prepare.log。")) }
        }.value
    }

    @discardableResult func control(_ path: String, body: [String: Any] = [:]) async -> Bool {
        guard busy == nil else { return false }
        busy = String(localized: "正在更新连接…"); defer { busy = nil }
        do {
            status = try await controlRequest(path, body: body); failure = nil; return true
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
            return false
        }
    }

    func refresh() async {
        guard connection != nil, !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            status = try await controlRequest("status")
            restorePairedInstallationIfNeeded()
            if !shuttingDown, busy == nil, UserDefaults.standard.bool(forKey: resumeKey),
               status?.agentOnline != true, agentProcess?.isRunning != true,
               Date().timeIntervalSince(lastAgentLaunchAttempt) >= 6 {
                try? launchAgent()
            }
            if status?.agentOnline == true,
               failure == String(localized: "MoMo 已停止，任务记录仍保留。请重新启动；运行详情见 desktop-momo_agent.log。") {
                failure = nil
            }
            await refreshEmbeddedAccess()
            if setupStep == .pair || isPairingDevice {
                if status?.tunnel.state == "connected", status?.invitation == nil, !pairingAccepted {
                    status = try await controlRequest("pair/invite", body: [:])
                }
            }
            if status?.agentOnline == true, taskStore == nil, let connection {
                let client = try baseClient(for: connection)
                taskStore = try Self.openTaskStore(file: dataDirectory.appendingPathComponent("desktop-tasks.json"), connection: connection, client: client)
                taskStore?.foreground()
            }
            if status?.agentOnline == true, !fetchingContext, Date().timeIntervalSince(lastContextRefreshAt) >= 15 {
                Task { [weak self] in await self?.loadContext(silent: true) }
            }
            if runtimeEngine == .superagent, status?.agentOnline == true {
                await refreshProactiveSnapshot()
            } else {
                proactiveSnapshot = nil
            }
        } catch {
            status = nil
            if !shuttingDown, isPrepared, accessProcess?.isRunning != true {
                try? startAccess()
            }
        }
    }

    private func restorePairedInstallationIfNeeded() {
        guard hasPairedPhone else { return }
        let defaults = UserDefaults.standard
        // An explicit stop always wins. Older installs may have only the data directory.
        if defaults.object(forKey: resumeKey) == nil,
           let config = Self.readModelConfiguration(from: dataDirectory.appendingPathComponent("hermes/config.yaml")),
           let provider = config["provider"], !provider.isEmpty,
           let model = config["default"], !model.isEmpty {
            defaults.set(true, forKey: resumeKey)
        }
        let setupKey = "setup." + dataDirectory.path
        if defaults.object(forKey: setupKey) == nil, status?.agentOnline == true {
            advanceSetup(.completed)
        }
    }

    private func controlRequest(_ path: String, body: [String: Any]? = nil) async throws -> AccessStatus {
        guard let connection, let port = connection.baseURL.port,
              let url = URL(string: "http://127.0.0.1:\(port + 3)/" + path) else { throw DesktopError.message(String(localized: "请先准备运行环境。")) }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await controlSession.data(for: request, delegate: ControlNoRedirects.shared)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            if path.hasPrefix("tunnel/") {
                throw DesktopError.message(String(localized: "连接设置未完成，请检查地址和网络后重试。"))
            }
            throw DesktopError.message(String(localized: "操作未完成，请检查连接状态；配对码可能已过期。"))
        }
        return try JSONDecoder().decode(AccessStatus.self, from: data)
    }

    func applyNetworkProxy(_ settings: TailnetProxySettings) async throws {
        try await tailnet.updateProxy(settings)
        await refreshEmbeddedAccess()
    }

    private func refreshEmbeddedAccess() async {
        guard busy == nil else { return }
        guard status?.tunnel.mode == "embedded", status?.tunnel.state != "stopped" else {
            if tailnet.node != nil { await tailnet.close() }
            return
        }
        var body: [String: Any] = ["state": "needs_setup", "error": String(localized: "请登录 Tailscale。")]
        var probeSession: URLSession?
        do {
            try await tailnet.start()
            if tailnet.state == "Running", let host = tailnet.address, let node = tailnet.node,
               let port = connection?.baseURL.port {
                try await node.serveLoopbackHTTP(port: Int32(port + 2))
                let url = URL(string: "http://\(host):\(TailnetEndpoint.port)")!
                let session = try await tailnet.connectedSession()
                probeSession = session
                var request = URLRequest(url: url.appendingPathComponent("pair/identity")); request.timeoutInterval = 5
                let (data, response) = try await session.data(for: request)
                let identity = try JSONSerialization.jsonObject(with: data) as? [String: String]
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      identity?["instance_id"]?.lowercased() == connection?.instanceID.uuidString.lowercased() else { throw TailnetError.unavailable }
                embeddedProbeFailures = 0
                lastEmbeddedEndpoint = url.absoluteString
                tailnetAccessError = nil
                body = ["state": "connected", "endpoint": url.absoluteString]
            } else {
                tailnetAccessError = nil
                body["error"] = tailnet.state == "Running" ? String(localized: "正在连接…") : tailnet.message ?? String(localized: "请登录 Tailscale。")
            }
        } catch {
            if let probeSession { tailnet.failedRequest(error, session: probeSession) }
            if tailnet.state == "Running", let lastEmbeddedEndpoint, embeddedProbeFailures < 2 {
                embeddedProbeFailures += 1
                tailnet.prepareForForeground()
                tailnetAccessError = nil
                body = ["state": "reconnecting", "endpoint": lastEmbeddedEndpoint, "error": String(localized: "正在恢复连接…")]
            } else {
                tailnetAccessError = String(localized: "连接未完成，请重试。")
                body["error"] = tailnetAccessError
            }
        }
        do { status = try await controlRequest("tunnel/embedded", body: body) }
        catch { if !AgentTransportFailure.isTransient(error) { failure = error.localizedDescription } }
    }

    func logoutTailnet() async {
        guard busy == nil else { return }
        busy = String(localized: "正在退出账号…"); defer { busy = nil }
        do {
            status = try await controlRequest("tunnel/stop", body: [:])
            lastEmbeddedEndpoint = nil; embeddedProbeFailures = 0
            try await tailnet.logout()
        } catch { failure = error.localizedDescription }
    }

    func loadContext(silent: Bool = false) async {
        if fetchingContext {
            contextRefreshRequested = true
            contextRefreshNonSilent = contextRefreshNonSilent || !silent
            return
        }
        guard let connection, let url = connection.dataURL else { memoryError = String(localized: "Mac 尚未连接。"); return }
        fetchingContext = true
        var runSilent = silent
        defer {
            fetchingContext = false
            contextLoading = false
        }
        repeat {
            contextRefreshRequested = false
            if contextRefreshNonSilent {
                runSilent = false
                contextRefreshNonSilent = false
            }
            let showLoading = !runSilent || (sources.isEmpty && memories.isEmpty)
            if showLoading { contextLoading = true }
            lastContextRefreshAt = Date()
            do {
                let client = try dataClient(for: connection, url: url)
                let contextStatus = try await client.contextStatus()
                memoryReviewStatus = contextStatus.memoryReview
                transcriptMemoryNeedsReview = contextStatus.memoryNeedsReview ?? 0
                var collected: [ContextMemory] = []; var cursor: String?; var revision: Int64?
                repeat {
                    let page = try await client.memories(after: cursor, revision: revision)
                    collected += page.items; cursor = page.nextCursor; revision = page.revision
                } while cursor != nil
                memories = collected
                var recordings: [ContextSource] = []; cursor = nil
                repeat {
                    let page = try await client.sources(after: cursor, summarize: true)
                    recordings += page.items; cursor = page.nextCursor
                } while cursor != nil
                sources = recordings
                memoryError = nil
            } catch {
                if !runSilent || sources.isEmpty {
                    memoryError = AgentTransportFailure.isTransient(error) ? String(localized: "正在恢复本地资料连接…") : error.localizedDescription
                }
            }
            runSilent = true
        } while contextRefreshRequested && !Task.isCancelled
    }

    func forgetMemory(_ memory: ContextMemory) async throws {
        guard let connection, let url = connection.dataURL else { throw DesktopError.message(String(localized: "Mac 尚未连接。")) }
        try await dataClient(for: connection, url: url).forget(ForgetMemory(memory: memory))
        await loadContext()
    }

    func readSource(_ source: ContextSource, offset: Int = 0, limit: Int? = nil) async throws -> SourceTextPage {
        guard let connection, let url = connection.dataURL else { throw DesktopError.message(String(localized: "Mac 尚未连接。")) }
        return try await dataClient(for: connection, url: url).sourceText(source, offset: offset, limit: limit)
    }

    func readRecordingCitation(_ citation: RecordingCitation) async throws -> ResolvedRecordingCitation {
        guard let connection, let url = connection.dataURL else { throw DesktopError.message(String(localized: "Mac 尚未连接。")) }
        return try await dataClient(for: connection, url: url).recordingCitation(citation)
    }

    func advanceSetup(_ step: SetupStep) {
        setupStep = step; failure = nil
        UserDefaults.standard.set(step.rawValue, forKey: "setup." + dataDirectory.path)
    }
    func continueWelcome() {
        if !isPrepared {
            advanceSetup(.prepare)
        } else if status?.agentOnline != true {
            advanceSetup(.model)
        } else {
            advanceSetup(hasDesktopPermissions ? .pair : .permissions)
        }
    }
    func prepareAndContinue() async { await prepare(); if isPrepared && failure == nil { advanceSetup(.model) } }
    func startAndContinue() async {
        await startAgent()
        guard failure == nil, !modelConnectionCancelled else { return }
        busy = String(localized: "正在等待 MoMo 就绪…"); defer { busy = nil }
        for _ in 0..<60 {
            await refresh()
            if status?.agentOnline == true { advanceSetup(hasDesktopPermissions ? .pair : .permissions); return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
        failure = String(localized: "MoMo 尚未就绪，请检查模型配置后重试。")
    }
    func beginPairing() async {
        if status?.tunnel.state == "connected", status?.invitation == nil, !pairingAccepted {
            _ = await control("pair/invite")
        }
    }
    func rememberReadingPosition(_ position: ChatReadingPosition) { readingPosition = position }

    func prepareDesktop() {
        guard desktopHost == nil, !key.isEmpty, let port = connection?.baseURL.port else { return }
        do { desktopHost = try DesktopControlHost(data: dataDirectory, key: key, tailnet: tailnet, controlPort: port + 3); desktopFailure = nil }
        catch { desktopFailure = error.localizedDescription }
    }

    func shutdown() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
        Task { await tailnet.close() }
        desktopHost?.stop(); desktopHost = nil
        cancelModelConnection()
        shuttingDown = true; timer?.cancel(); taskStore?.background(); accessProcess?.terminate(); agentProcess?.terminate()
        controlSession.finishTasksAndInvalidate()
    }
    func showFiles() { NSWorkspace.shared.open(dataDirectory.appendingPathComponent("workspace")) }

    func loadEngineConfiguration() {
        let file = dataDirectory.appendingPathComponent("runtime/engine.json")
        guard let raw = try? Data(contentsOf: file),
              let parsed = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            runtimeEngine = .superagent
            return
        }
        if let eng = parsed["engine"] as? String, let resolved = DesktopAgentEngine(rawValue: eng) {
            runtimeEngine = resolved
        } else {
            runtimeEngine = .superagent
        }
    }

    private func writeEngineConfiguration(engine: DesktopAgentEngine) throws {
        let file = dataDirectory.appendingPathComponent("runtime/engine.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload: [String: String] = ["engine": engine.rawValue, "proactive_mode": "auto"]
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try privateWrite(encoded, to: file)
    }

    func switchRuntimeEngine(_ target: DesktopAgentEngine) async {
        guard busy == nil, target != runtimeEngine else { return }
        let wasRunning = status?.agentOnline == true || agentProcess?.isRunning == true
        busy = String(localized: "正在切换智能体引擎…")
        failure = nil
        preparationPhase = .agent
        defer { busy = nil; preparationPhase = nil; preparationDownload = nil }
        do {
            if wasRunning {
                agentProcess?.terminate()
                for _ in 0..<80 {
                    if agentProcess == nil { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            try writeEngineConfiguration(engine: target)
            runtimeEngine = target
            proactiveSnapshot = nil
            try await prepareRuntime()
            if wasRunning {
                try startAccess()
                try launchAgent()
                UserDefaults.standard.set(true, forKey: resumeKey)
            }
            await refresh()
        } catch {
            loadEngineConfiguration()
            failure = error.localizedDescription
        }
    }

    func refreshProactiveSnapshot() async {
        guard let connection, !key.isEmpty else { return }
        var request = URLRequest(url: connection.baseURL.appendingPathComponent("momo/v1/proactive"))
        request.timeoutInterval = 5
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await controlSession.data(for: request, delegate: ControlNoRedirects.shared),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let ready = (json["dsh_ready"] as? Bool) ?? false
        let tickets = (json["tickets"] as? [[String: Any]]) ?? []
        let decisions = (json["decisions"] as? [[String: Any]]) ?? []
        let activeCount = tickets.filter { item in
            let state = (item["state"] as? String) ?? (item["outcome"] as? String) ?? ""
            return !["ended", "completed", "merged", "dropped", "stopped", "canceled"].contains(state)
        }.count
        let latest = decisions.first.flatMap { item -> String? in
            let kind = (item["kind"] as? String) ?? ""
            if kind.isEmpty { return nil }
            if let reason = item["reason"] as? String, !reason.isEmpty {
                return "\(kind): \(reason)"
            }
            if let reasons = item["reason"] as? [[String: Any]],
               let code = reasons.first?["code"] as? String, !code.isEmpty {
                return "\(kind): \(code)"
            }
            return kind
        }
        proactiveSnapshot = DesktopProactiveSnapshot(
            dshReady: ready,
            activeTickets: activeCount,
            totalDecisions: decisions.count,
            latestSummary: latest
        )
    }

    private func privateWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum DesktopError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self {
            return Bundle.main.localizedString(forKey: message, value: message, table: nil)
        }
        return nil
    }
}

private final class ControlNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = ControlNoRedirects()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
