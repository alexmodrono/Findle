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
