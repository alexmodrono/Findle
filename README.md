# Foodle

A native macOS app that syncs Moodle / Open LMS course content to your Mac using Apple's File Provider framework. Course files appear directly in Finder, just like iCloud Drive or Dropbox.

## Features

- Native macOS app built with Swift and SwiftUI
- File Provider integration for Finder sidebar presence and on-demand downloads
- Secure authentication via Moodle web services API
- Automatic course discovery and content enumeration
- Metadata-first sync with placeholder files
- On-demand content materialization (files download when opened)
- SQLite-backed local persistence
- Keychain-secured credentials
- Incremental sync with per-course change tracking

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 16.0 or later
- Swift 6.0
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for project generation)

## Setup

1. Install XcodeGen if needed:
   ```sh
   brew install xcodegen
   ```

2. Generate the Xcode project:
   ```sh
   xcodegen generate
   ```

3. Open the generated project:
   ```sh
   open Foodle.xcodeproj
   ```

4. Select the `Foodle` scheme, then build and run.

Note: The File Provider extension requires code signing with a valid development team. Set your team in the project settings.

## Architecture

See [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) for a detailed architecture overview.

### Module Structure

| Module | Purpose |
|--------|---------|
| `SharedDomain` | Core types, models, state machines, errors |
| `FoodleNetworking` | Moodle API client, authentication, Keychain |
| `FoodlePersistence` | SQLite database, metadata cache, sync cursors |
| `FoodleSyncEngine` | Sync orchestration, diffing, download management |
| `FoodleFileProvider` | File Provider extension for Finder integration |
| `Foodle` (App) | SwiftUI app: onboarding, settings, diagnostics |

### Data Flow

```
Moodle Server -> Networking -> SyncEngine -> Persistence -> FileProvider -> Finder
```

## Testing

Run tests in Xcode using `Cmd+U`, or:

```sh
xcodebuild test -project Foodle.xcodeproj -scheme SharedDomainTests
xcodebuild test -project Foodle.xcodeproj -scheme PersistenceTests
```

Test fixtures are located in the `Fixtures/` directory.

## Project Structure

```
Foodle/
├── Sources/
│   ├── App/                    Main macOS application
│   ├── SharedDomain/           Shared models and types
│   ├── Networking/             Moodle API client
│   ├── Persistence/            SQLite database
│   ├── SyncEngine/             Sync orchestration
│   └── FileProviderExtension/  File Provider extension
├── Tests/                      Unit and integration tests
├── Fixtures/                   Mock API response data
├── Resources/                  Plists, entitlements, assets
├── Docs/                       Architecture documentation
└── project.yml                 XcodeGen project definition
```

## Roadmap

- [ ] End-to-end vertical slice (authenticate -> enumerate -> Finder placeholders)
- [ ] Background sync refresh
- [ ] Offline pinning support
- [ ] Multi-account support
- [ ] Optional offline mirror to user-chosen folder
- [ ] Spotlight integration
- [ ] Assignment submission support
- [ ] Additional LMS backend adapters
