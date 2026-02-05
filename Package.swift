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
  targets: [
    .executableTarget(
      name: "capa",
      path: "Sources"
    )
  ]
)
