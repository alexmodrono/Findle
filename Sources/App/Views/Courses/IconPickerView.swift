// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI

struct IconPickerView: View {
    @Binding var selectedIcon: String?
    let onDismiss: () -> Void

    @State private var searchText = ""

    private var filteredIcons: [String] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return Self.courseIcons }
        return Self.courseIcons.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose Icon")
                    .font(.headline)
                Spacer()
                Button("Reset", action: resetIcon)
                    .buttonStyle(.borderless)
                    .disabled(selectedIcon == nil)
            }
            .padding()

            TextField("Search symbols", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 8) {
                    ForEach(filteredIcons, id: \.self) { icon in
                        iconButton(icon)
                    }
                }
                .padding()
            }

            if filteredIcons.isEmpty {
                ContentUnavailableView.search
                    .frame(height: 120)
            }
        }
        .frame(width: 320, height: 380)
    }

    private func iconButton(_ icon: String) -> some View {
        let isSelected = selectedIcon == icon
        return Button {
            selectedIcon = icon
            onDismiss()
        } label: {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 36, height: 36)
                .background(
                    isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon)
    }

    private func resetIcon() {
        selectedIcon = nil
        onDismiss()
    }

    // MARK: - Icon Catalog

    static let courseIcons: [String] = [
        // Education
        "book.fill", "book.closed.fill", "books.vertical.fill",
        "text.book.closed.fill", "bookmark.fill",
        "graduationcap.fill", "pencil", "pencil.and.ruler.fill",
        "backpack.fill", "studentdesk",
        // Science & Math
        "atom", "function", "sum", "percent",
        "chart.bar.fill", "chart.line.uptrend.xyaxis", "chart.pie.fill",
        "waveform.path.ecg", "waveform",
        // Computing
        "desktopcomputer", "laptopcomputer", "terminal.fill",
        "cpu.fill", "memorychip.fill", "network",
        "antenna.radiowaves.left.and.right", "wifi",
        "chevron.left.forwardslash.chevron.right",
        // Engineering
        "gearshape.fill", "wrench.and.screwdriver.fill", "hammer.fill",
        "bolt.fill", "battery.100.bolt",
        "car.fill", "airplane",
        // Arts & Language
        "paintbrush.fill", "paintpalette.fill", "theatermasks.fill",
        "music.note", "music.note.list", "film.fill",
        "camera.fill", "photo.fill",
        "character.book.closed.fill", "textformat.abc",
        "globe", "globe.americas.fill", "globe.europe.africa.fill",
        // Health & Nature
        "heart.fill", "cross.case.fill", "stethoscope",
        "leaf.fill", "tree.fill",
        "figure.run", "figure.walk",
        // Business & Law
        "briefcase.fill", "banknote.fill", "building.2.fill",
        "building.columns.fill", "chart.line.uptrend.xyaxis.circle.fill",
        "scale.3d",
        // General
        "star.fill", "flag.fill", "pin.fill",
        "lightbulb.fill", "puzzlepiece.fill",
        "trophy.fill", "rosette",
        "folder.fill", "doc.fill", "doc.text.fill",
        "calendar", "clock.fill",
        "map.fill", "location.fill",
        "magnifyingglass", "eye.fill",
        "person.fill", "person.2.fill", "person.3.fill",
    ]
}
