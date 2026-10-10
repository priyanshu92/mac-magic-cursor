// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MagicCursor",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "MagicCursor", targets: ["MagicCursor"])],
  targets: [
    .target(name: "MagicCursorCore"),
    .executableTarget(name: "MagicCursor", dependencies: ["MagicCursorCore"]),
    .executableTarget(
      name: "MagicCursorChecks", dependencies: ["MagicCursorCore"], path: "Tests/MagicCursorChecks"),
  ]
)
