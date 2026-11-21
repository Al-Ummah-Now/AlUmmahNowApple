import Foundation

/// The one fixture channel, «الأمة الآن» / "Al Ummah Now", and its videos. The Viewer (`FixtureCatalogService`) and
/// Studio (`FixtureStudioService`) fixtures both read it, so the two apps show the same channel with the same videos
/// and the same numbers: the Viewer lists the published public videos, Studio lists them all.
///
/// Video `n` is `fixture-n` in the Viewer and `fixture-content-n` in Studio (the ids UI tests already use).
/// Every number comes from one daily model (``views(of:daysAgo:)``): a long-tail audience after upload, a weekly rhythm
/// (Friday highest, the day Surat Al-Kahf is read), day-to-day noise, and launch spikes from new uploads. Period totals,
/// top videos and lifetime counts are sums of that model, so they always agree.
public enum FixtureLibrary {
    public struct Item: Sendable {
        public let index: Int
        public let title: LocalizedText
        public let summary: LocalizedText
        /// The bundled title card (`Resources/thumbs/<thumb>.jpg`, the art Android's review fixtures use).
        public let thumb: String
        /// Lifetime views; the daily model hands them out over the video's life.
        public let views: Int
        public let seconds: Double
        public let status: StudioStatus
        public let isPublic: Bool
        /// Days before today it was uploaded.
        public let age: Int

        public var titleEN: String { title.en ?? "" }
        public var viewerID: String { "fixture-\(index)" }
        public var studioID: String { "fixture-content-\(index)" }
        public var isWatchable: Bool { status == .published && isPublic }
        /// Likes and comments in proportion to views, as on a typical channel.
        public var likes: Int { views * 13 / 1000 }
        public var comments: Int { views / 1200 }
    }

    public static let channelName = LocalizedText(en: "Al Ummah Now", ar: "الأمة الآن")
    /// Lifetime subscribers; more than any period's new subscribers.
    public static let subscribers = 18_640

    /// Newest first among the published ones, as Studio lists them: video 1 is the latest published upload.
    public static let items: [Item] = [
        item(
            1, ("Friday khutbah: patience", "خطبة الجمعة: الصبر"),
            ("This week's Friday khutbah on patience.", "خطبة الجمعة لهذا الأسبوع عن الصبر."), "khutbah", 8_020, 1_934,
            age: 9),
        item(
            2, ("Tafsir of Surah Al-Kahf, part 2", "تفسير سورة الكهف، الجزء الثاني"),
            ("Verses 32–59: the owner of the two gardens.", "الآيات ٣٢–٥٩: صاحب الجنتين."), "kahf2", 2_031, 1_512, age: 16),
        item(
            3, ("Tafsir of Surah Al-Kahf, part 1", "تفسير سورة الكهف، الجزء الأول"),
            ("Verses 1–31: the people of the cave.", "الآيات ١–٣١: أصحاب الكهف."), "kahf1", 11_400, 1_468, age: 23),
        item(
            4, ("Patience in hardship", "الصبر عند الشدائد"),
            ("How the Prophet ﷺ met hardship with patience.", "كيف واجه النبي ﷺ الشدائد بالصبر."), "patience", 1_004, 738,
            age: 40),
        item(
            5, ("Ramadan reminders", "تذكيرات رمضان"),
            ("Short daily reminders for the month of Ramadan.", "تذكيرات يومية قصيرة لشهر رمضان."), "ramadan", 1_310, 524,
            age: 75),
        item(
            6, ("Introduction to Tafsir", "مقدمة في التفسير"),
            ("An introduction to the sources of tafsir.", "مقدمة في مصادر التفسير."), "tafsir", 2_040_000, 1_275, age: 300),
        item(
            7, ("Surat Al-Kahf recitation", "تلاوة سورة الكهف"),
            ("The full recitation of Surat Al-Kahf for Friday.", "تلاوة كاملة لسورة الكهف ليوم الجمعة."), "kahf",
            3_012_400, 1_642, age: 410),
        item(
            8, ("Seerah overview", "نظرة عامة على السيرة"),
            ("The life of the Prophet ﷺ from Makkah to Madinah.", "سيرة النبي ﷺ من مكة إلى المدينة."), "seerah", 0, 2_895,
            status: .scheduled, isPublic: false, age: 2),
        item(
            9, ("Fiqh of Prayer", "فقه الصلاة"),
            ("The conditions, pillars and obligations of prayer.", "شروط الصلاة وأركانها وواجباتها."), "fiqh", 0, 2_210,
            status: .drafts, isPublic: false, age: 3),
        item(
            10, ("Ramadan reminder", "تذكير رمضان"), ("A short reminder for Ramadan.", "تذكير قصير لشهر رمضان."), "reminder", 0,
            312,
            status: .processing, isPublic: false, age: 0),
    ]

    // One row of the table above per call, read like a table row.
    // swiftlint:disable:next function_parameter_count
    private static func item(
        _ index: Int, _ title: (String, String), _ summary: (String, String), _ thumb: String, _ views: Int,
        _ seconds: Double, status: StudioStatus = .published, isPublic: Bool = true, age: Int
    ) -> Item {
        Item(
            index: index, title: LocalizedText(en: title.0, ar: title.1), summary: LocalizedText(en: summary.0, ar: summary.1),
            thumb: thumb, views: views, seconds: seconds, status: status, isPublic: isPublic, age: age)
    }

