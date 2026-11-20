import Foundation

/// An import uses a private, initially empty directory. No archive-provided filesystem
/// objects are restored: the decoder receives only the regular-file destinations below.
struct ArchiveOutputPolicy {
    let root: URL
    private let requestedRoot: URL
    let limits: ArchiveExtractionLimits
    private(set) var totalBytes: UInt64 = 0
    private var files = Set<String>()
    private var directories = Set<String>()

    init(root: URL, limits: ArchiveExtractionLimits = .default) {
        self.requestedRoot = root.standardizedFileURL
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.limits = limits
    }

    static func isSupportedImage(_ name: String) -> Bool {
        guard ["jpg", "jpeg", "png"].contains((name as NSString).pathExtension.lowercased()) else { return false }
        // Match the existing viewer's skipsHiddenFiles behavior, including macOS
        // resource-fork entries. Dot traversal remains subject to path validation.
        return !name.split(separator: "/").contains { component in
            component.hasPrefix(".") && component != "." && component != ".."
        }
    }

    mutating func reserve(entryName: String, size: UInt64) throws -> URL {
        guard !entryName.isEmpty, !entryName.hasPrefix("/"),
              !entryName.contains("\\"), !entryName.contains(":"),
              !entryName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ArchiveImportError.unsafeOutput(entryName)
        }
        let components = entryName.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }),
              entryName.utf8.count <= 4096 else {
            throw ArchiveImportError.unsafeOutput(entryName)
        }
        // Conservatively reject aliases even on a case-sensitive filesystem.
        let keys = components.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        let key = keys.joined(separator: "/")
        guard !files.contains(key), !directories.contains(key) else {
            throw ArchiveImportError.unsafeOutput("Conflicting filenames: \(entryName)")
        }
        var parentKeys: [String] = []
        for index in 1..<keys.count {
            let parent = keys.prefix(index).joined(separator: "/")
            guard !files.contains(parent) else {
                throw ArchiveImportError.unsafeOutput("A file is also used as a directory: \(entryName)")
            }
            parentKeys.append(parent)
        }
        guard files.count < limits.maximumImageCount else {
            throw ArchiveImportError.resourceLimit("The archive contains too many images (limit: \(limits.maximumImageCount)).")
        }
        guard size <= limits.maximumFileBytes else {
            throw ArchiveImportError.resourceLimit("An image exceeds the allowed uncompressed file size.")
        }
        let (newTotal, overflow) = totalBytes.addingReportingOverflow(size)
        guard !overflow, newTotal <= limits.maximumTotalBytes else {
            throw ArchiveImportError.resourceLimit("The images exceed the allowed total uncompressed size.")
        }
        let destination = components.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        guard destination.path.hasPrefix(root.path + "/") else {
            throw ArchiveImportError.unsafeOutput(entryName)
        }
        files.insert(key)
        directories.formUnion(parentKeys)
        totalBytes = newTotal
        return destination
    }

    func prepareDestination() throws {
        let manager = FileManager.default
        // Inspect the requested path before resolving it; otherwise a supplied symlink
        // could silently turn an unrelated empty directory into the extraction root.
        if let values = try? requestedRoot.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw ArchiveImportError.unsafeOutput("The extraction directory is a symbolic link.")
        }
        if manager.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  try manager.contentsOfDirectory(atPath: root.path).isEmpty else {
                throw ArchiveImportError.unsafeOutput("The extraction directory must be empty.")
            }
        } else {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let attributes = try manager.attributesOfFileSystem(forPath: root.path)
        if let available = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value {
            let (required, overflow) = totalBytes.addingReportingOverflow(limits.minimumFreeDiskBytes)
            guard !overflow, available >= required else {
                throw ArchiveImportError.resourceLimit("There is not enough free storage to extract this archive.")
            }
        }
    }

    func verifyOutput(_ url: URL, expectedSize: UInt64) throws {
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw ArchiveImportError.unsafeOutput(url.lastPathComponent)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ArchiveImportError.unsafeOutput(url.lastPathComponent)
        }
        guard let size = values.fileSize, size >= 0, UInt64(size) == expectedSize else {
            throw ArchiveImportError.storageFailure
        }
    }
}
