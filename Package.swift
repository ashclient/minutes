// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Minutes", platforms: [.macOS(.v14)], products: [.executable(name: "Minutes", targets: ["Minutes"]), .executable(name: "MinutesUpdateHelper", targets: ["MinutesUpdateHelper"])], targets: [.target(name: "UpdateSupport"), .executableTarget(name: "Minutes", dependencies: ["UpdateSupport"]), .executableTarget(name: "MinutesUpdateHelper", dependencies: ["UpdateSupport"]), .testTarget(name: "MinutesTests", dependencies: ["Minutes", "UpdateSupport"])])
