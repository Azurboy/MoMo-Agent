import Foundation
import Darwin
import TailscaleKit

/// Uses two real SDK nodes and a synthetic control server; no user account or phone data.
@main struct RecoveryProbe {
    enum Check: Error { case failed(String) }

    @MainActor static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        let control = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let port = Int32(CommandLine.arguments[3])!
        let server = try TailscaleNode(config: Configuration(hostName: "recovery-server",
            path: root.appendingPathComponent("server").path, authKey: nil, controlURL: control), logger: nil)
        let client = EmbeddedTailnet(directory: root.appendingPathComponent("client"), device: "test", controlURL: control)
        do {
            try await server.up()
            try await server.serveLoopbackHTTP(port: port)
            let address = try await server.addrs().ip4!
            let url = URL(string: "http://\(address):8767/")!
            @Sendable func check(_ passed: Bool, _ message: String) throws {
                guard passed else { throw Check.failed(message) }
            }
            @Sendable func read(_ session: URLSession) async throws {
                let response = try await TailnetChunkStream.read(URLRequest(url: url), session: session, network: client, limit: 1024)
                try check(response.status == 200, "Private HTTP failed")
            }
            let original = try await client.connectedSession(peer: address)
            let missingPeer = Task { try await client.connectedSession(peer: "100.127.255.254") }
            try await Task.sleep(for: .milliseconds(300))
            missingPeer.cancel()
            do {
                _ = try await missingPeer.value
                throw Check.failed("Cold request obtained a session before its peer was mapped")
            } catch is CancellationError {}
            try await read(original)
            let generation = client.generation
            let addressBefore = client.address
            for _ in 0..<5 {
                client.prepareForForeground()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<8 {
                        group.addTask {
                            let session = try await client.connectedSession()
                            try check(session === original, "Foreground replaced a healthy session")
                            try await read(session)
                        }
                    }
                    try await group.waitForAll()
                }
                try check(client.generation == generation, "Foreground restarted a healthy node")
            }
            let chat = try await client.connectedSession(peer: address, interactive: true)
            client.peerMapTimeout = .milliseconds(250)
            for _ in 0..<3 {
                do {
                    _ = try await client.connectedSession(peer: "100.127.255.254")
                    throw Check.failed("An unmapped peer was dialed")
                } catch let error as URLError where error.code == .notConnectedToInternet {}
            }
            try await read(chat)

            // Drop the remote HTTP listener while both tailnet nodes remain healthy.
            await server.stopServing()
            var current = original
            for _ in 0..<8 {
                var request = URLRequest(url: url)
                request.timeoutInterval = 2
                do {
                    _ = try await TailnetChunkStream.read(request, session: current, network: client, limit: 1024)
                    throw Check.failed("Offline Mac accepted a request")
                } catch let error as URLError {
                    client.failedRequest(error, session: current)
                }
                let session = try await client.connectedSession(peer: address)
                try check(client.generation == generation, "Peer failure restarted a healthy local proxy")
                try check(session !== current, "Failed request retained the failed session")
                current = session
            }
            try await server.serveLoopbackHTTP(port: port)
            let resumedChat = try await client.connectedSession(peer: address, interactive: true)
            try check(resumedChat === chat, "Peer outage replaced the independent chat session")
            try await read(resumedChat)

            // Simulate the local listener disappearing while the app is suspended.
            try await client.node!.close()
            client.prepareForForeground()
            let recovered = try await client.connectedSession()
            try check(recovered !== original && client.generation != generation, "Dead local proxy was not rebuilt")
            try check(client.address == addressBefore, "Recovery changed the paired node address")
            try await read(recovered)
            do {
                try await read(original)
                throw Check.failed("A late request ran on a retired pool")
            } catch let error as URLError where error.code == .networkConnectionLost {}
            let recoveredGeneration = client.generation
            client.failedRequest(URLError(.timedOut), session: original)
            let retained = try await client.connectedSession()
            try check(retained === recovered && client.generation == recoveredGeneration, "Stale session invalidated recovery")
            try await client.logout()
            do {
                _ = try await client.connectedSession()
                throw Check.failed("Logout was undone by a network request")
            } catch TailnetError.loginRequired { }
            print("PASS: unmapped peer waits and cancels; 40 foreground reads reuse the node/session; unmapped peer and eight offline Mac requests preserve chat; HTTP resumes on the original node; dead proxy rebuilds with same address; late requests on retired pools fail safely; stale failures ignored; logout stays logged out")
        } catch {
            await client.close(); try? await server.close()
            throw error
        }
        await client.close(); try await server.close()
    }
}
