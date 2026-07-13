import Foundation

public struct Vault: Sendable {
    public let root: URL

    public static let generatedFiles: Set<String> = ["INDEX.md", "CLAUDE.md", "AGENTS.md"]

    public init(root: URL) {
        self.root = root.standardizedFileURL
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
        let filePath = url.standardizedFileURL.path
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
            guard let rel = relativePath(of: url), isNotePath(rel) else { continue }
            result.append(rel)
        }
        return result.sorted()
    }
}
