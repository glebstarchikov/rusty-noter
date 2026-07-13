import Foundation
@testable import NoterCore

func makeTempVault() throws -> Vault {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noter-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return Vault(root: dir)
}

@discardableResult
func writeFile(_ vault: Vault, _ relativePath: String, _ contents: String) throws -> URL {
    let url = vault.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

func sampleRaw(title: String, tags: [String] = [], body: String = "Hello\n") -> String {
    """
    ---
    title: \(title)
    type: note
    created: 2026-07-13T10:00:00+02:00
    updated: 2026-07-13T10:00:00+02:00
    tags: [\(tags.joined(separator: ", "))]
    ---

    \(body)
    """
}
