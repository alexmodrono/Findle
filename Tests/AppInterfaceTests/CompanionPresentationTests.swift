import Foundation
import Testing

@MainActor
struct CompanionPresentationTests {
    private func section(_ id: String, children: [CompanionNode]) -> CompanionNode {
        CompanionNode(id, destination: .item(id), children: children)
    }

    @Test func expansionAndSelectionSurviveRefreshAndPanelCollapse() {
        let model = CompanionPresentation()
        let leaf = CompanionNode("Notes.pdf", destination: .item("notes"))
        let group = section("week-1", children: [leaf])
        model.replaceNodes([group], contextID: "site/course")
        model.selectedID = leaf.persistentID
        model.mode = .compact
        let refreshedLeaf = CompanionNode("Renamed.pdf", destination: .item("notes"))
        model.replaceNodes([section("week-1", children: [refreshedLeaf])], contextID: "site/course")
        model.mode = .expanded
        #expect(model.visibleRows.map(\.node.name) == ["week-1", "Renamed.pdf"])
        #expect(model.selectedID == refreshedLeaf.persistentID)
    }

    @Test func aNewFileListedTwiceHasTwoRows() {
        let model = CompanionPresentation()
        let added = CompanionNode("Added Recently", children: [CompanionNode("Lab.pdf", destination: .item("lab"), isNew: true, scope: "recent")],
                                  symbol: "sparkles")
        let week = section("week-1", children: [CompanionNode("Lab.pdf", destination: .item("lab"), isNew: true)])
        model.replaceNodes([added, week], contextID: "site/course")
        model.toggleExpansion(week)
        let ids = model.visibleRows.map(\.id)
        #expect(ids == ["label:Added Recently", "recent/item:lab", "item:week-1", "item:lab"])
        #expect(Set(ids).count == ids.count, "Each row needs its own identity in the list")
        #expect(added.symbolName == "sparkles")
        model.reveal(["item:lab"])
        #expect(model.selectedID == "item:lab", "Following Finder selects the file where it lives")
    }

    @Test func onlyItemRowsCanBeDraggedPreviewedAndKept() {
        let file = CompanionNode("Notes.pdf", destination: .item("file-1"), isKept: true)
        #expect(file.itemID == "file-1")
        #expect(file.isKept)
        #expect(CompanionNode("Quiz", destination: .web(URL(string: "https://moodle.example.edu")!)).itemID == nil)
        #expect(CompanionNode("Added Recently").itemID == nil)
    }

        @Test func changingCoursesClearsStaleNavigation() {
        let model = CompanionPresentation()
        let group = section("week-1", children: [CompanionNode("Notes", destination: .item("notes"))])
        model.replaceNodes([group], contextID: "site/course-1")
        model.selectedID = "item:notes"
        model.replaceNodes([section("week-2", children: [CompanionNode("Lab", destination: .item("lab"))])], contextID: "site/course-2")
        #expect(model.selectedID == nil)
        #expect(!model.expandedIDs.contains(group.persistentID))
        #expect(model.visibleRows.map(\.id) == ["item:week-2", "item:lab"])
    }

    @Test func keyboardNavigationExpandsDescendsAndReturnsToParent() {
        let model = CompanionPresentation()
        let leaf = CompanionNode("Notes", destination: .item("notes"))
        let group = section("week-1", children: [leaf])
        model.replaceNodes([group], contextID: "site/course")
        model.toggleExpansion(group)
        model.selectedID = group.persistentID
        #expect(model.expandSelection())
        #expect(model.selectedID == group.persistentID)
        #expect(model.expandSelection())
        #expect(model.selectedID == leaf.persistentID)
        #expect(model.collapseSelection())
        #expect(model.selectedID == group.persistentID)
        #expect(model.collapseSelection())
        #expect(model.visibleRows.count == 1)
    }

    @Test func collapsingAParentDoesNotLeaveAnInvisibleSelection() {
        let model = CompanionPresentation()
        let leaf = CompanionNode("Notes", destination: .item("notes"))
        let group = section("week-1", children: [leaf])
        model.replaceNodes([group], contextID: "site/course")
        model.selectedID = leaf.persistentID
        model.toggleExpansion(group)
        #expect(model.selectedID == group.persistentID)
        model.replaceNodes([], contextID: "site/course")
        #expect(model.selectedID == nil)
        #expect(model.expandedIDs.isEmpty)
    }
}
