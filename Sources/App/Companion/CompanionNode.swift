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
    /// Added since the user last looked (FI-04), or holds something that was.
    let isNew: Bool
    /// Tells apart rows for the same item in different groups, such as a file
    /// listed both in Added Recently and in its section.
    let scope: String?
    private let symbol: String?

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
        if let symbol { return symbol }
        if !children.isEmpty { return "folder" }
        switch destination {
        case .web: return "globe"
        case .course: return "books.vertical"
        case .item: return (name as NSString).pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc"
        case .none: return "folder"
        }
    }

    var persistentID: String {
        let base: String
        switch destination {
        case .item(let id): base = "item:\(id)"
        case .web(let url): base = "web:\(url.absoluteString)"
        case .course(let id): base = "course:\(id)"
        case .none: base = "label:\(name)"
        }
        return scope.map { "\($0)/\(base)" } ?? base
    }

    init(_ name: String, destination: Destination = .none, children: [CompanionNode] = [],
         isNew: Bool = false, scope: String? = nil, symbol: String? = nil) {
        self.name = name
        self.destination = destination
        self.children = children
        self.isNew = isNew
        self.scope = scope
        self.symbol = symbol
    }
}
