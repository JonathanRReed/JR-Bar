import CryptoKit
import Foundation

/// Where the Now Playing helper's dylib lives on disk, and the checks made
/// before perl is asked to load it. perl runs whatever file it is pointed
/// at, so the file sits in a folder only this account can enter
/// (`~/Library/Application Support/JR-Bar/Alcove`, mode 0700, not the
/// shared temporary folder), is read back and hashed against the pinned
/// sha256 before every launch, and is written read-only. A copy that does
/// not hash right is deleted and written again. The folder and file names
/// older builds used in the temporary folder are removed.
struct AlcoveMediaAdapterFiles {
    /// The private folder the dylib is written into.
    var directory: URL
    /// Folders an older build wrote into; their dylibs are removed.
    var legacyDirectories: [URL]
    /// The bytes to install and their pinned sha256 (lowercase hex).
    var bytes: Data
    var sha256: String
    var fileManager: FileManager = .default

    /// The folder in production: `Application Support/JR-Bar/Alcove`, with
    /// `$TMPDIR/jrbar-alcove` as the one legacy home.
    static func live(fileManager: FileManager = .default) -> AlcoveMediaAdapterFiles? {
        guard let bytes = Data(base64Encoded: AlcoveMediaAdapterAsset.dylibBase64), !bytes.isEmpty,
              let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return AlcoveMediaAdapterFiles(
            directory: support.appendingPathComponent("JR-Bar", isDirectory: true)
                .appendingPathComponent("Alcove", isDirectory: true),
            legacyDirectories: [fileManager.temporaryDirectory
                .appendingPathComponent("jrbar-alcove", isDirectory: true)],
            bytes: bytes,
            sha256: AlcoveMediaAdapterAsset.dylibSHA256,
            fileManager: fileManager)
    }

    enum Failure: Error, Equatable {
        /// The embedded bytes do not hash to the pinned value.
        case embeddedBytesMismatch
        /// The folder is a link, belongs to someone else, or cannot be made private.
        case folderNotPrivate
        /// What was written does not read back as the pinned bytes.
        case writtenCopyMismatch
    }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The dylib's path inside `directory`; its name carries the hash, so a
    /// new build lands beside the old one and the old one is swept.
    var fileURL: URL {
        directory.appendingPathComponent("mediaremote-\(sha256.prefix(16)).dylib")
    }

    /// A verified copy of the dylib, ready for perl to load.
    func prepare() throws -> URL {
        guard Self.hex(bytes) == sha256 else { throw Failure.embeddedBytesMismatch }
        try makePrivateFolder()
        sweepStale()
        let url = fileURL
        if let existing = try? Data(contentsOf: url), Self.hex(existing) == sha256 {
            return url
        }
        try? fileManager.removeItem(at: url)
        try bytes.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
        guard let written = try? Data(contentsOf: url), Self.hex(written) == sha256 else {
            try? fileManager.removeItem(at: url)
            throw Failure.writtenCopyMismatch
        }
        return url
    }

    /// The folder exists, is a real folder (not a link), is ours, and is 0700.
    private func makePrivateFolder() throws {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              ownerID == getuid() else { throw Failure.folderNotPrivate }
        if (attributes[.posixPermissions] as? NSNumber)?.intValue != 0o700 {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    /// Removes every other dylib here and the dylibs in the legacy folders
    /// (and a legacy folder once it is empty).
    private func sweepStale() {
        let keep = fileURL.lastPathComponent
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        where name != keep {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        for legacy in legacyDirectories {
            for name in (try? fileManager.contentsOfDirectory(atPath: legacy.path)) ?? []
            where name.hasPrefix("mediaremote-") && name.hasSuffix(".dylib") {
                try? fileManager.removeItem(at: legacy.appendingPathComponent(name))
            }
            // `removeItem` on a folder would take unknown files with it; only an empty one goes.
            if (try? fileManager.contentsOfDirectory(atPath: legacy.path))?.isEmpty == true {
                try? fileManager.removeItem(at: legacy)
            }
        }
    }
}