    /// Whether the app runs in Arabic: the stored choice (`AUNLanguage`), else the first of Arabic or English the device
    /// prefers, the same rule as `AppSettings`.
    public static func prefersArabic(
        defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Bool {
        if let stored = defaults.string(forKey: "AUNLanguage") { return stored == "ar" }
        return preferredLanguages.first { $0.hasPrefix("ar") || $0.hasPrefix("en") }?.hasPrefix("ar") ?? false
    }

    /// The published public videos, as the Viewer lists them.
    public static var watchable: [Item] { items.filter(\.isWatchable) }

    /// A bundled title card.
    public static func thumbnail(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "jpg", subdirectory: "thumbs")
    }

    /// Today at 00:00 UTC, the day every fixture date counts from.
    public static func today(_ now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.startOfDay(for: now)
    }

    /// When `item` was uploaded: 09:00 UTC `age` days ago (the latest upload, still processing, an hour later).
    public static func uploaded(_ item: Item, now: Date = Date()) -> Date {
        today(now).addingTimeInterval(Double(-item.age) * 86_400 + (item.age == 0 ? 10 : 9) * 3600)
    }

    // MARK: Daily model

    /// Views of `item` on each UTC day of its life, indexed by days before today; they add up to 97% of its lifetime
    /// views (the rest came before the daily series). Empty for unpublished videos.
    public static func series(of item: Item, now: Date = Date()) -> [Int] {
        guard item.views > 0 else { return [] }
        let today = dayNumber(now)
        let raw = (0...item.age).map { daysAgo in
            curve(age: item.age - daysAgo) * weekday(today - daysAgo) * noise(today - daysAgo, item.index)
        }
        let total = raw.reduce(0, +)
        return raw.map { Int((Double(item.views) * 0.97 * $0 / total).rounded(.down)) }
    }

    /// Views of `item` on the UTC day `daysAgo` days before today.
    public static func views(of item: Item, daysAgo: Int, now: Date = Date()) -> Int {
        let series = series(of: item, now: now)
        return series.indices.contains(daysAgo) ? series[daysAgo] : 0
    }

    /// Audience by days since upload: a launch spike that settles into a long tail.
    private static func curve(age: Int) -> Double { exp(-Double(age) / 5) * 3 + 1 / pow(Double(age) + 4, 0.6) }

    /// Days since 1970-01-01 (UTC) of today.
    private static func dayNumber(_ now: Date) -> Int { Int((today(now).timeIntervalSince1970 / 86_400).rounded()) }

    /// Weekly rhythm, averaging 1: Friday highest, Thursday evening next, Saturday and Sunday lowest.
    static func weekday(_ day: Int) -> Double {
        // 1970-01-01 was a Thursday: 0 Thu, 1 Fri, 2 Sat, 3 Sun, 4 Mon, 5 Tue, 6 Wed.
        [1.15, 1.55, 0.85, 0.8, 0.88, 0.87, 0.9][((day % 7) + 7) % 7]
    }

    /// A repeatable 0.85–1.15 factor per day and video.
    static func noise(_ day: Int, _ salt: Int) -> Double {
        var x = UInt64(bitPattern: Int64(day &* 7919 &+ salt &* 104_729)) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return 0.85 + Double(x % 10_000) / 10_000 * 0.3
    }

    /// One video's day: views, then likes, comments, new subscribers and seconds watched in proportion to them.
    static func metric(views: Int, of item: Item, date: String) -> DailyMetric {
        DailyMetric(
            date: date, views: views, likes: views * 13 / 1000, comments: views / 1200, subscribers: views * 35 / 10_000,
            watchTime: Double(views) * item.seconds * averageWatched)
    }

    /// The share of a video the average view watches.
    public static let averageWatched = 0.38

    /// Days before today of each UTC day of `period`, both ends counted, as the API answers.
    public static func days(_ period: DateInterval, now: Date = Date()) -> [(daysAgo: Int, date: String)] {
        let count = max(1, Int((period.duration / 86_400).rounded(.up)))
        let start = today(period.start)
        let first = Int((today(now).timeIntervalSince(start) / 86_400).rounded())
        return (0..<count).map { offset in
            (first - offset, start.addingTimeInterval(Double(offset) * 86_400).ISO8601Format().prefix(10).description)
        }
    }

    /// Several videos' days added together.
    public static func daily(_ items: [Item], _ period: DateInterval, now: Date = Date()) -> [DailyMetric] {
        let series = items.map { self.series(of: $0, now: now) }
        return days(period, now: now).map { day in
            zip(items, series).map { item, views in
                metric(views: views.indices.contains(day.daysAgo) ? views[day.daysAgo] : 0, of: item, date: day.date)
            }.reduce(
                DailyMetric(date: day.date, views: 0)
            ) { sum, next in
                DailyMetric(
                    date: day.date, views: sum.views + next.views, likes: sum.likes + next.likes,
                    comments: sum.comments + next.comments, subscribers: sum.subscribers + next.subscribers,
                    watchTime: sum.watchTime + next.watchTime)
            }
        }
    }
}
