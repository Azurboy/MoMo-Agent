# Native embedded-network probe

Use synthetic data only. Build `Scripts/build-tailscale-kit.sh` first.

1. Run `go run ./tstestcontrol` from `Vendor/TailscaleKit`; it prints a local control URL and provides local DERP/STUN. Stop with Ctrl-C after testing.
2. macOS: compile `EmbeddedProbe.swift` with `swiftc -parse-as-library`, `-F Vendor/TailscaleKit/Build/TailscaleKit.xcframework/macos-arm64_x86_64`, `-framework TailscaleKit`, and an rpath to that framework directory. Run with the printed URL and an empty temporary state directory.
3. Simulator: generate `Simulator/project.yml` with the pinned XcodeGen, build `MoMoTailnetProbe`, install on one simulator, and launch with `--control <local URL>`. The test app writes `Documents/result.txt` and displays the result. Remove this dedicated simulator after collecting evidence.
4. Go forwarding regression: `go test -run TestMoMoProxy -v .` from `Vendor/TailscaleKit`.

The same Swift probe creates two genuine SDK nodes with HTTPS Certificates disabled. It exercises the production `serveLoopbackHTTP` forwarder on port 8767, streams SSE before completion, checks that requests through a closed proxy fail, closes/recreates one node while retaining its directory, checks the same IP, and resumes the same run with Last-Event-ID. Both the product and probe use HTTP inside the encrypted tailnet. The simulator uses the same `100.64.0.0/10` ATS exception as the product, never NSAllowsArbitraryLoads. It does not use a real Tailscale account or a user's phone. Simulator success does not prove physical background networking, roaming, or real-account pairing.

## Foreground / peer-failure recovery

`RecoveryProbe.swift` compiles together with the production `EmbeddedTailnet.swift`, `EmbeddedTailnetTransport.swift`, their diagnostics and proxy settings, and `MoMoAgentClient`. Run it with three arguments: synthetic control URL, an empty temporary state directory, and the port of a loopback HTTP fixture that returns 200 at `/`. Link the same macOS TailscaleKit framework and MoMoAgentClient module as the product. It creates two real SDK nodes, forwards the fixture through the server node, and checks:

- Five foreground transitions with eight concurrent requests each retain the healthy session and node.
- Three missing-peer timeouts and eight requests with the remote HTTP listener stopped preserve the client node and chat session. Restarting that listener restores HTTP on the same chat session.
- Closing the local SDK node simulates a dead listener: recovery preserves its address and resumes HTTP.
- Late requests on the replaced session receive a transport error, and late failures preserve the recovered session. Logout stays logged out.

The pre-fix implementation fails at `Foreground replaced a healthy session`. The probe does not establish real iOS suspension or cellular/Wi-Fi roaming reliability.
