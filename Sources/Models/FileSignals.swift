import Foundation

/// Everything the Classifier sees about a file. Built by Triage from the file at rest
/// plus any Vision-derived OCR text and image labels.
public struct FileSignals: Sendable, Equatable {
    /// The file we're filing. Always a path inside the watched source folder at this point.
    public let url: URL
    /// Raw filename, e.g. "Screenshot 2026-06-08 at 10.13.42 AM.png".
    public let filename: String
    /// File size in bytes, used by Triage's stability check too.
    public let byteSize: Int64
    /// OCR text from the image (empty if not an image / no text).
    public let ocrText: String
    /// Generic image labels from Vision's `VNClassifyImageRequest` (empty if not run).
    public let imageLabels: [String]
    /// The list of existing folder names the classifier may choose from.
    /// The classifier is forbidden from inventing new folders (Prime Directive 2 — no silent guessing).
    public let candidateFolders: [String]

    public init(
        url: URL,
        filename: String,
        byteSize: Int64,
        ocrText: String,
        imageLabels: [String],
        candidateFolders: [String]
    ) {
        self.url = url
        self.filename = filename
        self.byteSize = byteSize
        self.ocrText = ocrText
        self.imageLabels = imageLabels
        self.candidateFolders = candidateFolders
    }
}
