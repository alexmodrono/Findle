import Testing
import SharedDomain

/// The companion follows the folder Finder shows by its File Provider identity.
@MainActor
struct CompanionLocationTests {
    private let course = MoodleCourse(id: 7, shortName: "ALG", fullName: "Algebra", siteID: "site")
    private let items: [String: LocalItem] = [
        "course-site-7": LocalItem(id: "course-site-7", siteID: "site", courseID: 7, remoteID: 7, filename: "Renamed by me", isDirectory: true),
        "section-site-7-1": LocalItem(id: "section-site-7-1", parentID: "course-site-7", siteID: "site", courseID: 7, remoteID: 1,
                                      filename: "Week 1", isDirectory: true),
        "folder-site-9": LocalItem(id: "folder-site-9", parentID: "section-site-7-1", siteID: "site", courseID: 7, remoteID: 9,
                                   filename: "Slides", isDirectory: true),
        "other-site": LocalItem(id: "other-site", siteID: "other", courseID: 7, remoteID: 1, filename: "x", isDirectory: true),
    ]

    @Test func aFolderFindsItsCourseWhateverItIsCalled() {
        let location = CompanionLocation.resolve(itemID: "folder-site-9", siteID: "site", courses: [course]) { items[$0] }
        #expect(location?.course == course)
        #expect(location?.folderIDs == ["folder-site-9", "section-site-7-1", "course-site-7"])
    }

    @Test func unknownItemsAndOtherSitesHaveNoLocation() {
        #expect(CompanionLocation.resolve(itemID: "missing", siteID: "site", courses: [course]) { items[$0] } == nil)
        #expect(CompanionLocation.resolve(itemID: "other-site", siteID: "site", courses: [course]) { items[$0] } == nil)
        #expect(CompanionLocation.resolve(itemID: "folder-site-9", siteID: "site", courses: []) { items[$0] } == nil,
                "A course the user doesn't sync isn't shown")
    }

    @Test func theOutlineOpensDownToTheFolderFinderShows() {
        let model = CompanionPresentation()
        let slides = CompanionNode("Slides", destination: .item("folder-site-9"), children: [CompanionNode("a.pdf", destination: .item("a"))])
        let week1 = CompanionNode("Week 1", destination: .item("section-site-7-1"), children: [slides])
        let week2 = CompanionNode("Week 2", destination: .item("section-site-7-2"), children: [CompanionNode("b.pdf", destination: .item("b"))])
        model.replaceNodes([week2, week1], contextID: "site/7")
        model.reveal(["item:folder-site-9", "item:section-site-7-1", "item:course-site-7"])
        #expect(model.selectedID == "item:folder-site-9")
        #expect(model.visibleRows.map(\.id).contains("item:a"), "The folder opens to show what Finder shows")

        model.reveal(["item:sub-folder", "item:section-site-7-2"])
        #expect(model.selectedID == "item:section-site-7-2", "A folder the outline lacks reveals the nearest one holding it")
    }

    @Test func aRevealWaitsForTheOutlineToLoad() {
        let model = CompanionPresentation()
        model.reveal(["item:section-site-7-1"])
        model.replaceNodes([CompanionNode("Week 1", destination: .item("section-site-7-1"))], contextID: "site/7")
        #expect(model.selectedID == "item:section-site-7-1")
    }
}
