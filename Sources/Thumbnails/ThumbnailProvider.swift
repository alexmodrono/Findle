// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import AppKit
import QuickLookThumbnailing
import SharedDomain

/// Icon view shows an assignment's or quiz's due date, or its score once graded.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        guard let data = try? Data(contentsOf: request.fileURL), let summary = CourseworkSummary.decode(data) else {
            handler(nil, CocoaError(.fileReadCorruptFile))
            return
        }
        let side = min(request.maximumSize.width, request.maximumSize.height)
        let size = CGSize(width: side * 0.8, height: side)
        handler(QLThumbnailReply(contextSize: size) { () -> Bool in
            Self.draw(summary, in: CGRect(origin: .zero, size: size))
            return true
        }, nil)
    }

    /// A card: the kind at the top, the headline (due date or score) large, the name below.
    static func draw(_ summary: CourseworkSummary, in rect: CGRect) {
        let card = rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.04)
        let path = NSBezierPath(roundedRect: card, xRadius: card.width * 0.08, yRadius: card.width * 0.08)
        NSColor.white.setFill()
        path.fill()
        let tint = summary.kind == .assignment ? NSColor.systemBlue : NSColor.systemPurple
        tint.withAlphaComponent(0.9).setStroke()
        path.lineWidth = max(1, card.width * 0.02)
        path.stroke()

        func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat, lines: Int = 1) {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style]
            let box = CGRect(x: card.minX + card.width * 0.08, y: y, width: card.width * 0.84, height: size * 1.3 * CGFloat(lines))
            (string as NSString).draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        }
        let unit = card.width / 10
        text(summary.kind == .assignment ? "ASSIGNMENT" : "QUIZ", size: unit * 0.8, weight: .semibold, color: tint,
             y: card.maxY - unit * 2)
        text(summary.headline, size: unit * 1.5, weight: .bold, color: .black, y: card.midY - unit * 0.2, lines: 2)
        text(summary.name, size: unit * 0.9, weight: .regular, color: .darkGray, y: card.minY + unit * 1.2, lines: 2)
    }
}
