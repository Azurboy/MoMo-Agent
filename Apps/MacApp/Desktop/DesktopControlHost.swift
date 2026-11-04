import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Observation
import ScreenCaptureKit

/// The app owns capture/input permissions. Only the private runtime IPC can reach this host.
@MainActor @Observable
final class DesktopControlHost {
    private let directory: URL
    private let key: String
    private let inputDriver = DesktopInputDriver()
    private let accessibilityDriver = AgentDesktopDriver()
    private let pimDriver = DesktopPIMDriver()
    private let screenStream = DesktopScreenStream()
    private let videoHost: DesktopVideoHost
    private var inputOwner: String?
    private var inputOrder = DesktopInputOrder()
    private var lastInput = Date.distantPast
    @ObservationIgnored private var inputWatchdog: Task<Void, Never>?
    private var inputReceipts: [String: Data] = [:]
    private var receiptOrder: [String] = []
    @ObservationIgnored private var server: DesktopUnixServer?
    var humanHasControl = false

    init(data: URL, key: String, tailnet: EmbeddedTailnet, controlPort: Int) throws {
        videoHost = DesktopVideoHost(tailnet: tailnet, key: key, port: controlPort)
        directory = data.appendingPathComponent("desktop")
        self.key = key
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let resolved = realpath(data.path, nil) else { throw DesktopError.message("桌面数据目录不可用。") }
        let canonical = String(cString: resolved); free(resolved)
        let hash = SHA256.hash(data: Data(canonical.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let socket = "/tmp/momo-desktop-" + hash + "/control.sock"
        server = try DesktopUnixServer(path: socket) { [weak self] input, reply in
            Task { @MainActor in
                guard let self else { reply(Data("{\"error\":\"桌面服务已关闭。\"}\n".utf8)); return }
                let result: [String: Any]
                do {
                    guard let request = try JSONSerialization.jsonObject(with: input) as? [String: Any], request["key"] as? String == self.key else {
                        throw DesktopError.message("桌面请求未获授权。")
                    }
                    guard input.count <= 16384 || request["op"] as? String == "video-offer" else { throw DesktopError.message("电脑请求过大。") }
                    result = try await self.handle(request)
                } catch { result = ["error": error.localizedDescription] }
                do { var data = try JSONSerialization.data(withJSONObject: result); data.append(10); reply(data) }
                catch { reply(Data("{\"error\":\"桌面响应不可用。\"}\n".utf8)) }
            }
        }
    }

    func stop() {
        videoHost.stop()
        Task { await screenStream.stop() }
        inputWatchdog?.cancel(); inputWatchdog = nil
        inputDriver.reset(); inputOwner = nil
        server?.stop(); server = nil
    }

    func returnControl() throws {
        let lock = open(directory.appendingPathComponent("lease.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw DesktopError.message("无法交还控制权。") }
        flock(lock, LOCK_EX); defer { flock(lock, LOCK_UN); close(lock) }
        let previous = try lease()
        var returned: [String: Any] = ["owner": "agent", "epoch": (previous["epoch"] as? Int ?? 0) + 1]
        returned["agent_work"] = previous["agent_work"]
        let data = try JSONSerialization.data(withJSONObject: returned)
        try data.write(to: directory.appendingPathComponent("lease.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("lease.json").path)
        inputDriver.reset(); inputOwner = nil
        humanHasControl = false
    }

    private func lease() throws -> [String: Any] {
        let file = directory.appendingPathComponent("lease.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return ["owner": "agent", "epoch": 0] }
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              ["human", "agent"].contains(value["owner"] as? String ?? ""), value["epoch"] is Int else {
            throw DesktopError.message("控制权记录不可用，已暂停电脑操作。")
        }
        humanHasControl = value["owner"] as? String == "human"
        return value
    }

    private func admit(_ request: [String: Any], input: Bool = false) throws -> Int {
        let current = try lease(), actor = request["actor"] as? String
        guard actor == "human" || actor == "agent" else { throw DesktopError.message("未知控制身份。") }
        if actor == "agent" {
            guard current["owner"] as? String == "agent" else { throw DesktopError.message("用户已接管电脑。请等待用户交还控制权，不能继续查看屏幕或操作电脑。") }
            guard let control = request["control"] as? [String: Any],
                  let work = current["agent_work"] as? [String: Any],
                  control["epoch"] as? Int == current["epoch"] as? Int,
                  control["work_id"] as? String == work["work_id"] as? String,
                  control["run_id"] as? String == work["run_id"] as? String,
                  control["generation"] as? Int == work["generation"] as? Int else {
                throw DesktopError.message("电脑任务已变化，请重新读取画面。")
            }
        } else {
            guard let viewer = request["viewer"] as? String, UUID(uuidString: viewer) != nil, request["paired"] as? Bool == true else { throw DesktopError.message("请先配对这台手机。") }
            if current["owner"] as? String == "human", current["viewer"] as? String != viewer {
                throw DesktopError.message("另一台设备正在控制电脑。")
            }
            if input {
                guard current["owner"] as? String == "human", let session = current["session"] as? String, UUID(uuidString: session) != nil,
                      session == request["session"] as? String,
                      (current["expires"] as? Double ?? 0) > Date.now.timeIntervalSince1970 else {
                    throw DesktopError.message("控制连接已失效，请重新接管。")
                }
            }
        }
        return current["epoch"] as? Int ?? 0
    }

    private func handle(_ request: [String: Any]) async throws -> [String: Any] {
        let op = request["op"] as? String
        let viewer = request["viewer"] as? String ?? ""
        if request["actor"] as? String == "human" {
            guard UUID(uuidString: viewer) != nil, request["paired"] as? Bool == true else { throw DesktopError.message("请先配对这台手机。") }
        }
        reconcileInput()
        // Pairing is approved locally once. Remote polling never opens another host approval dialog.
        if op == "status" || op == "request" {
            let current = try lease(), yours = current["viewer"] as? String == viewer
            var result: [String: Any] = ["approved": request["paired"] as? Bool == true, "screen": CGPreflightScreenCaptureAccess(),
                "input": AXIsProcessTrusted(), "owner": current["owner"] as? String == "human" ? (yours ? "you" : "other") : "agent",
                "epoch": current["epoch"] ?? 0, "active": (current["expires"] as? Double ?? 0) > Date.now.timeIntervalSince1970]
            if yours {
                result["session"] = current["session"]
                let owner = "\(current["epoch"] as? Int ?? 0):" + (current["session"] as? String ?? "")
                result["input_sequence"] = inputOrder.last(for: owner)
            }
            return result
        }
        if op == "pim" {
            guard request["actor"] as? String == "agent",
                  let pimOp = request["pim_op"] as? String else {
                throw DesktopError.message("个人事项请求无效。")
            }
            let argsData = try JSONSerialization.data(withJSONObject: request["args"] as? [String: Any] ?? [:])
            let responseData = try await pimDriver.perform(op: pimOp, argsData: argsData)
            return (try JSONSerialization.jsonObject(with: responseData) as? [String: Any]) ?? [:]
        }
        let epoch = try admit(request, input: op == "input")
        if op == "video-offer" {
            guard request["actor"] as? String == "human", CGPreflightScreenCaptureAccess() else { throw DesktopError.message("请先在 Mac 开启屏幕录制权限。") }
            return try await videoHost.offer(request)
        }
        if op == "accessibility-snapshot" || op == "accessibility-action" {
            guard request["actor"] as? String == "agent", AXIsProcessTrusted() else {
                throw DesktopError.message("请先在 Mac 的「屏幕与控制权限」中开启辅助功能。")
            }
            let payload = try JSONSerialization.data(withJSONObject: request)
            let driver = accessibilityDriver, directory = directory
            let response = try await Task.detached { try driver.perform(payload, directory: directory) }.value
            guard try admit(request) == epoch else { throw DesktopError.message("电脑控制权已变化，请重新读取界面。") }
            return ["result": try JSONSerialization.jsonObject(with: response)]
        }
        if op == "frame" {
            guard CGPreflightScreenCaptureAccess() else { throw DesktopError.message("Mac 的屏幕录制权限尚未生效，请在 Mac 的「屏幕与控制权限」中检查。") }
            let image = try await screenStream.frame()
            let preview = request["preview"] as? Bool == true
            let edge = min(1440, max(320, request["edge"] as? Int ?? 960))
            let encoded = try await Task.detached {
                var rendered = image
                if preview {
                    let (width, height) = DesktopScreenStream.size(width: image.width, height: image.height, edge: edge)
                    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw DesktopError.message("无法缩放电脑画面。") }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                    guard let scaled = context.makeImage() else { throw DesktopError.message("无法缩放电脑画面。") }
                    rendered = scaled
                }
                guard let data = NSBitmapImageRep(cgImage: rendered).representation(using: .jpeg, properties: [.compressionFactor: preview ? 0.45 : 0.65]) else { throw DesktopError.message("无法读取电脑桌面。") }
                return (data, rendered.width, rendered.height)
            }.value
            guard try admit(request) == epoch else { throw DesktopError.message("控制权已变化，请重新读取桌面。") }
            return ["jpeg": encoded.0.base64EncodedString(), "width": encoded.1, "height": encoded.2]
        }
        if op == "input" {
            let lock = open(directory.appendingPathComponent("lease.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lock >= 0 else { throw DesktopError.message("控制权记录暂时不可用。") }
            flock(lock, LOCK_EX); defer { flock(lock, LOCK_UN); close(lock) }
            let inputEpoch = try admit(request, input: true)
            guard AXIsProcessTrusted() else { throw DesktopError.message("Mac 的辅助功能权限尚未生效，请在 Mac 的「屏幕与控制权限」中检查。") }
            guard let event = request["event"] as? [String: Any] else { throw DesktopError.message("电脑操作内容无效。") }
            guard let id = request["event_id"] as? String, UUID(uuidString: id) != nil else { throw DesktopError.message("操作编号无效。") }
            let signature = try JSONSerialization.data(withJSONObject: event, options: .sortedKeys)
            let receipt = String(inputEpoch) + ":" + id
            if let previous = inputReceipts[receipt] {
                guard previous == signature else { throw DesktopError.message("操作编号对应的内容已变化。") }
                return ["ok": true]
            }
            let owner = "\(inputEpoch):" + (request["session"] as? String ?? "agent")
            if inputOwner != owner { inputDriver.reset(); inputOwner = owner }
            guard try inputOrder.accept(owner: owner, sequence: event["sequence"]) else { return ["ok": true, "discarded": true] }
            try inputDriver.perform(event)
            lastInput = .now
            if inputWatchdog == nil {
                inputWatchdog = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { break }
                        guard let self else { break }
                        self.reconcileInput()
                    }
                }
            }
            inputReceipts[receipt] = signature; receiptOrder.append(receipt)
            if receiptOrder.count > 256 { inputReceipts.removeValue(forKey: receiptOrder.removeFirst()) }
            return ["ok": true]
        }
        throw DesktopError.message("不支持的电脑操作。")
    }

    private func reconcileInput() {
        guard inputOwner != nil else { return }
        if let current = try? lease(), current["owner"] as? String == "agent",
           inputOwner == "\(current["epoch"] as? Int ?? 0):agent", Date.now.timeIntervalSince(lastInput) < 5 { return }
        guard let current = try? lease(),
              current["owner"] as? String == "human",
              (current["expires"] as? Double ?? 0) > Date.now.timeIntervalSince1970,
              inputOwner == "\(current["epoch"] as? Int ?? 0):" + (current["session"] as? String ?? "") else {
            inputDriver.reset(); inputOwner = nil; return
        }
    }

}

/// One bounded request per connection, with no TCP listener or shared screenshots on disk.
private final class DesktopUnixServer: @unchecked Sendable {
    private let descriptor: Int32
    private let path: String
    private let handler: @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void

    init(path: String, handler: @escaping @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void) throws {
        self.path = path; self.handler = handler
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.ownerAccountID] as? UInt32 == getuid(), attributes[.type] as? FileAttributeType == .typeDirectory else { throw DesktopError.message("桌面服务目录不可用。") }
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DesktopError.message("无法启动桌面服务。") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(descriptor); throw DesktopError.message("桌面服务路径过长。") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let existing = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard existing != 0 else { close(descriptor); throw DesktopError.message("桌面服务已经在运行。") }
        unlink(path)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, listen(descriptor, 8) == 0 else { close(descriptor); throw DesktopError.message("无法启动桌面服务。") }
        chmod(path, 0o600)
        DispatchQueue(label: "momo.desktop.ipc", qos: .userInitiated).async { [weak self, descriptor] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0, let self else { break }
                DispatchQueue.global(qos: .userInitiated).async { self.receive(client) }
            }
        }
    }

    func stop() { Darwin.shutdown(descriptor, SHUT_RDWR); close(descriptor); unlink(path) }

    private func receive(_ client: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var input = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while input.count <= 192 * 1024 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { close(client); return }
            input.append(contentsOf: buffer.prefix(count))
            guard input.count <= 192 * 1024 else { close(client); return }
            if input.last == 10 {
                handler(input) { response in
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { close(client) }
                        var enabled: Int32 = 1
                        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                        response.withUnsafeBytes { bytes in
                            var offset = 0
                            while offset < response.count {
                                let sent = Darwin.send(client, bytes.baseAddress!.advanced(by: offset), response.count - offset, 0)
                                if sent <= 0 { break }; offset += sent
                            }
                        }
                    }
                }
                return
            }
        }
        close(client)
    }
}
