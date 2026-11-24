import Foundation

/// Stable live data for UI tests, snapshots and screenshots. No network access.
public struct FixtureLiveService: LiveServicing {
    /// Everything off and nothing on air: the app as it is without Epic 17.
    private let isOff: Bool
    private let playable: Bool
    private let now: Date
    private let language: AppLanguage

    public init(isOff: Bool = false, playable: Bool = false, language: AppLanguage = .en, now: Date = Date()) {
        self.isOff = isOff
        self.playable = playable
        self.language = language
        self.now = now
    }

    public static let liveID = "fixture-live"
    public static let comingID = "fixture-coming"
    public static let premiereID = "fixture-premiere"
    public static let recordingID = "fixture-recording"

    private func text(_ en: String, _ ar: String) -> String { language == .ar ? ar : en }

    private var channel: String { text("Noor Learning", "نور للتعلّم") }

    public var all: [LiveStream] {
        [
            LiveStream(
                id: Self.liveID, title: text("Questions after Maghrib", "أسئلة بعد المغرب"),
                description: text("Weekly. Questions are answered at the end.", "كل أسبوع. تُجاب الأسئلة في الآخر."),
                status: .live, eventType: .halqa, channelName: channel, startedAt: now.addingTimeInterval(-1500), viewers: 128),
            LiveStream(
                id: Self.comingID, title: text("Friday sermon", "خطبة الجمعة"), status: .scheduled, eventType: .jumuah,
                channelName: channel, scheduledStart: now.addingTimeInterval(9 * 3600)),
            LiveStream(
                id: Self.premiereID, title: text("Tafsir of Surah Al-Kahf", "تفسير سورة الكهف"), status: .scheduled,
                kind: .premiere, channelName: channel, scheduledStart: now.addingTimeInterval(7954)),
        ]
    }

    public func features() async -> UserFeatures {
        isOff ? .none : UserFeatures(on: [.liveChat, .livePremieres, .liveReminders, .liveEvents])
    }

    public func streams(_ status: LiveStatus, event: LiveEventType?) async throws -> [LiveStream] {
        isOff ? [] : all.filter { $0.status == status && (event == nil || $0.eventType == event) }
    }

    public func stream(id: String) async throws -> LiveStream {
        if id == Self.recordingID {
            return LiveStream(
                id: id, title: text("Questions after Maghrib, last week", "أسئلة بعد المغرب، الأسبوع الماضي"), status: .ended,
                channelName: channel)
        }
        guard let stream = all.first(where: { $0.id == id }) else { throw CoreError.notFound }
        return stream
    }

    public func state(id: String) async throws -> TimedLiveState {
        let clip = playable ? FixtureCatalogService.playableClip : URL(string: "https://fixtures.invalid/live/master.m3u8")
        let state: LiveState
        switch id {
        case Self.liveID:
            state = LiveState(
                status: .live, sessionStatus: "live", playbackURL: clip, startedAt: now.addingTimeInterval(-1500),
                eventType: .halqa, viewers: 128, chat: .init(enabled: true))
        case Self.premiereID:
            state = LiveState(
                status: .scheduled, kind: .premiere, scheduledStart: now.addingTimeInterval(7954), durationSeconds: 1860,
                chat: .init(enabled: true))
        case Self.recordingID:
            state = LiveState(status: .ended, sessionStatus: "ended", vodURL: clip, chat: .init(replay: true))
        case Self.comingID:
            state = LiveState(
                status: .scheduled, scheduledStart: now.addingTimeInterval(9 * 3600), eventType: .jumuah,
                chat: .init(enabled: true))
        default: throw CoreError.notFound
        }
        return TimedLiveState(state: state)
    }

    public var messages: [LiveChatMessage] {
        [
            ("Yusuf Rahman", "يوسف الرحمن", nil, "Assalamu alaikum from Toronto.", "السلام عليكم من تورنتو."),
            (
                "Noor Learning", "نور للتعلّم", LiveChatMessage.Role.owner, "Wa alaikum assalam. Welcome, everyone.",
                "وعليكم السلام ورحمة الله. أهلًا بكم جميعًا."
            ),
            ("Khadija Haddad", "خديجة حداد", nil, "Is there a recording after?", "هل يبقى التسجيل بعد ذلك؟"),
            (
                "Omar Farooq", "عمر الفاروق", .moderator, "Yes, it stays on the channel with the chat beside it.",
                "نعم، يبقى في القناة ومعه المحادثة."
            ),
            (
                "Bilal Ahmed", "بلال أحمد", nil, "The sound is clear now, jazakum Allahu khayran.",
                "الصوت واضح الآن، جزاكم الله خيرًا."
            ),
        ].enumerated().map { index, m in
            LiveChatMessage(
                id: "m\(index)", authorName: text(m.0, m.1), authorRole: m.2, text: text(m.3, m.4), offsetMs: index * 400)
        }
    }

    public var pinned: LiveChatMessage {
        LiveChatMessage(
            id: "pin", authorName: channel, text: text("Please keep to today’s subject.", "نرجو الالتزام بموضوع اليوم."),
            offsetMs: 0)
    }

    public func chat(id: String) async throws -> LiveChatPage {
        guard id == Self.liveID else { return LiveChatPage(messages: []) }
        return LiveChatPage(messages: messages, pinned: pinned)
    }

    public func chatReplay(id: String, fromMs: Int, toMs: Int) async throws -> LiveChatPage {
        LiveChatPage(messages: messages.filter { $0.offsetMs >= fromMs && $0.offsetMs < toMs })
    }

    public func beat(id: String, viewerID: String, leaving: Bool) async -> Int? { 128 }
}
