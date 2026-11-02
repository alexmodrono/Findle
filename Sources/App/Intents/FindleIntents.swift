// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import AppIntents
import Foundation
import SharedDomain

/// Lets the intents reach the app's live state, which the app delegate owns.
@MainActor
enum IntentBridge {
    static var state: AppState?

    /// The signed-in state, or an error Shortcuts and Spotlight show as is.
    static func signedInState() throws -> AppState {
        guard let state, state.currentScreen == .workspace, state.currentSite != nil, !state.sessionExpired else {
            throw IntentFailure.notSignedIn
        }
        return state
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case courseUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: "Sign in to Findle first. Open Findle to connect your Moodle account."
        case .courseUnavailable: "That course isn't synced with Findle."
        }
    }
}

struct SyncFindleIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Findle"
    static let description = IntentDescription("Brings your Moodle courses up to date in Finder.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = try IntentBridge.signedInState()
        await state.syncAll()
        let report = state.lastSyncReport
        if let report, !report.allSucceeded, !report.isNoOp {
            return .result(dialog: "Findle synced \(report.succeededCount) of \(report.courses.count) courses. Open Findle for details.")
        }
        return .result(dialog: "Your courses are up to date.")
    }
}

struct DueThisWeekIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Due This Week"
    static let description = IntentDescription("Lists the assignments and quizzes due in the next seven days.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let state = try IntentBridge.signedInState()
        let lines = state.dueThisWeek().map(\.line)
        guard !lines.isEmpty else { return .result(value: [], dialog: "Nothing is due in the next seven days.") }
        return .result(value: lines, dialog: "\(lines.joined(separator: "\n"))")
    }
}

struct OpenCourseFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Course Folder"
    static let description = IntentDescription("Opens a course's folder in Finder.")

    @Parameter(title: "Course")
    var course: CourseEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let state = try IntentBridge.signedInState()
        guard let match = state.courses.first(where: { $0.id == course.id && $0.isSyncEnabled }) else {
            throw IntentFailure.courseUnavailable
        }
        await state.openFileProviderInFinder(selecting: match)
        return .result()
    }
}

/// A synced course, as Shortcuts and Spotlight offer it.
struct CourseEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Course"
    static let defaultQuery = CourseQuery()

    let id: Int
    let name: String
    let shortName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(shortName)")
    }
}

struct CourseQuery: EntityStringQuery {
    @MainActor
    private func synced() throws -> [CourseEntity] {
        try IntentBridge.signedInState().courses.filter(\.isSyncEnabled)
            .map { CourseEntity(id: $0.id, name: $0.fullName, shortName: $0.shortName) }
    }

    @MainActor
    func entities(for identifiers: [Int]) async throws -> [CourseEntity] {
        try synced().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [CourseEntity] {
        try synced().filter { $0.name.localizedCaseInsensitiveContains(string) || $0.shortName.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [CourseEntity] {
        try synced()
    }
}

struct FindleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncFindleIntent(), phrases: ["Sync \(.applicationName)"],
                    shortTitle: "Sync", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: DueThisWeekIntent(), phrases: ["What's due this week in \(.applicationName)"],
                    shortTitle: "Due This Week", systemImageName: "calendar.badge.clock")
        AppShortcut(intent: OpenCourseFolderIntent(), phrases: ["Open \(\.$course) in \(.applicationName)"],
                    shortTitle: "Open Course Folder", systemImageName: "folder")
    }
}
