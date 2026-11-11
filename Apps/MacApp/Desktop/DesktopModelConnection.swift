import Foundation
import Darwin

enum DesktopModelLoginFlow: String { case device, browser }

struct DesktopModelLogin: Identifiable {
    let id = UUID()
    let provider: DesktopModelProvider
    let flow: DesktopModelLoginFlow
    var authorizationURL: URL?
    var code: String?
    var expiresAt = Date.now.addingTimeInterval(300)
    var failure: String?
}

private struct ModelAuthorization: Decodable {
    let event: String
    let url: URL
    let code: String?
    let expiresAt: Double

    func accepts(_ provider: DesktopModelProvider) -> Bool {
        guard let host = url.host, url.scheme == "https", url.user == nil, url.password == nil,
              url.absoluteString.count <= 16_384, (code?.count ?? 0) <= 64,
              url.port == nil || url.port == 443 else { return false }
        switch provider {
        case .codex: return host == "auth.openai.com" && ["/codex/device", "/oauth/authorize"].contains(url.path)
        case .claude: return ["claude.ai", "console.anthropic.com", "platform.claude.com"].contains(host)
                && url.path == "/oauth/authorize"
        case .antigravity: return host == "accounts.google.com"
                && (url.path.hasPrefix("/o/oauth2") || url.path.hasPrefix("/signin") || url.path.hasPrefix("/v3/signin"))
        case .api: return false
        }
    }
}

private nonisolated func stopModelProcess(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    Task.detached {
        try? await Task.sleep(for: .seconds(2))
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

enum DesktopModelProvider: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, antigravity, api
    var id: String { rawValue }
    var label: String {
        switch self {
        case .codex: String(localized: "Codex 订阅")
        case .claude: String(localized: "Claude 订阅")
        case .antigravity: String(localized: "Antigravity 订阅")
        case .api: "API"
        }
    }
    var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        case .api: "API"
        }
    }
    var detail: String {
        switch self {
        case .codex: String(localized: "登录 ChatGPT 账号，让 MoMo 使用你的 Codex 订阅。")
        case .claude: String(localized: "通过 Claude Code 登录，让 MoMo 使用你的 Claude 订阅。")
        case .antigravity: String(localized: "通过 Antigravity CLI (agy) 登录 Google 账号，使用你的 Antigravity 订阅。")
        case .api: String(localized: "填写兼容 OpenAI 的 API 地址、模型和密钥。")
        }
    }
}

struct DesktopModelAccount: Decodable, Sendable {
    let provider: DesktopModelProvider
    let connected: Bool
    let models: [String]
    let loginAvailable: Bool
}

extension DesktopModelProvider: Decodable {}

extension DesktopModel {
    var subscriptionConnected: Bool { modelAccount?.provider == modelProvider && modelAccount?.connected == true }
    var modelActionLabel: String { modelProvider == .api || subscriptionConnected ? String(localized: "验证并继续") : String(localized: "登录 \(modelProvider.name)") }

