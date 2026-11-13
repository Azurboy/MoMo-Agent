// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MobileWebSpeech",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "momo-web-speech", targets: ["MobileWebSpeech"])],
    dependencies: [.package(path: "../../../Packages/MoMoAgentKit")],
    targets: [.executableTarget(name: "MobileWebSpeech", dependencies: [
        .product(name: "MoMoContracts", package: "MoMoAgentKit"),
        .product(name: "MoMoSpeech", package: "MoMoAgentKit")
    ])]
)
