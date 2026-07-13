import Testing
import Foundation
@testable import NoterCore

@Suite struct AgentDocsWriterTests {
    @Test func rendersConventionsWithVaultPath() {
        let doc = AgentDocsWriter.render(vaultPath: "/Users/gleb/Notes")
        #expect(doc.contains("/Users/gleb/Notes"))
        #expect(doc.contains("INDEX.md"))
        #expect(doc.contains("status: recording"))
        #expect(doc.contains("rg"))
        // The frontmatter contract keys must all be documented:
        for key in ["title:", "type:", "created:", "updated:", "tags:"] {
            #expect(doc.contains(key))
        }
    }

    @Test func writesBothFilesOnceAndSkipsWhenFresh() throws {
        let vault = try makeTempVault()
        try AgentDocsWriter.writeIfMissingOrStale(to: vault)
        let claudeURL = vault.root.appendingPathComponent("CLAUDE.md")
        let agentsURL = vault.root.appendingPathComponent("AGENTS.md")
        #expect(FileManager.default.fileExists(atPath: claudeURL.path))
        let claude = try String(contentsOf: claudeURL, encoding: .utf8)
        let agents = try String(contentsOf: agentsURL, encoding: .utf8)
        #expect(claude == agents)

        // Second write with identical content must not touch mtime.
        let mtimeBefore = try FileManager.default
            .attributesOfItem(atPath: claudeURL.path)[.modificationDate] as! Date
        Thread.sleep(forTimeInterval: 0.05)
        try AgentDocsWriter.writeIfMissingOrStale(to: vault)
        let mtimeAfter = try FileManager.default
            .attributesOfItem(atPath: claudeURL.path)[.modificationDate] as! Date
        #expect(mtimeBefore == mtimeAfter)
    }
}
