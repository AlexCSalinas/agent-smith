// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentSmith",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AgentSmith", targets: ["AgentSmith"]),
        .library(name: "SmithCore", targets: ["SmithCore"])
    ],
    targets: [
        .target(name: "Models", path: "Sources/Models"),

        .target(
            name: "Watcher",
            dependencies: ["Models"],
            path: "Sources/Watcher"
        ),
        .target(
            name: "Triage",
            dependencies: ["Models"],
            path: "Sources/Triage"
        ),
        .target(
            name: "Filer",
            dependencies: ["Models"],
            path: "Sources/Filer"
        ),
        .target(
            name: "Ledger",
            dependencies: ["Models"],
            path: "Sources/Ledger"
        ),
        .target(
            name: "Classifier",
            dependencies: ["Models"],
            path: "Sources/Classifier"
        ),
        .target(
            name: "Curator",
            dependencies: ["Models"],
            path: "Sources/Curator"
        ),
        .target(
            name: "SmithCore",
            dependencies: ["Models", "Watcher", "Triage", "Filer", "Ledger", "Classifier", "Curator"],
            path: "Sources/SmithCore"
        ),

        .executableTarget(
            name: "AgentSmith",
            dependencies: ["SmithCore"],
            path: "Sources/AgentSmith"
        ),

        .testTarget(
            name: "ModelsTests",
            dependencies: ["Models"],
            path: "Tests/ModelsTests"
        ),
        .testTarget(
            name: "WatcherTests",
            dependencies: ["Watcher", "Models"],
            path: "Tests/WatcherTests"
        ),
        .testTarget(
            name: "TriageTests",
            dependencies: ["Triage", "Models"],
            path: "Tests/TriageTests"
        ),
        .testTarget(
            name: "FilerTests",
            dependencies: ["Filer", "Models"],
            path: "Tests/FilerTests"
        ),
        .testTarget(
            name: "LedgerTests",
            dependencies: ["Ledger", "Models"],
            path: "Tests/LedgerTests"
        ),
        .testTarget(
            name: "ClassifierTests",
            dependencies: ["Classifier", "Models"],
            path: "Tests/ClassifierTests"
        ),
        .testTarget(
            name: "CuratorTests",
            dependencies: ["Curator", "Models"],
            path: "Tests/CuratorTests"
        ),
        .testTarget(
            name: "SmithCoreTests",
            dependencies: ["SmithCore", "Curator", "Triage", "Models"],
            path: "Tests/SmithCoreTests"
        )
    ]
)
