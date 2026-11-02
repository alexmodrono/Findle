// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// `findle://` links other processes open to ask the app to do something.
public enum FindleLinks {
    public static let scheme = "findle"

    /// Show a course in Findle (Show in Findle in Finder).
    public static func showCourse(_ courseID: Int) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "show"
        components.queryItems = [URLQueryItem(name: "course", value: String(courseID))]
        return components.url
    }

    /// Reveal an item in Finder (the widget's entries).
    public static func reveal(itemID: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "reveal"
        components.queryItems = [URLQueryItem(name: "item", value: itemID)]
        return components.url
    }

    /// The item a reveal link names, or nil for any other link.
    public static func revealedItem(in url: URL) -> String? {
        guard url.scheme == scheme, url.host == "reveal" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "item" }?.value
    }

    /// Start a sync in the background (the Control Center control).
    public static let sync = URL(string: "\(scheme)://sync")!

    /// Open Findle's settings (the Finder toolbar button).
    public static let settings = URL(string: "\(scheme)://settings")!

    /// Open a course's folder in Finder (the Finder toolbar button).
    public static func openCourse(_ courseID: Int) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "course", value: String(courseID))]
        return components.url
    }

    /// The course an open link names, or nil for any other link.
    public static func openedCourse(in url: URL) -> Int? {
        guard url.scheme == scheme, url.host == "open" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "course" }?.value.flatMap(Int.init)
    }

    /// The course a Show in Findle link names, or nil for any other link.
    public static func shownCourse(in url: URL) -> Int? {
        guard url.scheme == scheme, url.host == "show" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "course" }?.value.flatMap(Int.init)
    }
}
