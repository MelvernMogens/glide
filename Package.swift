// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Glide",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Glide", targets: ["Glide"])],
    targets: [
        // Pure logic: settings, scroll math, modifier mapping, button state machine. Foundation only.
        .target(name: "GlideKit"),
        // App: event tap, event synthesis, menu-bar UI.
        .executableTarget(
            name: "Glide",
            dependencies: ["GlideKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(name: "GlideKitTests", dependencies: ["GlideKit"]),
    ]
)
