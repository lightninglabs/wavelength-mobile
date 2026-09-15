// swift-tools-version: 5.9
import PackageDescription

// WalletKit wraps the gomobile-generated Wavewalletdk.xcframework in an idiomatic
// Swift API (async / AsyncThrowingStream / Codable models).
//
// The xcframework is a large native artifact built from wavelength and is
// not committed here. Before building this package, run `make mobile-ios` in a
// wavelength checkout and copy the result to Frameworks/Wavewalletdk.xcframework
// (see ios/README.md). The scripts/fetch-xcframework.sh helper does this.
let package = Package(
    name: "WalletKit",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "WalletKit", targets: ["WalletKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "Wavewalletdk",
            path: "Frameworks/Wavewalletdk.xcframework"
        ),
        .target(
            name: "WalletKit",
            dependencies: ["Wavewalletdk"],
            linkerSettings: [
                // The embedded Go resolver references res_9_* symbols. Keep
                // this on the package so tests and downstream hosts link it
                // without duplicating an app-target setting.
                .linkedLibrary("resolv"),
            ]
        ),
    ]
)
