// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "capa",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(name: "capa", targets: ["capa"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.4.0")
  ],
  targets: [
    .executableTarget(
      name: "capa",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ],
      path: "Sources",
      swiftSettings: [
        .unsafeFlags(["-enable-testing"], .when(configuration: .debug)),
        .unsafeFlags(["-Xfrontend", "-lazy-typecheck"], .when(configuration: .debug))
      ]
    ),
    .testTarget(
      name: "CapaTests",
      dependencies: ["capa"],
      path: "Tests/CapaTests"
    )
  ]
)
