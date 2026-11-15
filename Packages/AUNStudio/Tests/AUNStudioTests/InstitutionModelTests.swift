import AUNCoreBridge
import Foundation
import Testing

@testable import AUNStudio

@MainActor
struct InstitutionModelTests {
    private func model(channel: String = "fixture-channel") -> InstitutionModel {
        InstitutionModel(services: .fixtures(signedIn: true), channelID: channel)
    }

    @Test func ownerLoadsAnEditableKitAndLibrary() async {
        let model = model()
        await model.refresh()
        #expect(model.load == .loaded)
        #expect(model.canEdit)
        #expect(model.library.canEdit)
        #expect(model.kit.name.ar == "الأمة الآن")
        #expect(model.assets(of: .image).map(\.id) == ["a1b2c3d4e5f60001"])
        #expect(model.asset(model.kit.logo)?.name == "Channel logo")
        #expect(!model.hasChanges)
        #expect(!model.canSave)
    }

    @Test func teamMemberSeesTheOwnersKitReadOnly() async {
        let model = model(channel: "fixture-channel-2")
        await model.refresh()
        #expect(model.load == .loaded)
        #expect(!model.canEdit)
        #expect(!model.library.canEdit)
        model.kit.name.en = "Changed"
        #expect(model.hasChanges)
        #expect(!model.canSave)
    }

    @Test func editSaveAndRevert() async {
        let model = model()
        await model.refresh()
        model.kit.colors.primary = "#12ab34"
        model.kit.watermark = .bottomEnd
        #expect(model.canSave)
        await model.save()
        #expect(model.message?.key == "studio.brand.saved")
        #expect(!model.hasChanges)
        model.kit.lowerThird.style = .box
        model.revert()
        #expect(model.kit.lowerThird.style == .bar)
        #expect(model.kit.colors.primary == "#12ab34")
    }

    @Test func invalidColourBlocksSaving() async {
        let model = model()
        await model.refresh()
        model.kit.colors.text = "red"
        #expect(model.invalidColors == ["text"])
        #expect(!model.canSave)
    }

    @Test func deletingTheLogoClearsItFromTheKit() async throws {
        let model = model()
        await model.refresh()
        let logo = try #require(model.asset(model.kit.logo))
        await model.delete(logo)
        #expect(model.kit.logo == nil)
        #expect(!model.hasChanges)
        #expect(model.assets(of: .image).isEmpty)
        #expect(model.message?.key == "studio.assets.deleted")
    }

    @Test func addingChecksLimitsBeforeSending() async throws {
        let model = model()
        await model.refresh()
        let empty = FileManager.default.temporaryDirectory.appending(path: "aun-empty-\(UUID().uuidString).png")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        await model.add(file: empty)
        #expect(model.message?.key == "studio.assets.error.empty")

        let png = FileManager.default.temporaryDirectory.appending(path: "aun-logo-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: png)
        defer { try? FileManager.default.removeItem(at: png) }
        let before = model.library.assets.count
        await model.add(file: png)
        #expect(model.library.assets.count == before + 1)
        #expect(model.message?.key == "studio.assets.added")
    }

    @Test func serverRefusalsBecomeMessages() {
        #expect(InstitutionModel.message(for: CoreError.forbidden).key == "studio.brand.ownerOnly")
        #expect(InstitutionModel.message(for: CoreError.conflict("library_full")).key == "studio.assets.error.library_full")
        #expect(InstitutionModel.message(for: CoreError.invalid("too_large")).key == "studio.assets.error.too_large")
        #expect(InstitutionModel.message(for: CoreError.invalid("unsupported_type")).key == "studio.assets.error.unsupported")
        #expect(InstitutionModel.message(for: CoreError.invalid("invalid_color")).key == "studio.brand.invalid")
    }
}

struct AnalyticsPeriodTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    @Test func customRangeCoversWholeDaysAndTheSameSpanBefore() {
        let now = day(2026, 11, 14, hour: 18)
        let period = AnalyticsPeriod(preset: nil, from: day(2026, 11, 1, hour: 9), to: day(2026, 11, 10, hour: 3))
        let periods = period.periods(now: now)
        #expect(periods.current.start == day(2026, 11, 1))
        #expect(periods.current.end == day(2026, 11, 11).addingTimeInterval(-1))
        #expect(periods.previous.start == day(2026, 10, 22))
        #expect(periods.previous.end == day(2026, 11, 1).addingTimeInterval(-1))
        #expect(period.fileStem(now: now) == "2026-11-01_2026-11-10")
    }

    @Test func customRangeStopsAtNowAndAtAYear() {
        let now = day(2026, 11, 14, hour: 18)
        let toToday = AnalyticsPeriod(preset: nil, from: day(2026, 11, 10), to: day(2026, 12, 1)).periods(now: now)
        #expect(toToday.current.end == now)
        let long = AnalyticsPeriod(preset: nil, from: day(2023, 1, 1), to: day(2026, 11, 13)).periods(now: now)
        let days = utc.dateComponents([.day], from: long.current.start, to: day(2026, 11, 14)).day
        #expect(days == AnalyticsPeriod.maxDays)
    }

    @Test func presetMatchesTheRange() {
        let now = day(2026, 11, 14, hour: 18)
        #expect(
            AnalyticsPeriod.preset(.days7, now: now).periods(now: now).current == AnalyticsRange.days7.periods(now: now).current)
    }
}
