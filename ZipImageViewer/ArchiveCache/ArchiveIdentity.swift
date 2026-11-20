import Foundation
import CryptoKit

enum ArchiveIdentity {
    static func signature(for url: URL, identityURL: URL,
                          cancellation: (() throws -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try cancellation?()
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(identityURL.standardizedFileURL.path)|\(digest)"
    }
}
