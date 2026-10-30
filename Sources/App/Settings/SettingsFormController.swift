import AppKit

/// A classic macOS settings form: trailing-aligned labels beside a column of controls,
/// with separators between groups.
@MainActor
class SettingsFormController: NSViewController {
    static let controlWidth: CGFloat = 360
    let grid = NSGridView(numberOfColumns: 2, rows: 0)

    override func loadView() {
        view = NativeSurface()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        NativeUI.pin(scroll, in: view)
        let document = FlippedView()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 1).width = Self.controlWidth
        document.addSubview(grid)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            grid.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 24),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 28),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -28)
        ])
        buildForm()
    }

    func buildForm() {}

    /// Adds a row. A nil title continues the group above it.
    @discardableResult
    func addRow(_ title: String?, _ control: NSView) -> NSGridRow {
        let label = title.map { NSTextField(labelWithString: "\($0):") } ?? NSGridCell.emptyContentView
        return grid.addRow(with: [label, control])
    }

    /// Adds secondary text below a control, close to the control it explains.
    @discardableResult
    func addNote(_ field: NSTextField) -> NSGridRow {
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = Self.controlWidth
        field.widthAnchor.constraint(lessThanOrEqualToConstant: Self.controlWidth).isActive = true
        let row = addRow(nil, field)
        row.topPadding = -4
        return row
    }

    func addSeparator() {
        let line = NSBox()
        line.boxType = .separator
        let row = grid.addRow(with: [line])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.cell(at: 0).xPlacement = .fill
        row.yPlacement = .center
        row.rowAlignment = .none
        row.topPadding = 8
        row.bottomPadding = 8
    }

    func buttons(_ views: [NSView]) -> NSStackView {
        NativeUI.stack(views, spacing: 8, horizontal: true)
    }
}
