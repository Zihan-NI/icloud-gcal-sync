// swift-tools-version:6.0
import PackageDescription

// No third-party dependencies: SQLite, CryptoKit, EventKit and URLSession all ship with macOS.
let package = Package(
    name: "icloud-gcal-sync",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure sync logic: models, hashing, planner, guards, engine. No I/O of its own.
        .target(name: "SyncCore"),
        // Google Calendar REST client + installed-app OAuth.
        .target(name: "GoogleCalendar", dependencies: ["SyncCore"]),
        // SQLite-backed link table, Google event cache and metadata.
        .target(name: "SyncStorage", dependencies: ["SyncCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        // EventKit adapter. The only target that touches the user's calendars.
        .target(name: "AppleCalendar", dependencies: ["SyncCore"]),
        .executableTarget(
            name: "icloud-gcal-sync",
            dependencies: ["SyncCore", "GoogleCalendar", "SyncStorage", "AppleCalendar"],
            // EventKit only grants calendar access to a binary that carries a usage description.
            // A command-line tool has no bundle, so the Info.plist is embedded in the executable.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", "Support/Info.plist"])]
        ),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore", "SyncStorage"]),
        .testTarget(name: "SyncStorageTests", dependencies: ["SyncStorage", "SyncCore"]),
        .testTarget(name: "GoogleCalendarTests", dependencies: ["GoogleCalendar", "SyncCore"]),
    ],
    swiftLanguageModes: [.v5]
)
