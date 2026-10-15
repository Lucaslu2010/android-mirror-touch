// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AndroidMirrorTouch",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "aoa-touch", targets: ["AOATouchCLI"]),
        .executable(name: "AndroidMirror", targets: ["AndroidMirror"])
    ],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [
                .brew(["libusb"])
            ]
        ),
        .target(
            name: "AOATouch",
            dependencies: ["CLibUSB"],
            path: "Sources/AOATouch"
        ),
        .executableTarget(
            name: "AOATouchCLI",
            dependencies: ["AOATouch"],
            path: "Sources/AOATouchCLI"
        ),
        .executableTarget(
            name: "AndroidMirror",
            dependencies: ["AOATouch"],
            path: "Sources/AndroidMirror"
        )
    ]
)
