import AppKit
import Combine
import SharedDomain

/// Per-course extras for a course list: the row context menu and tag dots.
/// Settings provides one; onboarding lists courses without it.
@MainActor
protocol CourseListCustomizing: AnyObject {
    /// Set by the list; call it when rows need to be redrawn.
    var onChange: (() -> Void)? { get set }
    func tags(for course: MoodleCourse) -> [FinderTag]
    func menuItems(for course: MoodleCourse, in window: @escaping @MainActor () -> NSWindow?) -> [NSMenuItem]
}

@MainActor
final class CourseSelectionView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private let state: AppState
    /// Renaming and tagging from the row context menu; `nil` when the host
    /// (onboarding) only lets the user pick courses.
    private let customization: CourseListCustomizing?
    private let search = NSSearchField()
    private let table = NSTableView()
    private let empty = NativeUI.label("No courses available.", secondary: true)
    private var courses: [MoodleCourse] = []
    private var subscriptions: Set<AnyCancellable> = []
    private static let checkboxTitleOffset: CGFloat = {
        let probe = NSButton(checkboxWithTitle: "A", target: nil, action: nil)
        probe.sizeToFit()
        return probe.cell?.titleRect(forBounds: probe.bounds).minX ?? 20
    }()

    init(state: AppState, customization: CourseListCustomizing? = nil) {
        self.state = state
        self.customization = customization
        super.init(frame: .zero)
        search.placeholderString = "Find a course"
        search.setAccessibilityLabel("Find a course")
        search.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("course")))
        table.headerView = nil
        table.rowHeight = 48
        table.dataSource = self
        table.delegate = self
        table.style = .fullWidth
        table.setAccessibilityLabel("Courses to sync")
        if let customization {
            let menu = NSMenu(title: "Course")
            menu.delegate = self
            table.menu = menu
            customization.onChange = { [weak self] in self?.reload() }
        }
        scroll.documentView = table
        let stack = NativeUI.stack([search, scroll, empty], spacing: 12)
        NativeUI.pin(stack, in: self)
        search.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        state.$courses.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }.store(in: &subscriptions)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        courses = state.courses.filter { query.isEmpty || matches($0, query: query) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        empty.stringValue = state.courses.isEmpty ? "No courses available. Refresh to check Moodle again." : "No courses match your search."
        empty.isHidden = !courses.isEmpty
        table.reloadData()
    }

    private func tags(for course: MoodleCourse) -> [FinderTag] {
        customization?.tags(for: course) ?? []
    }

    /// Whether the filter `query` matches the course's custom or Moodle name,
    /// short name, or any of its tags.
    private func matches(_ course: MoodleCourse, query: String) -> Bool {
        course.displayName.localizedCaseInsensitiveContains(query)
            || course.fullName.localizedCaseInsensitiveContains(query)
            || course.shortName.localizedCaseInsensitiveContains(query)
            || tags(for: course).contains { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    // MARK: - Context menu

    /// Rebuild the context menu for the row that was clicked; empty when the
    /// click wasn't on a row or the list has no customization.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard let customization, courses.indices.contains(row) else { return }
        for item in customization.menuItems(for: courses[row], in: { [weak self] in self?.window }) {
            menu.addItem(item)
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { courses.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let course = courses[row]
        let toggle = ActionButton(course.displayName, checkbox: true) { [weak self] button in
            guard let self else { return }
            let enabled = button.state == .on
            self.state.setCourseSyncEnabled(enabled, for: course)
            if enabled, self.state.currentScreen == .workspace {
                Task { _ = await self.state.syncCourse(course) }
            }
        }
        toggle.state = course.isSyncEnabled ? .on : .off
        toggle.lineBreakMode = .byTruncatingTail
        toggle.toolTip = course.displayName
        toggle.setAccessibilityLabel("Sync \(course.displayName)")
        // Once renamed, the Moodle name is the useful secondary line.
        let subtitle = course.hasCustomName ? "\(course.shortName) · \(course.fullName)" : course.shortName
        let code = NativeUI.label(subtitle, secondary: true, size: 11)
        code.toolTip = subtitle
        code.lineBreakMode = .byTruncatingTail
        code.maximumNumberOfLines = 1
        let tagView = tagDots(for: tags(for: course))
        let cell = NSView()
        for view in [toggle, code, tagView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            toggle.trailingAnchor.constraint(lessThanOrEqualTo: tagView.leadingAnchor, constant: -8),
            toggle.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            // Line the course code up with the checkbox title, not the box.
            code.leadingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: Self.checkboxTitleOffset),
            code.trailingAnchor.constraint(lessThanOrEqualTo: tagView.leadingAnchor, constant: -8),
            code.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 2),
            tagView.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            tagView.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    /// The course's tags as a row of colored dots, named in the tooltip.
    private func tagDots(for tags: [FinderTag]) -> NSView {
        let dots = tags.map { tag -> NSView in
            let dot = NSImageView(image: tag.color.menuSwatch)
            dot.setContentHuggingPriority(.required, for: .horizontal)
            return dot
        }
        let stack = NativeUI.stack(dots, spacing: 2, horizontal: true)
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        if !tags.isEmpty {
            let names = tags.map(\.name).joined(separator: ", ")
            stack.toolTip = names
            stack.setAccessibilityElement(true)
            stack.setAccessibilityLabel("Tags: \(names)")
        }
        return stack
    }
}
