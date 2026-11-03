// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SharedDomain

/// The Findle item selected in Finder, with its Moodle context, for the
/// companion to show in place of the course view.
struct CompanionSelection: Equatable {
    enum Download: Equatable { case downloaded, inCloud, folder }

    let itemID: String
    let name: String
    /// The section and activity it sits in, outermost first.
    let place: [String]
    let posted: Date?
    let changed: Date?
    let download: Download
    /// Kept downloaded by the user.
    let isKept: Bool
    /// It comes from Moodle, so it can be opened there and kept downloaded.
    let isFromMoodle: Bool
    let moodleURL: URL?

    var placeText: String { place.joined(separator: " › ") }

    var symbolName: String {
        switch download {
        case .folder: "folder"
        case .downloaded: "checkmark.icloud"
        case .inCloud: "icloud.and.arrow.down"
        }
    }

    var downloadText: String {
        switch download {
        case .folder: isKept ? "Kept downloaded" : "Folder"
        case .downloaded: isKept ? "Kept downloaded" : "Downloaded"
        case .inCloud: "In the cloud — downloads when opened"
        }
    }

    /// `ancestors` are the item's folders from the course down, without the course.
    static func make(item: LocalItem, ancestors: [LocalItem], downloaded: Bool?, baseURL: URL?) -> CompanionSelection {
        let fromMoodle = !item.isLocal && !item.isInFinderCollection
        let link = fromMoodle ? baseURL.map {
            MoodleURLBuilder.webURL(baseURL: $0, itemID: item.id, courseID: item.courseID, remoteID: item.remoteID,
                                    isDirectory: item.isDirectory, parentID: item.parentID)
        } : nil
        return CompanionSelection(
            itemID: item.id, name: item.filename, place: ancestors.map(\.filename),
            posted: item.creationDate, changed: item.modificationDate,
            download: item.isDirectory ? .folder : downloaded == true ? .downloaded : .inCloud,
            isKept: item.isPinned, isFromMoodle: fromMoodle, moodleURL: link)
    }
}
