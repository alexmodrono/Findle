# Foodle Architecture

## Overview

Foodle is a native macOS application that syncs Moodle / Open LMS course content to the Mac using Apple's File Provider framework. It presents course files as a cloud storage domain in Finder, similar to Dropbox or iCloud Drive.

## Architectural Decisions

### File Provider as canonical storage surface

The app uses `NSFileProviderReplicatedExtension` (File Provider) as the primary Finder integration model. Course content appears as a provider domain in Finder's sidebar. Files are dataless (placeholders) by default and materialized on demand.

This is the same architecture used by Dropbox, OneDrive, and iCloud Drive on modern macOS.

A secondary "offline mirror" feature may be added later, but the File Provider domain remains the architectural center.

### Native Moodle connector

The app communicates with Moodle/Open LMS instances through their official web services API using token-based authentication. No dependency on moodle-dl, Python, or external CLI tools.

The connector layer uses a provider abstraction so additional LMS backends can be added in the future.

### No scraping

The app does not rely on HTML scraping. If a Moodle instance lacks required web services, the app surfaces this as a clear compatibility limitation.

## Module Structure

```
Foodle.app
├── SharedDomain          (models, identifiers, errors, state machines)
├── FoodleNetworking      (Moodle API client, auth, pagination)
├── FoodlePersistence     (SQLite database, metadata cache, sync cursors)
├── FoodleSyncEngine      (sync planning, diffing, materialization)
├── FoodleFileProvider    (File Provider extension - embedded)
└── FoodleApp             (UI: onboarding, settings, diagnostics)
```

### SharedDomain

Core types shared across all modules:
- `MoodleSite` - server identity and capabilities
- `MoodleUser` - authenticated user info
- `MoodleCourse` - course metadata
- `MoodleResource` - file/content resource
- `SyncState` - per-item sync state machine
- `AccountState` - account lifecycle state
- Error types and identifiers

### FoodleNetworking

Moodle web services client:
- Token-based authentication (`login/token.php`)
- Course enumeration (`core_enrol_get_users_courses`)
- Content enumeration (`core_course_get_contents`)
- File download with token auth
- Site info and capability detection
- Retry/backoff and pagination
- Provider abstraction protocol for future LMS backends

### FoodlePersistence

SQLite-backed local storage:
- Account/site records
- Course metadata cache
- Resource metadata and sync state
- Sync cursors (per-course change tokens)
- Content index for search
- Pinning state

Uses raw SQLite3 C API with a thin Swift wrapper. No external ORM dependency.

### FoodleSyncEngine

Orchestrates sync between remote Moodle and local state:
- Metadata-first enumeration
- Incremental diff against local cache
- Per-course sync scheduling
- Download queue with priority and cancellation
- Offline pinning management
- Conflict detection
- State invalidation
- Change notification to File Provider

### FoodleFileProvider

`NSFileProviderReplicatedExtension` implementation:
- Working set and item enumeration
- Placeholder/dataless file creation
- On-demand download (materialization)
- Item metadata (size, dates, content type)
- Sidebar domain registration
- Eviction support for downloaded content

### App UI

SwiftUI-based macOS app:
- Onboarding wizard (server URL, validation, sign-in)
- Account management
- Course browser with sync scope selection
- Sync activity view
- Settings (sync frequency, storage, notifications)
- Diagnostics (logs, rebuild index, reset provider)

## Data Flow

```
Moodle Server
    │
    ▼
FoodleNetworking (API calls)
    │
    ▼
FoodleSyncEngine (diff, schedule, orchestrate)
    │
    ├──▶ FoodlePersistence (update local DB)
    │
    └──▶ FoodleFileProvider (signal changes)
              │
              ▼
         Finder (user sees files)
```

## Security Model

- Credentials stored exclusively in Keychain
- Token-based auth preferred over password storage
- Course content treated as sensitive
- Sync scope is user-controllable
- No telemetry unless explicitly opted in
- Diagnostics export is privacy-safe (no tokens/passwords)
- Hardened runtime and sandbox-ready design

## State Model

### Account State
```
disconnected → validating → authenticated → expired → re-authenticating
                    │                                       │
                    └──── incompatible                     └──▶ authenticated
```

### Item Sync State
```
placeholder → downloading → materialized → evicting → placeholder
     │              │              │
     └──── error ◀──┘              └──▶ stale → re-downloading
```

### Per-Course State
```
discovered → subscribed → syncing → synced → stale → syncing
                │
                └──▶ unsubscribed
```

## Open Technical Decisions

1. **Change detection strategy**: Moodle's `timemodified` fields are the primary change signal. If Moodle adds proper change tokens in the future, the cursor model can adapt.

2. **File Provider domain lifecycle**: Single domain for all courses vs. per-course domains. Starting with a single domain containing course-level folders.

3. **Background refresh**: Using `BGAppRefreshTask` or a login item helper via `SMAppService`. Decision depends on how aggressive refresh needs to be.

4. **Conflict handling**: Moodle content is typically read-only from the student perspective. Conflicts are unlikely but the model handles them explicitly (server wins by default).

5. **URL/link resources**: Represented as `.webloc` files for native macOS URL handling.

## Future Roadmap

- Offline mirror to user-chosen folder
- Multi-account support
- Moodle assignment submission (upload flow)
- Moodle forum/discussion content
- Spotlight integration via CSSearchableIndex
- Notification support for new content
- Additional LMS backend adapters
