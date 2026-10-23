// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PipFiles",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FilesCore", targets: ["FilesCore"]),
        .executable(name: "PipFiles", targets: ["PipFiles"])
    ],
    targets: [
        .target(name: "FilesCore"),
        .executableTarget(name: "PipFiles", dependencies: ["FilesCore"]),
        .testTarget(name: "FilesCoreTests", dependencies: ["FilesCore"]),
        .testTarget(name: "PipFilesAppTests", dependencies: ["PipFiles", "FilesCore"])
    ]
)
