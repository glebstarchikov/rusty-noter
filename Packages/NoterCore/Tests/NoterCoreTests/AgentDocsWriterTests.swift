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

    /// Every `rg` recipe in the skill must carry the absolute vault path.
    /// This is the negative test that matters: an unqualified recipe run from
    /// another repo silently searches THAT repo and returns confident, wrong
    /// answers -- no error, no signal. Asserting "the path appears somewhere"
    /// would pass even with one stale relative recipe left in.
    @Test func everySkillRecipeIsPathQualified() {
        let vaultPath = "/Users/gleb/Notes"
        let skill = AgentDocsWriter.renderSkill(vaultPath: vaultPath)
        let recipes = skill
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("rg ") }

        #expect(!recipes.isEmpty)
        for recipe in recipes {
            #expect(recipe.contains(vaultPath),
                    "unqualified recipe would search the wrong tree: \(recipe)")
        }
    }

    /// The in-vault docs are read by an agent already sitting in the vault,
    /// so their recipes must stay relative -- the mode split must not leak
    /// absolute paths into CLAUDE.md/AGENTS.md.
    @Test func inVaultRecipesStayRelative() {
        let vaultPath = "/Users/gleb/Notes"
        let doc = AgentDocsWriter.render(vaultPath: vaultPath)
        let recipes = doc
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("rg ") }

        #expect(!recipes.isEmpty)
        for recipe in recipes {
            #expect(!recipe.contains(vaultPath),
                    "in-vault recipe should not be path-qualified: \(recipe)")
        }
    }

    @Test func skillCarriesFrontmatterAndTriggerLanguage() {
        let skill = AgentDocsWriter.renderSkill(vaultPath: "/Users/gleb/Notes")
        #expect(skill.hasPrefix("---\n"))
        #expect(skill.contains("name: rusty-noter"))
        #expect(skill.contains("description:"))
        // Trigger phrases the description must claim, and the negative clause
        // that keeps it from firing on unrelated questions.
        #expect(skill.contains("my notes"))
        #expect(skill.contains("note this down"))
        #expect(skill.contains("Not for general questions"))
    }

    @Test func skillTellsTheAgentItIsElsewhereAndWhatToDoIfTheVaultIsGone() {
        let skill = AgentDocsWriter.renderSkill(vaultPath: "/Users/gleb/Notes")
        #expect(skill.contains("not in that directory"))
        #expect(skill.contains("absolute paths"))
        #expect(skill.contains("does not exist"))
        // Orientation order is what makes one INDEX read + one rg achievable.
        #expect(skill.contains("/Users/gleb/Notes/INDEX.md"))
    }

    @Test func skillDocumentsTheSameFrontmatterContractAsTheVaultDocs() {
        let skill = AgentDocsWriter.renderSkill(vaultPath: "/Users/gleb/Notes")
        for key in ["title:", "type:", "created:", "updated:", "tags:"] {
            #expect(skill.contains(key))
        }
        #expect(skill.contains("status: recording"))
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
