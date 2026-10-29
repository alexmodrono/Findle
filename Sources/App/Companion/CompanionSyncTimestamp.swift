import SwiftUI

struct CompanionSyncTimestamp: View {
    let date: Date
    let now: Date
    let compact: Bool
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var relative: String {
        now.timeIntervalSince(date) < 60 ? "Just now" : Self.formatter.localizedString(for: date, relativeTo: now)
    }

    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            Text("Last synced")
            Text(relative)
                .foregroundStyle(.primary)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.14), value: relative)
        }
        .lineLimit(compact ? 2 : 1)
        .help(date.formatted(date: .abbreviated, time: .shortened))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("Last synced \(date.formatted(date: .abbreviated, time: .shortened))")
    }
}
