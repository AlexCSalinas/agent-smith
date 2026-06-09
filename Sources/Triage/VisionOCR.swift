import Foundation
import Models

#if canImport(Vision)
import Vision
import CoreImage

/// Vision-backed OCR + image labels. Always on-device; no network calls.
/// Best-effort: throws on unreadable image, returns empty strings on no text/labels.
public enum VisionOCR {
    public struct Result: Sendable {
        public let text: String
        public let labels: [String]
    }

    public static func extract(from url: URL) async throws -> Result {
        guard let image = CIImage(contentsOf: url) else {
            throw SmithError.classificationFailed(reason: "could not load image at \(url.path)")
        }

        let handler = VNImageRequestHandler(ciImage: image, options: [:])

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true

        let classifyRequest = VNClassifyImageRequest()

        try handler.perform([textRequest, classifyRequest])

        let lines: [String] = (textRequest.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        let text = lines.joined(separator: "\n")

        // Vision returns a lot of fine-grained labels; keep the top-N most confident.
        let labels: [String] = (classifyRequest.results ?? [])
            .filter { $0.confidence > 0.4 }
            .prefix(8)
            .map { $0.identifier }

        return Result(text: text, labels: labels)
    }
}
#else
// Vision is part of macOS — this fallback shouldn't actually trigger on any Apple platform,
// but the conditional makes intent explicit and keeps the module importable elsewhere.
public enum VisionOCR {
    public struct Result: Sendable {
        public let text: String
        public let labels: [String]
    }

    public static func extract(from url: URL) async throws -> Result {
        Result(text: "", labels: [])
    }
}
#endif
