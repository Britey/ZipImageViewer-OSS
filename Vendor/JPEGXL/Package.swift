// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "JPEGXL",
    platforms: [.iOS(.v18)],
    products: [.library(name: "JPEGXLBridge", targets: ["JPEGXLBridge"])],
    targets: [
        .binaryTarget(name: "JPEGXL", path: "JPEGXL.xcframework"),
        .target(name: "JPEGXLBridge", dependencies: ["JPEGXL"],
                publicHeadersPath: "include", linkerSettings: [.linkedLibrary("c++")])
    ],
    cxxLanguageStandard: .cxx17
)
