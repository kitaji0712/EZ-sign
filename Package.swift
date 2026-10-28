// swift-tools-version:5.9
// アプリから Apple のフレームワークに依存しない部分（Sources/EZSignCore）だけを
// Mac / Linux で `swift test` するためのパッケージ。アプリ本体は EZSign.xcodeproj。
import PackageDescription

let package = Package(
    name: "EZSignCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    targets: [
        .target(name: "EZSignCore"),
        .testTarget(name: "EZSignCoreTests", dependencies: ["EZSignCore"]),
    ]
)
