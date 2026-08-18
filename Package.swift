// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AISubscriptionStatus",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "AISubscriptionStatus", targets: ["AISubscriptionStatus"]),
    ],
    targets: [
        .executableTarget(
            name: "AISubscriptionStatus",
            path: "Sources/AISubscriptionStatus"
        ),
    ]
)
