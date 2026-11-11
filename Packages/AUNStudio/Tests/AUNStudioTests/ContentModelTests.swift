import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

@MainActor
struct ContentModelTests {
    private func settle(_ model: ContentModel) async throws {
        for _ in 0..<100 {
            if model.state == .loaded || model.state == .failed { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func loadsATabWithCounts() async throws {
        let model = ContentModel(channelID: "fixture-channel", services: .fixtures(signedIn: true))
        model.reload()
        try await settle(model)
        #expect(model.items.count == 3)
        #expect(model.counts[.published] == 3)
        #expect(model.counts[.drafts] == 1)
        model.status = .drafts
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)
        #expect(model.items.map(\.id) == ["fixture-content-5"])
    }

    @Test func softDeleteThenRestoreFromRecentlyDeleted() async throws {
        let services = StudioServices.fixtures(signedIn: true)
        let model = ContentModel(channelID: "fixture-channel", services: services)
        model.reload()
        try await settle(model)
        await model.delete(["fixture-content-1"])
        #expect(model.message?.key == "studio.content.deleted")
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)
        #expect(!model.items.contains { $0.id == "fixture-content-1" })
        let deleted = DeletedModel(channelID: "fixture-channel", services: services)
        await deleted.load()
        #expect(deleted.items.map(\.id) == ["fixture-content-1"])
        await deleted.restore(["fixture-content-1"])
        #expect(deleted.items.isEmpty)
        #expect(deleted.message?.key == "studio.deleted.restored")
        model.reload()
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)
        #expect(model.items.contains { $0.id == "fixture-content-1" })
    }

    @Test func bulkEditAppliesToTheSelection() async throws {
        let model = ContentModel(channelID: "fixture-channel", services: .fixtures(signedIn: true))
        model.reload()
        try await settle(model)
        model.selection = ["fixture-content-1", "fixture-content-2"]
        await model.bulkUpdate(BulkChanges(isPublic: false, addTags: ["seerah"]))
        #expect(model.selection.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        try await settle(model)
        let changed = model.items.filter { ["fixture-content-1", "fixture-content-2"].contains($0.id) }
        #expect(changed.allSatisfy { !$0.isPublic && $0.tags.contains("seerah") })
    }

    @Test func suggestionsIncludeTheChannelsOwnMatches() async throws {
        let model = ContentModel(channelID: "fixture-channel", services: .fixtures(signedIn: true))
        model.reload()
        try await settle(model)
        model.searchText = "khut"
        await model.suggest("khut")
        #expect(model.suggestions.first?.itemID == "fixture-content-3")
        await model.suggest("k")
        #expect(model.suggestions.isEmpty)
    }
}
