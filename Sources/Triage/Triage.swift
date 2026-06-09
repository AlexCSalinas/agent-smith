import Foundation
import Models

/// Triage decides whether a freshly-noticed item is something Smith should handle, waits
/// until it's done being written, and builds the `FileSignals` payload for the Classifier.
///
/// Default policy is "process everything except known-bad" (a blacklist): app bundles,
/// frameworks, iCloud placeholders, browser partial-downloads, OS metadata files, dotfiles.
/// Whitelist mode is available by setting `allowedExtensions`.
public struct Triage: Sendable {
    public struct Config: Sendable {
        /// If non-empty, only files with these extensions are processed.
        /// If empty (default), all extensions are processed subject to `excludedExtensions`.
        public var allowedExtensions: Set<String>
        /// Extensions Smith always skips. Catches macOS bundle types (`.app`, `.bundle`, …)
        /// plus a few junk file conventions.
        public var excludedExtensions: Set<String>
        /// Lowercase filename suffixes meaning "still being written".
        public var partialSuffixes: Set<String>
        /// Exact filenames Smith never touches (`.DS_Store`, `.localized`).
        public var excludedFilenames: Set<String>
        /// Process directories as candidates for moving. Default true.
        public var processFolders: Bool
        /// File extensions Vision should OCR.
        public var ocrExtensions: Set<String>
        /// File extensions PDFKit should extract text from.
        public var pdfExtensions: Set<String>
        /// Files whose presence in a directory marks it as an active project — Smith
        /// refuses to move folders containing any of these (regardless of `processFolders`).
        /// Lowercase. Empty set disables project detection.
        public var projectMarkers: Set<String>

        public var pollInterval: Duration
        public var requiredStablePolls: Int
        public var stabilityTimeout: Duration

        public init(
            allowedExtensions: Set<String> = [],
            excludedExtensions: Set<String> = [
                "app", "bundle", "framework", "kext", "plugin", "saver",
                "appex", "icloud", "alias", "lock", "swp",
                "xcodeproj", "xcworkspace", "playground"
            ],
            partialSuffixes: Set<String> = [
                ".crdownload", ".download", ".part", ".tmp", ".partial"
            ],
            excludedFilenames: Set<String> = [".DS_Store", ".localized"],
            processFolders: Bool = true,
            ocrExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp", "webp"],
            pdfExtensions: Set<String> = ["pdf"],
            projectMarkers: Set<String> = [
                ".git", "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
                "package.swift", "cargo.toml", "go.mod", "pyproject.toml", "pipfile",
                "requirements.txt", "gemfile", "pom.xml", "build.gradle", "build.gradle.kts",
                "pubspec.yaml", "composer.json", "makefile", "cmakelists.txt",
                ".xcodeproj", ".xcworkspace", "node_modules"
            ],
            pollInterval: Duration = .milliseconds(250),
            requiredStablePolls: Int = 2,
            stabilityTimeout: Duration = .seconds(30)
        ) {
            self.allowedExtensions = allowedExtensions
            self.excludedExtensions = excludedExtensions
            self.partialSuffixes = partialSuffixes
            self.excludedFilenames = excludedFilenames
            self.processFolders = processFolders
            self.ocrExtensions = ocrExtensions
            self.pdfExtensions = pdfExtensions
            self.projectMarkers = projectMarkers
            self.pollInterval = pollInterval
            self.requiredStablePolls = requiredStablePolls
            self.stabilityTimeout = stabilityTimeout
        }

        public static let `default` = Config()
    }

    public let config: Config

    public init(config: Config = .default) {
        self.config = config
    }

    /// Fast filter — does this URL look like something we should touch at all?
    public func shouldConsider(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let lower = name.lowercased()

        // Skip dotfiles.
        if name.hasPrefix(".") { return false }

        // Skip exact-name exclusions.
        if config.excludedFilenames.contains(name) { return false }

        // Skip browser/download partial-file conventions.
        for suffix in config.partialSuffixes where lower.hasSuffix(suffix) {
            return false
        }

        // Skip excluded extensions — catches `.app`, `.bundle`, `.framework`, etc.
        // (macOS treats those as files with a directory layout; the extension is the tell.)
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty && config.excludedExtensions.contains(ext) { return false }

        // Project safety: if this is a directory containing well-known project markers
        // (.git, package.json, etc.), refuse — never move an active project.
        if !config.projectMarkers.isEmpty && looksLikeActiveProject(url) {
            return false
        }

        // Skip macOS Finder aliases. These have no special extension; we detect them by
        // the file-system attribute `isAliasFile`.
        if isAliasFile(url) { return false }

        // Whitelist mode: must match if the whitelist is set.
        if !config.allowedExtensions.isEmpty {
            if ext.isEmpty {
                // Extension-less entries (folders, README-style files) are governed by processFolders.
                return config.processFolders
            }
            return config.allowedExtensions.contains(ext)
        }

        return true
    }

    /// True iff `url` is a directory whose immediate children include any of the
    /// configured project markers (`.git`, `package.json`, etc.).
    public func looksLikeActiveProject(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        let lowered = Set(entries.map { $0.lowercased() })
        return !lowered.isDisjoint(with: config.projectMarkers)
    }

    /// True iff the URL is a Finder alias (resolves to a different file/folder).
    public func isAliasFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
        return (values?.isAliasFile ?? false) || (values?.isSymbolicLink ?? false)
    }

    /// True iff the filename looks like a macOS screenshot. Informational; not used as a filter.
    public func looksLikeMacScreenshot(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.range(of: #"^Screenshot \d{4}-\d{2}-\d{2}( at .+)?\.(png|jpe?g|heic)$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Block until the file's byte size is stable across `requiredStablePolls` polls, or throw on timeout.
    /// Directories return immediately — they don't have a meaningful byte-size signal.
    public func waitForStability(_ url: URL) async throws {
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw SmithError.fileNotFound(url)
        }
        if isDir.boolValue {
            return  // a directory visible in the watched folder is treated as done
        }

        let deadline = ContinuousClock.now.advanced(by: config.stabilityTimeout)

        var lastSize: Int64? = nil
        var stableCount = 0

        while ContinuousClock.now < deadline {
            guard fm.fileExists(atPath: url.path) else {
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

    /// Build the `FileSignals` payload Triage passes to the Classifier. Different content
    /// extractors per type: Vision OCR for images, PDFKit for PDFs, filename-only otherwise.
    public func buildSignals(
        for url: URL,
        candidateFolders: [String]
    ) async throws -> FileSignals {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw SmithError.fileNotFound(url)
        }

        let size: Int64 = isDir.boolValue ? 0 : ((try? fileByteSize(url)) ?? 0)
        let ext = url.pathExtension.lowercased()

        var extractedText = ""
        var labels: [String] = []

        if !isDir.boolValue {
            if config.ocrExtensions.contains(ext) {
                if let r = try? await VisionOCR.extract(from: url) {
                    extractedText = r.text
                    labels = r.labels
                }
            } else if config.pdfExtensions.contains(ext) {
                extractedText = PDFTextExtractor.extract(from: url)
            }
            // else: filename-only classification
        }

        return FileSignals(
            url: url,
            filename: url.lastPathComponent,
            byteSize: size,
            ocrText: extractedText,
            imageLabels: labels,
            candidateFolders: candidateFolders
        )
    }

    private func fileByteSize(_ url: URL) throws -> Int64 {
        // Don't use URL.resourceValues here — it caches on the URL instance.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
}
