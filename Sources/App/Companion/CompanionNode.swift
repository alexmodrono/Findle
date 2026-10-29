import Foundation

final class CompanionNode: NSObject {
    enum Destination {
        case item(String)
        case web(URL)
        case course(Int)
        case none
    }

    let name: String
    let destination: Destination
    let children: [CompanionNode]

    var canOpen: Bool {
        if case .none = destination { return false }
        return true
    }

    var openTitle: String {
        switch destination {
        case .web: "Open in Moodle"
        case .item, .course: "Open in Finder"
        case .none: "Expand"
        }
    }

    var symbolName: String {
        if !children.isEmpty { return "folder" }
        switch destination {
        case .web: return "globe"
        case .course: return "books.vertical"
        case .item: return (name as NSString).pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc"
        case .none: return "folder"
        }
    }

    var persistentID: String {
        switch destination {
        case .item(let id): return "item:\(id)"
        case .web(let url): return "web:\(url.absoluteString)"
        case .course(let id): return "course:\(id)"
        case .none: return "label:\(name)"
        }
    }

    init(_ name: String, destination: Destination = .none, children: [CompanionNode] = []) {
        self.name = name
        self.destination = destination
        self.children = children
    }
}
