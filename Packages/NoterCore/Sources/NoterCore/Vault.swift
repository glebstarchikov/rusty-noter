import Darwin
import Foundation

public struct Vault: Sendable {
    public let root: URL

    public static let generatedFiles: Set<String> = ["INDEX.md", "CLAUDE.md", "AGENTS.md"]

    public init(root: URL) {
        let standardized = root.standardizedFileURL
        // Canonicalize (e.g. /var -> /private/var) so paths reported by the kernel
        // (FSEvents) compare equal to vault-derived paths.
        if let canonical = Self.canonicalPath(standardized.path) {
            self.root = URL(fileURLWithPath: canonical, isDirectory: true)
        } else {
            self.root = standardized
        }
    }

    public func isNotePath(_ relativePath: String) -> Bool {
        guard relativePath.hasSuffix(".md") else { return false }
        guard !Self.generatedFiles.contains(relativePath) else { return false }
        let components = relativePath.split(separator: "/")
        guard !components.isEmpty else { return false }
        // No hidden file or directory anywhere in the path.
        return !components.contains { $0.hasPrefix(".") }
    }

    public func noteURL(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    public func relativePath(of url: URL) -> String? {
        let filePath = Self.canonicalizedFilePath(url)
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard filePath.hasPrefix(rootPath) else { return nil }
        return String(filePath.dropFirst(rootPath.count))
    }

    public func enumerateNoteFiles() throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [String] = []
        for case let url as URL in enumerator {
            // Skip directories (e.g. a folder named "x.md") and other non-regular files.
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            guard let rel = relativePath(of: url), isNotePath(rel) else { continue }
            result.append(rel)
        }
        return result.sorted()
    }

    /// Kernel-canonical form of `path` via POSIX realpath (resolves /var -> /private/var,
    /// which Foundation's standardization deliberately leaves alone). Nil if the path
    /// does not exist.
    private static func canonicalPath(_ path: String) -> String? {
        guard let rp = realpath(path, nil) else { return nil }
        defer { free(rp) }
        return String(cString: rp)
    }

    /// Canonicalized path for `url`. For paths whose file no longer exists (deleted-file
    /// events) the parent directory is canonicalized instead; if that also fails, falls
    /// back to the Foundation-standardized path.
    private static func canonicalizedFilePath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        if let canonical = canonicalPath(standardized.path) {
            return canonical
        }
        let parent = standardized.deletingLastPathComponent()
        if let canonicalParent = canonicalPath(parent.path) {
            let dir = canonicalParent.hasSuffix("/") ? canonicalParent : canonicalParent + "/"
            return dir + standardized.lastPathComponent
        }
        return standardized.path
    }
}
