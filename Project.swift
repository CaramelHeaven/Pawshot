import ProjectDescription

private let bundleId = "com.caramelheaven.pawshot"

/// Signing lives in `Config/Signing.xcconfig`: ad hoc out of the box, a personal certificate
/// through the git-ignored `Config/Signing.local.xcconfig`. See the comment in the former.
private let signing: Path = "Config/Signing.xcconfig"
/// Tuist's defaults write `CODE_SIGN_IDENTITY = -` into every target, and a target's own setting
/// beats its xcconfig — the certificate from the local file would never be used.
private let defaultSettings = DefaultSettings.recommended(excluding: ["CODE_SIGN_IDENTITY"])

/// Formatting before compilation. The binary comes from the pin in `mise.toml`, and if mise
/// hasn't installed it yet — from PATH, so the build doesn't fail on somebody else's machine.
/// `basedOnDependencyAnalysis: false`: the phase has no output files, otherwise Xcode skips it.
private let formatScript = TargetScript.pre(
    script: """
    export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
    cd "$SRCROOT" || exit 0

    if BIN="$(mise which swiftformat 2>/dev/null)" && [ -x "$BIN" ]; then
        :
    elif BIN="$(command -v swiftformat)"; then
        echo "warning: swiftformat taken from $BIN instead of the mise.toml pin"
    else
        echo "warning: swiftformat not found — run mise install"
        exit 0
    fi

    "$BIN" Pawshot/Sources Tests
    """,
    name: "SwiftFormat",
    basedOnDependencyAnalysis: false
)

let project = Project(
    name: "Pawshot",
    // Russian next to English. The tests pin English: the test host is the app itself, so a
    // language picked in its settings would otherwise turn "Space" into "Пробел" under them.
    options: .options(
        automaticSchemesOptions: .enabled(testLanguage: "en"),
        defaultKnownRegions: ["en", "ru"],
        developmentRegion: "en"
    ),
    // Swift 6 is set here rather than through `defaultSwiftVersion` in Tuist.swift: that one
    // doesn't affect the targets' SWIFT_VERSION, which stayed at 5.0 in the project.
    // Strict concurrency is what keeps the AppKit parts and the SwiftUI app honest about the main
    // actor.
    // ENABLE_USER_SCRIPT_SANDBOXING is disabled explicitly: the SwiftFormat phase writes into the
    // sources, and under the script sandbox writing outside the derived directory is forbidden.
    // The two localization settings let a build collect every user-visible string into the
    // catalogs in Pawshot/Resources.
    settings: .settings(base: [
        "SWIFT_VERSION": "6.0",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    ]),
    targets: [
        .target(
            name: "Pawshot",
            destinations: .macOS,
            product: .app,
            bundleId: bundleId,
            deploymentTargets: .macOS("26.0"),
            // .dictionary and not .extendingDefault: the Tuist default slips in
            // NSMainStoryboardFile = Main, and the app crashes on launch because there is no
            // storyboard here and never will be — the UI is built in code.
            infoPlist: .dictionary([
                "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)",
                "CFBundleExecutable": "$(EXECUTABLE_NAME)",
                "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundlePackageType": "APPL",
                "CFBundleName": "Pawshot",
                "CFBundleDisplayName": "Pawshot",
                // From build settings, so a build can set them on the command line (`MARKETING_VERSION=…`).
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "LSMinimumSystemVersion": "26.0",
                "LSApplicationCategoryType": "public.app-category.utilities",
                // A background utility: no Dock icon, no ⌘Tab entry, only the menu bar.
                "LSUIElement": true,
                "NSPrincipalClass": "NSApplication",
                // Without it the first recording with the microphone on doesn't ask — it crashes.
                "NSMicrophoneUsageDescription": "Pawshot records your voice along with the screen when the microphone is turned on.",
                "NSHumanReadableCopyright": "Copyright © CaramelHeaven",
            ]),
            sources: ["Pawshot/Sources/**"],
            resources: ["Pawshot/Resources/**"],
            scripts: [formatScript],
            // Two Icon Composer icons, drawn by `make icon`: the Debug build wears the grey one, so
            // a copy from DerivedData can't pass for the one in /Applications — launch at login
            // remembers the bundle path, and mixing them up starts a stale build.
            settings: .settings(
                base: ["MARKETING_VERSION": "0.1.1", "CURRENT_PROJECT_VERSION": "1"],
                configurations: [
                    .debug(
                        name: .debug,
                        settings: ["ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon-Debug"],
                        xcconfig: signing
                    ),
                    .release(
                        name: .release,
                        settings: ["ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"],
                        xcconfig: signing
                    ),
                ],
                defaultSettings: defaultSettings
            )
        ),
        .target(
            name: "PawshotTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "\(bundleId).tests",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .default,
            sources: ["Tests/PawshotTests/**"],
            dependencies: [.target(name: "Pawshot")],
            settings: .settings(configurations: [
                .debug(name: .debug, xcconfig: signing),
                .release(name: .release, xcconfig: signing),
            ], defaultSettings: defaultSettings)
        ),
    ]
)
