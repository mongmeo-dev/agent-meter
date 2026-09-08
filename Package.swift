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
  targets: [
    .target(name: "AgentMeterCore"),
    .executableTarget(name: "AgentMeter", dependencies: ["AgentMeterCore"]),
    .testTarget(name: "AgentMeterCoreTests", dependencies: ["AgentMeterCore"]),
  ]
)
