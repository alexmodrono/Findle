import AppKit
import Combine
import SharedDomain

@MainActor
final class CourseSelectionView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let state: AppState
    private let search = NSSearchField()
    private let table = NSTableView()
    private let empty = NativeUI.label("No courses available.", secondary: true)
    private var courses: [MoodleCourse] = []
    private var subscription: AnyCancellable?
    private static let checkboxTitleOffset: CGFloat = {
        let probe = NSButton(checkboxWithTitle: "A", target: nil, action: nil)
        probe.sizeToFit()
        return probe.cell?.titleRect(forBounds: probe.bounds).minX ?? 20
    }()

    init(state: AppState) {
        self.state = state
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
        scroll.documentView = table
        let stack = NativeUI.stack([search, scroll, empty], spacing: 12)
        NativeUI.pin(stack, in: self)
        search.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        subscription = state.$courses.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        courses = state.courses.filter { query.isEmpty || $0.fullName.localizedCaseInsensitiveContains(query) || $0.shortName.localizedCaseInsensitiveContains(query) }
            .sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
        empty.stringValue = state.courses.isEmpty ? "No courses available. Refresh to check Moodle again." : "No courses match your search."
        empty.isHidden = !courses.isEmpty
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { courses.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let course = courses[row]
        let toggle = ActionButton(course.fullName, checkbox: true) { [weak self] button in
            guard let self else { return }
            let enabled = button.state == .on
            self.state.setCourseSyncEnabled(enabled, for: course)
            if enabled, self.state.currentScreen == .workspace {
                Task { _ = await self.state.syncCourse(course) }
            }
        }
        toggle.state = course.isSyncEnabled ? .on : .off
        toggle.lineBreakMode = .byTruncatingTail
        toggle.toolTip = course.fullName
        toggle.setAccessibilityLabel("Sync \(course.fullName)")
        let code = NativeUI.label(course.shortName, secondary: true, size: 11)
        code.lineBreakMode = .byTruncatingTail
        code.maximumNumberOfLines = 1
        let cell = NSView()
        for view in [toggle, code] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            toggle.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            toggle.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            // Line the course code up with the checkbox title, not the box.
            code.leadingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: Self.checkboxTitleOffset),
            code.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            code.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 2)
        ])
        return cell
    }
}
