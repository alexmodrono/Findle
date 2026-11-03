// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import AppKit
import Combine
import SharedDomain

/// Renaming and tagging for a course: the "Rename…" and "Tags" menu items and
/// the sheets behind them. Shared by any view that lists courses.
@MainActor
final class CourseCustomizationController: NSObject, NSTextFieldDelegate, CourseListCustomizing {
    private let state: AppState
    private var tagSubscription: AnyCancellable?

    /// Called after a rename or tag change (here or in Finder) so the host
    /// can refresh its rows.
    var onChange: (() -> Void)?

    // The rename sheet currently on screen, for live validation.
    private var renameCourse: MoodleCourse?
    private weak var renameAlert: NSAlert?
    private weak var renameField: NSTextField?
    private weak var renameHint: NSTextField?

    // The new-tag sheet currently on screen.
    private weak var tagField: NSTextField?
    private weak var tagColorPopup: NSPopUpButton?
    private weak var tagAlert: NSAlert?
    private var tagCourse: MoodleCourse?

    init(state: AppState) {
        self.state = state
        super.init()
        tagSubscription = state.$courseTags.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.onChange?() }
        }
    }

    func tags(for course: MoodleCourse) -> [FinderTag] {
        state.tags(for: course)
    }

    // MARK: - Menu

    /// "Rename…" and a "Tags" submenu for `course`.
    func menuItems(for course: MoodleCourse, in window: @escaping @MainActor () -> NSWindow?) -> [NSMenuItem] {
        let rename = ClosureMenuItem(title: "Rename…") { [weak self] in
            self?.presentRename(for: course, in: window())
        }

        let tagsItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        let tagsMenu = NSMenu(title: "Tags")
        let knownTags = state.knownTags
        for tag in knownTags {
            let item = ClosureMenuItem(title: tag.name) { [weak self] in
                self?.state.toggleTag(tag, on: course)
                self?.onChange?()
            }
            item.image = tag.color.menuSwatch
            item.state = state.hasTag(tag, on: course) ? .on : .off
            tagsMenu.addItem(item)
        }
        if !knownTags.isEmpty {
            tagsMenu.addItem(.separator())
        }
        tagsMenu.addItem(ClosureMenuItem(title: "New Tag…") { [weak self] in
            self?.presentNewTag(for: course, in: window())
        })
        if !state.tags(for: course).isEmpty {
            tagsMenu.addItem(ClosureMenuItem(title: "Remove All Tags") { [weak self] in
                self?.state.updateCourseTags(for: course, tags: [])
                self?.onChange?()
            })
        }
        tagsItem.submenu = tagsMenu

        return [rename, tagsItem]
    }

    // MARK: - Rename

    /// Show the rename sheet for `course` on `window`. "Rename" saves the
    /// typed name (blank restores the Moodle name), "Use Moodle Name" clears
    /// a custom name, and a colliding name keeps "Rename" disabled.
    func presentRename(for course: MoodleCourse, in window: NSWindow?) {
        guard let window else { return }

        let alert = NSAlert()
        alert.messageText = "Rename “\(course.displayName)”"
        alert.informativeText = "Moodle name: \(course.fullName)"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        if course.hasCustomName {
            alert.addButton(withTitle: "Use Moodle Name")
        }

        let field = NSTextField(string: course.displayName)
        field.placeholderString = course.fullName
        field.delegate = self
        field.setAccessibilityLabel("Course name")
        let hint = NativeUI.label(Self.renameHint, secondary: true, size: 11)
        hint.preferredMaxLayoutWidth = 300
        let accessory = NativeUI.stack([field, hint], spacing: 6)
        accessory.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        hint.widthAnchor.constraint(equalToConstant: 300).isActive = true
        alert.accessoryView = accessory
        alert.layout()

        renameCourse = course
        renameAlert = alert
        renameField = field
        renameHint = hint
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer { self.renameCourse = nil }
            switch response {
            case .alertFirstButtonReturn:
                guard self.state.folderNameConflict(for: course, proposedName: field.stringValue) == nil else { return }
                self.state.updateCustomFolderName(for: course, name: field.stringValue)
            case .alertThirdButtonReturn:
                self.state.updateCustomFolderName(for: course, name: nil)
            default:
                return
            }
            self.onChange?()
        }
    }

    private static let renameHint = "The course folder in Finder is renamed too. Leave the name empty to use the Moodle name."

    /// Enable "Rename" only when the typed name doesn't collide with another
    /// course's folder, and swap the hint for a warning naming that course.
    private func validateRename() {
        guard let course = renameCourse, let field = renameField else { return }
        let conflict = state.folderNameConflict(for: course, proposedName: field.stringValue)
        renameAlert?.buttons.first?.isEnabled = conflict == nil
        if let conflict {
            renameHint?.stringValue = "“\(conflict.displayName)” already uses this folder name."
            renameHint?.textColor = .systemOrange
        } else {
            renameHint?.stringValue = Self.renameHint
            renameHint?.textColor = .secondaryLabelColor
        }
    }

    // MARK: - New tag

    /// Show the new-tag sheet for `course` on `window`: a name field and a
    /// color pop-up. The tag is added through `AppState.addTag`, which reuses
    /// an existing tag of the same name.
    func presentNewTag(for course: MoodleCourse, in window: NSWindow?) {
        guard let window else { return }

        let alert = NSAlert()
        alert.messageText = "Add a Tag to “\(course.displayName)”"
        alert.informativeText = "Typing the name of a tag you already use adds that tag, with its color."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: "")
        field.placeholderString = "Tag name"
        field.delegate = self
        field.setAccessibilityLabel("Tag name")

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for color in FinderTag.Color.allCases where color != .none {
            popup.addItem(withTitle: color.displayName)
            popup.lastItem?.image = color.menuSwatch
            popup.lastItem?.tag = color.rawValue
        }
        popup.selectItem(withTag: FinderTag.Color.blue.rawValue)
        popup.setAccessibilityLabel("Tag color")

        let row = NativeUI.stack([field, popup], spacing: 8, horizontal: true)
        row.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        alert.accessoryView = row
        alert.buttons.first?.isEnabled = false
        alert.layout()

        tagCourse = course
        tagAlert = alert
        tagField = field
        tagColorPopup = popup
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer { self.tagCourse = nil }
            guard response == .alertFirstButtonReturn else { return }
            let color = FinderTag.Color(rawValue: popup.selectedTag()) ?? .blue
            self.state.addTag(FinderTag(name: field.stringValue, color: color), to: course)
            self.onChange?()
        }
    }

    /// Lock the color to an existing tag's when its name is typed, and enable
    /// "Add" only for a non-empty name the course doesn't already have.
    private func validateNewTag() {
        guard let course = tagCourse, let field = tagField else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = FinderTag.existing(named: name, in: state.knownTags)
        // An existing tag keeps its color, so show it and lock the picker.
        if let existing {
            tagColorPopup?.selectItem(withTag: existing.color.rawValue)
        }
        tagColorPopup?.isEnabled = existing == nil
        let alreadyApplied = existing.map { state.hasTag($0, on: course) } ?? false
        tagAlert?.buttons.first?.isEnabled = !name.isEmpty && !alreadyApplied
    }

    // MARK: - NSTextFieldDelegate

    /// Re-validate whichever sheet's text field changed.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === renameField {
            validateRename()
        } else if field === tagField {
            validateNewTag()
        }
    }
}

/// A menu item that runs a closure, so menus can be built without selectors.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func invoke() { handler() }
}
