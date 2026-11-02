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

    /// The course a Show in Findle link names, or nil for any other link.
    public static func shownCourse(in url: URL) -> Int? {
        guard url.scheme == scheme, url.host == "show" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "course" }?.value.flatMap(Int.init)
    }
}
