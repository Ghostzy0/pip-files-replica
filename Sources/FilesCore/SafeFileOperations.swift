import Foundation
import Darwin
import CryptoKit

/// Mutation boundary. Directory descriptors pin each traversed directory, so
/// replacing a path component with a symlink cannot redirect the write.
/// This uses only Apple system APIs and never invokes a shell.
enum SafeFileOperations {
    private static let tagAttribute = "com.apple.metadata:_kMDItemUserTags"
    #if DEBUG
    static var beforeFinalStatForTesting: (() -> Void)?
    static var beforeEntryFingerprintForTesting: (() -> Void)?
    static var beforeSourceStageRenameForTesting: (() -> Void)?
    static var beforeFinalStageRenameForTesting: (() -> Void)?
    static var beforeRecoveryVerificationForTesting: (() -> Void)?
    #endif
    private final class Parent {
        let fd: Int32
        let name: String
        init(fd: Int32, name: String) { self.fd = fd; self.name = name }
        deinit { close(fd) }
    }

    static func directEntries(in folder: URL) throws -> [(URL, Result<FileFingerprint, Error>)] {
        let fd = try openDirectory(folder.path)
        defer { close(fd) }
        let copy = dup(fd)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw systemError("Cannot enumerate selected directory")
        }
        defer { closedir(stream) }
        var entries: [(URL, Result<FileFingerprint, Error>)] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw systemError("Directory listing changed") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw FilesError.unsupported("A filename cannot be represented safely") }
            if name == "." || name == ".." { continue }
            let url = folder.appendingPathComponent(name)
            #if DEBUG
            beforeEntryFingerprintForTesting?()
            #endif
            entries.append((url, Result { try fingerprintAt(fd, name: name) }))
        }
        return entries.sorted { $0.0.lastPathComponent < $1.0.lastPathComponent }
    }

    static func fingerprint(_ url: URL) throws -> FileFingerprint {
        let location = try parent(url)
        return try fingerprintAt(location.fd, name: location.name)
    }

    static func copy(_ source: URL, to destination: URL, expected: FileFingerprint) throws {
        let src = try parent(source)
        let dst = try parent(destination)
        let input = try openRegular(src, expected: expected)
        defer { close(input) }
        let output = try createExclusive(dst)
        defer { close(output) }
        // fcopyfile copies data, stat, ACLs and named forks/xattrs through the
        // pinned descriptors. The destination was opened O_EXCL above. An error
        // leaves the exclusive partial result and its journal intent for review.
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
            throw systemError("Could not copy file data and metadata; inspect the incomplete result")
        }
        guard fsync(output) == 0 else { throw systemError("Sync failed") }
        guard try fingerprintFD(input) == expected else {
            throw FilesError.stalePreview("Source changed while copying; inspect the incomplete result")
        }
        let copied = try fingerprintFD(output)
        guard copied.size == expected.size, copied.contentHash == expected.contentHash,
              copied.permissions == expected.permissions,
              copied.modifiedAt == expected.modifiedAt, copied.tags == expected.tags else {
            throw FilesError.interrupted("Copied result differs from the source; inspect the incomplete result")
        }
    }

    /// The first rename may stage a concurrently substituted name. Verify the
    /// staged inode before placing anything at the destination; on mismatch,
    /// restore only if the source name is vacant. An uncooperative same-UID
    /// writer can still race between verification and the final rename, so a
    /// postcheck keeps the staged name for explicit recovery on mismatch.
    static func move(_ source: URL, to destination: URL, staging: URL, expected: FileFingerprint) throws {
        guard staging.deletingLastPathComponent().path == source.deletingLastPathComponent().path,
              staging.path != source.path, staging.path != destination.path else {
            throw FilesError.unsafePath("Move stage must be a distinct sibling of the source")
        }
        let src = try parent(source)
        let stage = try sibling(staging, of: src)
        let dst = destination.deletingLastPathComponent().path == source.deletingLastPathComponent().path
            ? try sibling(destination, of: src) : try parent(destination)
        let input = try openRegular(src, expected: expected)
        defer { close(input) }
        #if DEBUG
        beforeSourceStageRenameForTesting?()
        #endif
        try renameExclusive(src, stage)
        do {
            let staged = try openRegular(stage, expected: expected)
            close(staged)
        } catch {
            _ = try? renameExclusive(stage, src)
            throw FilesError.interrupted("Source changed while staging; inspect \(staging.path) and \(source.path)")
        }
        #if DEBUG
        beforeFinalStageRenameForTesting?()
        #endif
        do {
            try renameExclusive(stage, dst)
        } catch {
            // A failed cross-volume or occupied destination leaves the selected
            // file at its journaled stage unless the original name is vacant.
            _ = try? renameExclusive(stage, src)
            throw error
        }
        do {
            let moved = try openRegular(dst, expected: expected)
            close(moved)
        } catch {
            // Do not remove a path by name. Preserve any substituted inode at
            // the recorded stage if it can be moved there exclusively.
            _ = try? renameExclusive(dst, stage)
            throw FilesError.interrupted("Moved name changed before verification; inspect \(staging.path) and \(destination.path)")
        }
    }

    static func archive(_ source: URL, to destination: URL, expected: FileFingerprint) throws {
        let src = try parent(source)
        let dst = try parent(destination)
        let input = try openRegular(src, expected: expected)
        defer { close(input) }
        guard expected.size <= 128 * 1_024 * 1_024 else {
            throw FilesError.unsupported("ZIP action currently supports files up to 128 MiB")
        }
        let (contents, hash) = try readAll(input, limit: 128 * 1_024 * 1_024)
        guard Int64(contents.count) == expected.size, hash == expected.contentHash else {
            throw FilesError.stalePreview("Source changed while archiving")
        }
        let zip = try ZipStore.archiveData(name: src.name, contents: contents)
        let output = try createExclusive(dst)
        defer { close(output) }
        try writeAll(zip, to: output)
        guard fsync(output) == 0 else { throw systemError("Sync failed") }
    }

    static func tagMetadata(_ source: URL, expected: FileFingerprint) throws -> Data? {
        let location = try parent(source)
        let fd = try openRegular(location, expected: expected)
        defer { close(fd) }
        return try readTags(fd)
    }

    static func addTag(_ tag: String, to source: URL, expected: FileFingerprint) throws {
        let location = try parent(source)
        let fd = try openRegular(location, expected: expected, writable: true)
        defer { close(fd) }
        let old = try readTags(fd)
        guard try decodedTagNames(old) == expected.tags else {
            throw FilesError.stalePreview("Finder tags changed before apply")
        }
        var names: [String]
        if let old {
            guard let value = try PropertyListSerialization.propertyList(from: old, options: [], format: nil) as? [String] else {
                throw FilesError.unsupported("Existing Finder tags cannot be decoded safely")
            }
            names = value
        } else { names = [] }
        guard !names.contains(where: { $0.split(separator: "\n", maxSplits: 1).first.map(String.init) == tag }) else { return }
        names.append(tag)
        let data = try PropertyListSerialization.data(fromPropertyList: names, format: .binary, options: 0)
        try writeTags(fd, data)
    }

    static func restoreTagMetadata(_ source: URL, metadata: Data?, expected: FileFingerprint) throws {
        let location = try parent(source)
        let fd = try openRegular(location, expected: expected, writable: true)
        defer { close(fd) }
        guard try decodedTagNames(readTags(fd)) == expected.tags else {
            throw FilesError.stalePreview("Finder tags changed before undo")
        }
        try writeTags(fd, metadata)
    }

    /// Undo of copy/ZIP removes the visible result name but retains its inode
    /// at a journaled hidden sibling. No path-based unlink occurs, including
    /// after a concurrent replacement. This recovery copy is never purged.
    static func retainForRecovery(_ url: URL, at recovery: URL, expected: FileFingerprint) throws {
        guard recovery.deletingLastPathComponent().path == url.deletingLastPathComponent().path,
              recovery.path != url.path else {
            throw FilesError.unsafePath("Recovery path must be a distinct sibling of the result")
        }
        let location = try parent(url)
        let retained = try sibling(recovery, of: location)
        let preflight = try openRegular(location, expected: expected)
        close(preflight)
        try renameExclusive(location, retained)
        #if DEBUG
        beforeRecoveryVerificationForTesting?()
        #endif
        do {
            let held = try openRegular(retained, expected: expected)
            close(held)
        } catch {
            throw FilesError.interrupted("Result changed during undo; inspect recovery path \(recovery.path)")
        }
    }

    private static func renameExclusive(_ source: Parent, _ destination: Parent) throws {
        let rc = source.name.withCString { s in
            destination.name.withCString { d in
                renameatx_np(source.fd, s, destination.fd, d, UInt32(RENAME_EXCL))
            }
        }
        guard rc == 0 else {
            if errno == EEXIST { throw FilesError.conflict("Destination appeared during move") }
            if errno == EXDEV { throw FilesError.unsupported("Move across volumes is unavailable; use copy") }
            throw systemError("Move failed")
        }
    }

    private static func parent(_ url: URL) throws -> Parent {
        let path = url.path
        guard path.hasPrefix("/") else { throw FilesError.unsafePath("Path must be absolute") }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains("."), !parts.contains(".."),
              let name = parts.last, !name.isEmpty else { throw FilesError.unsafePath("Unsafe path") }
        let directoryPath = "/" + parts.dropLast().joined(separator: "/")
        let fd = try openDirectory(directoryPath)
        return Parent(fd: fd, name: name)
    }

    private static func sibling(_ url: URL, of existing: Parent) throws -> Parent {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw FilesError.unsafePath("Invalid sibling name")
        }
        let fd = dup(existing.fd)
        guard fd >= 0 else { throw systemError("Cannot pin sibling directory") }
        return Parent(fd: fd, name: name)
    }

    private static func openDirectory(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/") else { throw FilesError.unsafePath("Directory path must be absolute") }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains("."), !parts.contains("..") else { throw FilesError.unsafePath("Unsafe directory path") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw systemError("Cannot open root") }
        for component in parts {
            let next = component.withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            close(fd)
            guard next >= 0 else { throw FilesError.unsafePath("Directory changed or is a symlink: \(component)") }
            fd = next
        }
        return fd
    }

    private static func fingerprintAt(_ directory: Int32, name: String) throws -> FileFingerprint {
        let fd = name.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw FilesError.unsafePath("File changed or is a symlink") }
        defer { close(fd) }
        return try fingerprintFD(fd)
    }

    private static func fingerprintFD(_ fd: Int32) throws -> FileFingerprint {
        var before = stat()
        guard fstat(fd, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw FilesError.unsafePath("Expected a regular file")
        }
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw systemError("Cannot read file") }
        let (size, hash) = try hashAll(fd)
        let tags = try decodedTagNames(readTags(fd, allowUnsupported: true))
        #if DEBUG
        beforeFinalStatForTesting?()
        #endif
        var after = stat()
        guard fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, Int64(before.st_size) == size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw FilesError.unstable("File changed while reading")
        }
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw systemError("Cannot reset file read position") }
        let created = Date(timeIntervalSince1970:
            Double(before.st_birthtimespec.tv_sec) + Double(before.st_birthtimespec.tv_nsec) / 1_000_000_000)
        let modified = Date(timeIntervalSince1970:
            Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileFingerprint(deviceID: UInt64(before.st_dev), fileID: UInt64(before.st_ino),
                               size: size, permissions: UInt16(before.st_mode & mode_t(0o7777)),
                               createdAt: created, modifiedAt: modified,
                               contentHash: hash, tags: tags)
    }

    private static func openRegular(_ parent: Parent, expected: FileFingerprint, writable: Bool = false) throws -> Int32 {
        let access = writable ? O_RDWR : O_RDONLY
        let fd = parent.name.withCString { openat(parent.fd, $0, access | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw systemError("Source changed or unavailable") }
        do {
            guard try fingerprintFD(fd) == expected else { throw FilesError.stalePreview("File changed") }
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    private static func readTags(_ fd: Int32, allowUnsupported: Bool = false) throws -> Data? {
        let size = tagAttribute.withCString { fgetxattr(fd, $0, nil, 0, 0, 0) }
        if size < 0 {
            if errno == ENOATTR { return nil }
            if allowUnsupported && (errno == ENOTSUP || errno == EOPNOTSUPP) { return nil }
            if errno == ENOTSUP || errno == EOPNOTSUPP {
                throw FilesError.unsupported("Finder tags are unavailable on this volume")
            }
            throw systemError("Cannot read Finder tags")
        }
        guard size <= 1_048_576 else { throw FilesError.unsupported("Finder tag metadata too large") }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { bytes in
            tagAttribute.withCString { fgetxattr(fd, $0, bytes.baseAddress, size, 0, 0) }
        }
        guard count == size else { throw systemError("Finder tags changed while reading") }
        return data
    }

    private static func decodedTagNames(_ data: Data?) throws -> [String] {
        guard let data else { return [] }
        guard let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String] else {
            throw FilesError.unsupported("Finder tag metadata is malformed")
        }
        return raw.map { String($0.split(separator: "\n", maxSplits: 1).first ?? "") }.sorted()
    }

    private static func writeTags(_ fd: Int32, _ data: Data?) throws {
        if let data {
            let rc = data.withUnsafeBytes { bytes in
                tagAttribute.withCString { fsetxattr(fd, $0, bytes.baseAddress, data.count, 0, 0) }
            }
            guard rc == 0 else { throw systemError("Cannot write Finder tags") }
        } else {
            let rc = tagAttribute.withCString { fremovexattr(fd, $0, 0) }
            guard rc == 0 || errno == ENOATTR else { throw systemError("Cannot remove Finder tags") }
        }
    }

    private static func createExclusive(_ parent: Parent) throws -> Int32 {
        let fd = parent.name.withCString {
            openat(parent.fd, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else {
            if errno == EEXIST { throw FilesError.conflict("Destination already exists") }
            throw systemError("Cannot create destination")
        }
        return fd
    }

    private static func transfer(_ input: Int32, _ output: Int32) throws -> (Int64, String) {
        var count: Int64 = 0
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = Darwin.read(input, &buffer, buffer.count)
            if n < 0 { throw systemError("Read failed") }
            if n == 0 { break }
            count += Int64(n)
            hasher.update(data: Data(buffer.prefix(n)))
            try buffer.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < n {
                    let wrote = Darwin.write(output, base.advanced(by: offset), n - offset)
                    if wrote <= 0 { throw systemError("Write failed") }
                    offset += wrote
                }
            }
        }
        return (count, hex(hasher.finalize()))
    }

    private static func readAll(_ input: Int32, limit: Int) throws -> (Data, String) {
        var result = Data()
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = Darwin.read(input, &buffer, buffer.count)
            if n < 0 { throw systemError("Read failed") }
            if n == 0 { break }
            guard result.count <= limit - n else { throw FilesError.unsupported("File exceeds archive or undo safety limit") }
            result.append(contentsOf: buffer.prefix(n))
            hasher.update(data: Data(buffer.prefix(n)))
        }
        return (result, hex(hasher.finalize()))
    }

    private static func hashAll(_ input: Int32) throws -> (Int64, String) {
        var count: Int64 = 0
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = Darwin.read(input, &buffer, buffer.count)
            if n < 0 { throw systemError("Read failed") }
            if n == 0 { break }
            count += Int64(n)
            hasher.update(data: Data(buffer.prefix(n)))
        }
        return (count, hex(hasher.finalize()))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let wrote = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if wrote <= 0 { throw systemError("Write failed") }
                offset += wrote
            }
        }
    }

    private static func systemError(_ context: String) -> FilesError {
        .interrupted("\(context): \(String(cString: strerror(errno)))")
    }
}
