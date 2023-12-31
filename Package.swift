// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "vapor-proxy",
    platforms: [
       .macOS(.v10_15)
    ],
    products: [
        .library(name: "VaporProxy", targets: ["VaporProxy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.77.1"),
        .package(url: "https://github.com/vsevolod-volkov/vapor-forwarded-host.git", from: "0.2.0"),
    ],
    targets: [
        .target(
            name: "VaporProxy",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "VaporForwardedHost", package: "vapor-forwarded-host"),
            ]
        ),
        .testTarget(name: "VaporProxyTests", dependencies: [
            .target(name: "VaporProxy"),
            .product(name: "XCTVapor", package: "vapor"),
        ])
    ]
)
