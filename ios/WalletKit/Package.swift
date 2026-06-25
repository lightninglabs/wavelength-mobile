// swift-tools-version: 5.9
import PackageDescription

// WalletKit wraps the gomobile-generated Walletdk.xcframework in an idiomatic
// Swift API (async / AsyncThrowingStream / Codable models).
//
// The xcframework is a large native artifact built from darepo-client and is
// not committed here. Before building this package, run `make mobile-ios` in a
// darepo-client checkout and copy the result to Frameworks/Walletdk.xcframework
// (see ios/README.md). The scripts/fetch-xcframework.sh helper does this.
let package = Package(
    name: "WalletKit",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "WalletKit", targets: ["WalletKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "Walletdk",
            path: "Frameworks/Walletdk.xcframework"
        ),
        .target(
            name: "WalletKit",
            dependencies: ["Walletdk"]
        ),
    ]
)
