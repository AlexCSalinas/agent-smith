import Foundation
import Models

/// Triage decides whether a freshly-noticed file is something Smith should handle, and
/// waits until the file is fully written before passing it downstream.
///
/// v1 only handles screenshots (macOS screenshot filename pattern OR any `.png`/`.jpg`/`.jpeg`
/// the user drops into the watched folder).
public struct Triage: Sendable {
    public struct Config: Sendable {
        /// Extensions Triage will consider. Lowercase, no leading dot.
        public var allowedExtensions: Set<String>
        /// Filename suffixes that mean "still being written, ignore." Lowercase.
        public var partialSuffixes: Set<String>
        /// How long to wait between size polls.
        public var pollInterval: Duration
        /// How many consecutive matching size polls are required before declaring stability.
        public var requiredStablePolls: Int
        /// Max time to wait for stability before giving up.
        public var stabilityTimeout: Duration

        public static let `default` = Config(
            allowedExtensions: ["png", "jpg", "jpeg", "heic"],
            partialSuffixes: [".crdownload", ".download", ".part", ".tmp", ".partial"],
            pollInterval: .milliseconds(250),
            requiredStablePolls: 2,
            stabilityTimeout: .seconds(30)
        )
    }

    public let config: Config

    public init(config: Config = .default) {
        self.config = config
    }

    /// Fast filter — does this URL look like something we should touch at all?
    /// Pure / synchronous so callers can short-circuit before the more expensive stability wait.
    public func shouldConsider(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let lower = name.lowercased()

        // Skip dotfiles and OS metadata.
        if name.hasPrefix(".") { return false }

        // Skip browser/download partial-file conventions.
        for suffix in config.partialSuffixes where lower.hasSuffix(suffix) {
            return false
        }

        // Must be in our allowed extension set.
        let ext = url.pathExtension.lowercased()
        guard config.allowedExtensions.contains(ext) else { return false }

        return true
    }

    /// True iff the filename looks like a macOS screenshot (Screenshot 2026-06-08 at 10.13.42 AM.png).
    /// Used to flag automatically-generated screenshots vs files the user dragged in (which we also handle).
    public func looksLikeMacScreenshot(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.range(of: #"^Screenshot \d{4}-\d{2}-\d{2}( at .+)?\.(png|jpe?g|heic)$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Block until the file's byte size stays constant across `requiredStablePolls` polls,
    /// or until `stabilityTimeout` elapses. Throws `fileNotStable` on timeout.
    public func waitForStability(_ url: URL) async throws {
        let fm = FileManager.default
        let deadline = ContinuousClock.now.advanced(by: config.stabilityTimeout)

        var lastSize: Int64? = nil
        var stableCount = 0

        while ContinuousClock.now < deadline {
            guard fm.fileExists(atPath: url.path) else {
                // File disappeared — it was moved or deleted before we could act.
                throw SmithError.fileNotFound(url)
            }
            let size = (try? fileByteSize(url)) ?? 0

            if let last = lastSize, last == size, size > 0 {
                stableCount += 1
                if stableCount >= config.requiredStablePolls {
                    AppLog.triage.debug(
                        "stable \(url.lastPathComponent, privacy: .public) at \(size, privacy: .public) bytes"
                    )
                    return
                }
            } else {
                stableCount = 0
            }
            lastSize = size

            try await Task.sleep(for: config.pollInterval)
        }

        throw SmithError.fileNotStable(url)
    }

    /// Build the `FileSignals` payload Triage passes to the Classifier. Reads file size,
    /// runs OCR + image labels via Vision, attaches the candidate folder list.
    public func buildSignals(
        for url: URL,
        candidateFolders: [String]
    ) async throws -> FileSignals {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw SmithError.fileNotFound(url) }

        let size = (try? fileByteSize(url)) ?? 0

        // Vision is best-effort. If OCR fails (corrupt image, unsupported format) we still
        // hand the classifier the filename + folder list — it'll fall back to filename signal.
        var ocrText = ""
        var labels: [String] = []
        if let result = try? await VisionOCR.extract(from: url) {
            ocrText = result.text
            labels = result.labels
        }

        return FileSignals(
            url: url,
            filename: url.lastPathComponent,
            byteSize: size,
            ocrText: ocrText,
            imageLabels: labels,
            candidateFolders: candidateFolders
        )
    }

    private func fileByteSize(_ url: URL) throws -> Int64 {
        // Don't use URL.resourceValues here — values are cached on the URL instance, so a
        // long-running stability poll would observe the size at first call forever.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
}
