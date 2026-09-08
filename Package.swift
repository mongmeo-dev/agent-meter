// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AgentMeter",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "AgentMeterCore", targets: ["AgentMeterCore"]),
    .executable(name: "AgentMeter", targets: ["AgentMeter"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/sparkle-project/Sparkle",
      exact: "2.9.6"
    )
  ],
  targets: [
    .target(name: "AgentMeterCore"),
    .executableTarget(
      name: "AgentMeter",
      dependencies: [
        "AgentMeterCore",
        .product(name: "Sparkle", package: "sparkle"),
      ],
      resources: [.process("Resources")]
    ),
    .testTarget(name: "AgentMeterCoreTests", dependencies: ["AgentMeterCore"]),
  ]
)
