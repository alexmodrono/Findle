import Foundation

/// A Finder tag with a name and color, matching macOS tag semantics.
public struct FinderTag: Sendable, Codable, Equatable, Hashable {
    public let name: String
    public let color: Color

    public init(name: String, color: Color) {
        self.name = name
        self.color = color
    }

    /// Finder tag color indices matching macOS label number values.
    /// Verified via NSURL.labelNumber: 1=Gray, 2=Green, 3=Purple, 4=Blue,
    /// 5=Yellow, 6=Red, 7=Orange.
    public enum Color: Int, Sendable, Codable, CaseIterable {
        case none = 0
        case gray = 1
        case green = 2
        case purple = 3
        case blue = 4
        case yellow = 5
        case red = 6
        case orange = 7

        public var displayName: String {
            switch self {
            case .none: "None"
            case .gray: "Gray"
            case .green: "Green"
            case .purple: "Purple"
            case .blue: "Blue"
            case .yellow: "Yellow"
            case .red: "Red"
            case .orange: "Orange"
            }
        }
    }

    /// Serialized tag string in macOS format: "name\ncolorIndex"
    public var serialized: String {
        "\(name)\n\(color.rawValue)"
    }

    /// Serialize an array of tags into NSKeyedArchiver data suitable for
    /// NSFileProviderItem.tagData.
    public static func tagData(from tags: [FinderTag]) -> Data? {
        guard !tags.isEmpty else { return nil }
        let strings = tags.map(\.serialized) as NSArray
        return try? NSKeyedArchiver.archivedData(withRootObject: strings, requiringSecureCoding: true)
    }
}
