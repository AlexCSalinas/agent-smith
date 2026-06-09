import Foundation
import Models

#if canImport(PDFKit)
import PDFKit

/// On-device PDF text extraction via PDFKit. Used by Triage for classification signals.
public enum PDFTextExtractor {
    /// Concatenate text from the first `maxPages` pages. Empty string for invalid/empty PDFs —
    /// we never throw here because PDF parsing failure should fall through to filename-only
    /// classification, not strand the file (Prime Directive 6, fail safe).
    public static func extract(from url: URL, maxPages: Int = 5) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var pieces: [String] = []
        let limit = min(doc.pageCount, maxPages)
        for i in 0..<limit {
            if let page = doc.page(at: i), let s = page.string, !s.isEmpty {
                pieces.append(s)
            }
        }
        return pieces.joined(separator: "\n")
    }
}
#else
public enum PDFTextExtractor {
    public static func extract(from url: URL, maxPages: Int = 5) -> String { "" }
}
#endif
