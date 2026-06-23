// swift-tools-version:5.9
import PackageDescription

let jsonCInclude = "/opt/homebrew/opt/json-c/include/json-c"

let package = Package(
    name: "VRDesktop",
    platforms: [.macOS(.v14)],
    targets: [
        // Vendored C: xrealair-sdk-macos (MIT) + xioTechnologies/Fusion (MIT) + hidapi mac backend (BSD)
        .target(
            name: "CXrealDriver",
            path: "Sources/CXrealDriver",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("include/Fusion"),
                .headerSearchPath("include/hidapi"),
                .unsafeFlags(["-I\(jsonCInclude)"]),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AppKit"),
                .unsafeFlags(["-L", "vendor/lib", "-ljson-c"]),
            ]
        ),
        .target(name: "GlassesDriver", dependencies: ["CXrealDriver"]),
        .target(name: "CapturePipeline"),
        .target(
            name: "CPrivateDisplay",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .target(name: "DisplayManager", dependencies: ["CPrivateDisplay"]),
        .target(name: "Compositor", dependencies: ["GlassesDriver", "CapturePipeline"]),
        // Re-declares NSXPCConnection.auditToken (header-only) so the helper can identify clients.
        .target(name: "CXPCAuditToken"),
        // XPC protocol + constants shared by the app and the privileged helper daemon.
        .target(name: "PrivilegedHelperShared"),
        // The privileged LaunchDaemon (runs as root, installed via SMAppService) that prunes
        // root-owned ColorSync display profiles on behalf of the verified app.
        .executableTarget(
            name: "VRDesktopHelper",
            dependencies: ["PrivilegedHelperShared", "CXPCAuditToken"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "VRDesktop",
            dependencies: ["GlassesDriver", "CapturePipeline", "Compositor", "DisplayManager",
                           "PrivilegedHelperShared"]
        ),
    ]
)
