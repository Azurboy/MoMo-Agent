// swift-tools-version: 6.2
import Foundation
import PackageDescription

let hasLegacyPiDurableKit = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../Vendor/PiDurableKit/Package.swift").path
)

var packageDependencies: [Package.Dependency] = [.package(path: "../../Packages/MoMoAgentKit")]
var packageTargets: [Target] = [
    .executableTarget(name: "CrashRecoveryReplay", dependencies: [
        .product(name: "MoMoContracts", package: "MoMoAgentKit"),
        .product(name: "MoMoRecording", package: "MoMoAgentKit"),
        .product(name: "MoMoArchive", package: "MoMoAgentKit")
    ])
]

if hasLegacyPiDurableKit {
    packageDependencies.append(.package(path: "../../Vendor/PiDurableKit"))
    packageTargets.append(.executableTarget(name: "AgentCrashRecoveryReplay", dependencies: [
        .product(name: "MoMoContracts", package: "MoMoAgentKit"),
        .product(name: "MoMoRecording", package: "MoMoAgentKit"),
        .product(name: "MoMoArchive", package: "MoMoAgentKit"),
        .product(name: "MoMoAgent", package: "MoMoAgentKit"),
        .product(name: "PiDurableKit", package: "PiDurableKit")
    ]))
}

let package = Package(
    name: "CrashRecoveryReplay",
    platforms: [.macOS(.v15)],
    dependencies: packageDependencies,
    targets: packageTargets
)