    func refreshModelAccount(force: Bool = false) async {
        guard isPrepared, modelProvider != .api, busy == nil, modelLogin == nil else { return }
        if let task = modelAccountRefreshTask { await task.value; return }
        if !force, modelAccount?.provider == modelProvider,
           let checked = modelAccountCheckedAt, Date.now.timeIntervalSince(checked) < 300 { return }
        let provider = modelProvider
        let refreshID = UUID()
        modelAccountRefreshID = refreshID
        modelConnectionCancelled = false
        loadingModelAccount = true
        // The model owns the refresh: closing/reopening Settings must not restart the subprocess.
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if modelAccountRefreshID == refreshID {
                    loadingModelAccount = false; modelAccountRefreshTask = nil; modelAccountRefreshID = nil
                }
            }
            do {
                let account = try await modelCommand("status", provider: provider)
                guard provider == modelProvider, modelAccountRefreshID == refreshID else { return }
                applyModelAccount(account, updateSelection: false)
            } catch is CancellationError { }
            catch {
                if provider == modelProvider, modelAccountRefreshID == refreshID, !modelConnectionCancelled {
                    failure = error.localizedDescription
                }
            }
        }
        modelAccountRefreshTask = task
        await task.value
    }

    func beginModelLogin(flow: DesktopModelLoginFlow = .device) {
        guard busy == nil, modelProvider != .api else { return }
        cancelModelConnection()
        modelConnectionCancelled = false
        failure = nil
        let login = DesktopModelLogin(provider: modelProvider, flow: flow)
        modelLogin = login
        modelLoginTask = Task {
            defer { if modelLogin?.id == login.id { modelLoginTask = nil } }
            do {
                var account = try await modelCommand("status", provider: login.provider)
                guard modelLogin?.id == login.id else { return }
                if !account.connected {
                    account = try await modelCommand("login", provider: login.provider, timeout: max(0.1, login.expiresAt.timeIntervalSinceNow))
                }
                guard modelLogin?.id == login.id, !Task.isCancelled else { return }
                applyModelAccount(account)
                if account.connected { modelLoginTask = nil; modelLogin = nil }
                else { modelLogin?.failure = String(localized: "登录尚未完成，请重试。") }
            } catch is CancellationError { }
            catch { if modelLogin?.id == login.id { modelLogin?.failure = error.localizedDescription } }
        }
    }

    func connectModel(continueSetup: Bool) async {
        guard busy == nil, !loadingModelAccount, modelLogin == nil else { return }
        if modelProvider != .api, !subscriptionConnected {
            beginModelLogin()
        } else if continueSetup { await startAndContinue() }
        else { await startAgent() }
    }

    func cancelModelConnection() {
        modelConnectionCancelled = true
        modelAccountRefreshID = nil
        modelAccountRefreshTask?.cancel(); modelAccountRefreshTask = nil
        modelLoginTask?.cancel(); modelLoginTask = nil
        modelLogin = nil
        loadingModelAccount = false
        if let process = modelProcess { stopModelProcess(process) }
        modelProcess = nil
    }

    func applyModelAccount(_ account: DesktopModelAccount, updateSelection: Bool = true) {
        modelAccount = account
        if ![.codex, .antigravity].contains(account.provider) || !account.connected {
            lifeIllustrations.invalidateSupport()
        } else {
            Task { [weak self] in await self?.lifeIllustrations.refresh() }
        }
        modelAccountCheckedAt = .now
        if modelName.isEmpty || updateSelection && !account.models.contains(modelName) {
            modelName = account.models.first ?? ""
        }
    }

    func modelCommand(_ command: String, provider: DesktopModelProvider, timeout: TimeInterval? = nil) async throws -> DesktopModelAccount {
        try Task.checkCancellation()
        let loginID = modelLogin?.id
        let process = Process()
        process.executableURL = runtimePython
        let isolation = hasBundledRuntime ? ["-I", "-B"] : []
        process.arguments = isolation + ["-X", "pycache_prefix=" + dataDirectory.appendingPathComponent("runtime/bytecode").path,
                             repository.appendingPathComponent("Apps/MacApp/Runtime/model_setup.py").path,
                             command, "--provider", provider.rawValue, "--data-dir", dataDirectory.path]
        if command == "verify" { process.arguments? += ["--model", modelName] }
        if command == "login", let flow = modelLogin?.flow { process.arguments? += ["--flow", flow.rawValue] }
        process.environment = ProcessInfo.processInfo.environment.filter {
            ["PATH", "HOME", "USER", "LANG", "TMPDIR", "SHELL", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
             "http_proxy", "https_proxy", "all_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE"].contains($0.key)
        }
        process.environment?["PATH"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.currentDirectoryURL = repository
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        let log = dataDirectory.appendingPathComponent("runtime/model-setup.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        process.standardError = handle
        try process.run()
        modelProcess = process
        defer {
            if modelProcess === process { modelProcess = nil }
            try? handle.close(); try? output.fileHandleForReading.close()
        }
        let clock = ContinuousClock()
        let duration = timeout ?? (command == "login" ? 305 : 60)
        let deadline = clock.now.advanced(by: .seconds(duration))
        let watchdog = Task.detached {
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            stopModelProcess(process)
        }
        defer { watchdog.cancel() }
        let (data, code) = await withTaskCancellationHandler {
            await Task.detached {
                var buffer = Data(), result = Data()
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    if buffer.count > 1_048_576 { stopModelProcess(process); break }
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                        if let auth = try? JSONDecoder().decode(ModelAuthorization.self, from: line),
                           auth.event == "authorization", auth.accepts(provider) {
                            await MainActor.run {
                                guard command == "login", let loginID, var login = self.modelLogin,
                                      login.id == loginID else { return }
                                login.authorizationURL = auth.url
                                login.code = auth.code
                                login.expiresAt = min(login.expiresAt, Date(timeIntervalSince1970: auth.expiresAt))
                                self.modelLogin = login
                            }
                        } else { result = line }
                    }
                }
                process.waitUntilExit()
                return (buffer.isEmpty ? result : buffer, process.terminationStatus)
            }.value
        } onCancel: { stopModelProcess(process) }
        try Task.checkCancellation()
        guard modelProcess === process else { throw CancellationError() }
        guard clock.now < deadline else { throw DesktopError.message(command == "login" ? String(localized: "登录已超时，请重试。") : String(localized: "连接超时，请重试。")) }
        guard code == 0 else {
            struct Failure: Decodable { let error: String }
            let detail = try? JSONDecoder().decode(Failure.self, from: data)
            throw DesktopError.message(detail?.error ?? String(localized: "模型连接没有完成，请重试。"))
        }
        guard let account = try? JSONDecoder().decode(DesktopModelAccount.self, from: data) else {
            throw DesktopError.message(String(localized: "模型连接没有完成，请重试。"))
        }
        return account
    }
}
