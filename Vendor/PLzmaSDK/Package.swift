// swift-tools-version: 6.1
import PackageDescription

// PLzmaSDK 1.6.1 with the bundled LZMA SDK updated to 26.06; see UPSTREAM.md.
let package = Package(
    name: "PLzmaSDK",
    products: [.library(name: "PLzmaSDK", targets: ["PLzmaSDK"])],
    targets: [
        .target(name: "libplzma", path: "src",
                cSettings: [.define("LIBPLZMA_VERSION_BUILD", to: "1448"), .define("LIBPLZMA_NO_TAR", to: "1"), .unsafeFlags(["-fPIC"])],
                cxxSettings: [.define("LIBPLZMA_VERSION_BUILD", to: "1448"), .define("LIBPLZMA_NO_TAR", to: "1"), .unsafeFlags(["-fPIC", "-fno-rtti"])]),
        .target(name: "PLzmaSDK", dependencies: ["libplzma"], path: "swift",
                resources: [.copy("Resources/PrivacyInfo.xcprivacy"), .copy("Resources/PLzmaSDK-LICENSE.txt"), .copy("Resources/LZMA-SDK-NOTICE.txt"), .copy("Resources/Unicode-ConvertUTF-NOTICE.txt")])
    ],
    swiftLanguageModes: [.v5, .v6],
    cLanguageStandard: .c11,
    cxxLanguageStandard: .cxx11
)
