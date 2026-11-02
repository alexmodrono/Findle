// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import QuickLookUI
import SharedDomain
import UniformTypeIdentifiers

/// Space on an H5P or SCORM package shows its title, kind of activity and a
/// first image instead of an opaque archive; on an assignment's or quiz's
/// summary, its dates, status, grade and brief. A file it can't read throws,
/// so Quick Look shows its default preview.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    /// Larger packages aren't read into memory for a preview.
    private static let maxPackageSize = 300 * 1024 * 1024

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let size = (try request.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxPackageSize else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: request.fileURL, options: .mappedIfSafe)
        // An assignment's or quiz's summary file (FX-04).
        if [CourseworkSummary.assignmentExtension, CourseworkSummary.quizExtension].contains(request.fileURL.pathExtension.lowercased()) {
            guard let coursework = CourseworkSummary.decode(data) else { throw CocoaError(.fileReadCorruptFile) }
            let page = Data(coursework.html.utf8)
            return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 600, height: coursework.brief == nil ? 300 : 520)) { _ in
                page
            }
        }
        let summary = try PackageSummary.read(data)
        let html = Data(summary.html.utf8)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 640, height: summary.image == nil ? 280 : 560)) { _ in
            html
        }
    }
}
