import AUNCoreBridge
import AUNDesign
import Foundation
import Testing

@testable import AUNStudio

/// The same cases as web `chart-scale.test.ts`, Android `ChartScaleTest` and Desktop `ChartScaleTests`.
struct ChartScaleTests {
    @Test func ticksAreZeroBasedOnRoundSteps() {
        #expect(ChartScale.nice([0, 0]) == ValueScale(top: 1, ticks: [0, 1]))
        #expect(ChartScale.nice([]) == ValueScale(top: 1, ticks: [0, 1]))
        #expect(ChartScale.nice([6075]).ticks == [0, 2000, 4000, 6000, 8000])
        #expect(ChartScale.nice([95]).ticks == [0, 25, 50, 75, 100])
        #expect(ChartScale.nice([3], integer: true).ticks == [0, 1, 2, 3])
        #expect(ChartScale.nice([1.7]).ticks == [0, 0.5, 1, 1.5, 2])
        #expect(ChartScale.nice([.nan, 40]).top >= 40)
    }

    @Test func labelsFirstMiddleAndLast() {
        #expect(ChartScale.labelIndices(28) == [0, 14, 27])
        #expect(ChartScale.labelIndices(2) == [0, 1])
        #expect(ChartScale.labelIndices(0).isEmpty)
    }

    @Test func arabicNumbersUseArabicDigits() {
        #expect(ChartScale.compact(1234, .en) == "1.2K")
        #expect(ChartScale.compact(1234, .ar).contains("١"))
        #expect(ChartScale.full(6075, .ar).contains("٦"))
    }

    @Test func watchTimeIsInMinutesOrHours() {
        #expect(ChartScale.watchUnit(largestSeconds: 3600) == .minute)
        #expect(ChartScale.watchUnit(largestSeconds: 7200) == .hour)
        #expect(ChartScale.watchTime(186, .en).contains("3.1"))
        #expect(ChartScale.watchTime(45_000, .en).contains("12.5"))
    }

    @Test func seriesRunsFromTheRightInArabic() throws {
        let daily = ["2026-11-09", "2026-11-10", "2026-11-11"].enumerated().map {
            DailyMetric(date: $1, views: $0 * 10, watchTime: Double($0) * 9000)
        }
        let views = ChartSeries(metric: .views, daily: daily)
        #expect(views.position(0, rtl: false) == 0)
        #expect(views.position(0, rtl: true) == 2)
        #expect(views.index(atPosition: 0, rtl: true) == 2)
        #expect(views.summary(L10n(.en)) == "Views from Nov 9 to Nov 11. Highest: 20 on Nov 11.")
        let watch = ChartSeries(metric: .watchTime, daily: daily)
        #expect(watch.unit == .hour)
        #expect(watch.points.last?.value == 5)
        #expect(ChartSeries(metric: .subscribers, daily: daily).isEmpty)
    }

    @Test func rebuildingIndexIsTriedOnceMore() async throws {
        let calls = Counter()
        let value = try await retryingRebuild(after: .milliseconds(1)) {
            if await calls.next() == 1 { throw CoreError.http(status: 503) }
            return 7
        }
        #expect(value == 7)
        await #expect(throws: CoreError.http(status: 503)) {
            try await retryingRebuild(after: .milliseconds(1)) { () async throws -> Int in throw CoreError.http(status: 503) }
        }
    }
}

private actor Counter {
    var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}
