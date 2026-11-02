import Foundation
import Testing
import SharedDomain

struct CompanionSelectionTests {
    private let base = URL(string: "https://moodle.example.edu")!
    private let week = LocalItem(id: "section-s-1-5", parentID: "course-s-1", siteID: "s", courseID: 1, remoteID: 5,
                                 filename: "Week 3", isDirectory: true)
    private let slides = LocalItem(id: "folder-s-1-9", parentID: "section-s-1-5", siteID: "s", courseID: 1, remoteID: 9,
                                   filename: "Slides", isDirectory: true)

    @Test func aMoodleFileShowsWhereItSitsAndWhetherItIsHere() {
        let file = LocalItem(id: "file-s-1-9-a.pdf", parentID: "folder-s-1-9", siteID: "s", courseID: 1, remoteID: 9,
                             filename: "a.pdf", creationDate: Date(timeIntervalSince1970: 100),
                             modificationDate: Date(timeIntervalSince1970: 200))
        let selection = CompanionSelection.make(item: file, ancestors: [week, slides], downloaded: false, baseURL: base)
        #expect(selection.placeText == "Week 3 › Slides")
        #expect(selection.download == .inCloud)
        #expect(selection.isFromMoodle)
        #expect(selection.moodleURL?.absoluteString.contains("mod/folder") == true, "A file in a folder opens the folder on Moodle")

        var kept = file
        kept.isPinned = true
        let downloaded = CompanionSelection.make(item: kept, ancestors: [week], downloaded: true, baseURL: base)
        #expect(downloaded.download == .downloaded)
        #expect(downloaded.downloadText == "Kept downloaded")
    }

    @Test func personalFilesHaveNoMoodleActions() {
        let notes = LocalItem(id: "local-notes", parentID: "section-s-1-5", siteID: "s", courseID: 1, remoteID: 0,
                              filename: "notes.txt", isLocal: true)
        let selection = CompanionSelection.make(item: notes, ancestors: [week], downloaded: true, baseURL: base)
        #expect(!selection.isFromMoodle)
        #expect(selection.moodleURL == nil)
    }
}
