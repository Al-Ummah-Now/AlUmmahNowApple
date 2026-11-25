import AUNCoreBridge
import Foundation
import Testing

@testable import AUNFeatures

/// A clock the test moves.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

actor StubLive: LiveServicing {
    var current: LiveState
    var on: Set<UserFeature> = [.livePremieres, .liveEvents]
    var lists: [LiveStatus: [LiveStream]] = [:]
    var windows: [Int: LiveChatPage] = [:]
    private(set) var stateReads = 0
    private(set) var chatReads = 0
    private(set) var askedEvent: LiveEventType?
    private(set) var leaves = 0
    var chatFails = false
    var chatPollAfter: TimeInterval?
    var pinned: LiveChatMessage?
    /// One event's list is held back until `release`.
    var heldEvent: LiveEventType?
    private var held: CheckedContinuation<Void, Never>?
    var isHeld: Bool { held != nil }
    /// The beats in the order they were sent, and whether each is held back until `releaseBeat`.
    private(set) var sent: [Bool] = []
    private var holdsBeats = false
    private var heldBeat: CheckedContinuation<Void, Never>?
    var isBeatHeld: Bool { heldBeat != nil }
    func set(holdsBeats: Bool) { self.holdsBeats = holdsBeats }
    private var beatFails = false
    func set(beatFails: Bool) { self.beatFails = beatFails }
    /// The state's answer comes whether or not its task is cancelled.
    private var holdsState = false
    private var heldState: CheckedContinuation<Void, Never>?
    var isStateHeld: Bool { heldState != nil }
    func set(holdsState: Bool) { self.holdsState = holdsState }
    func releaseState() {
        heldState?.resume()
        heldState = nil
    }
    /// Chat reads can be held back mid-flight so tests can block while a poll is in flight.
    private var holdsChat = false
    private var heldChat: CheckedContinuation<Void, Never>?
    var isChatHeld: Bool { heldChat != nil }
    func set(holdsChat: Bool) { self.holdsChat = holdsChat }
    func releaseChat() {
        heldChat?.resume()
        heldChat = nil
    }
    var streamChannelID: String?
    var streamChannelName: String?
    func set(channelID: String?, channelName: String?) {
        streamChannelID = channelID
        streamChannelName = channelName
    }
    /// Chat reads on their way at once, at most.
    private(set) var mostChatReads = 0
    private var chatReadsNow = 0
    func releaseBeat() {
        heldBeat?.resume()
        heldBeat = nil
    }
    private(set) var windowReads: [Int] = []
    func release() {
        held?.resume()
        held = nil
    }
    func set(pinned: LiveChatMessage?) { self.pinned = pinned }
    func set(heldEvent: LiveEventType?) { self.heldEvent = heldEvent }
    /// Every read is refused with this `Retry-After`.
    var retryAfter: TimeInterval?
    /// The state does not answer.
    var isSlow = false
    private(set) var beats = 0
    let offset: TimeInterval

    init(_ state: LiveState = LiveState(status: .scheduled), offset: TimeInterval = 0) {
        current = state
        self.offset = offset
    }

    func set(_ state: LiveState) { current = state }
    func set(on: Set<UserFeature>) { self.on = on }
    func set(chatFails: Bool) { self.chatFails = chatFails }
    func set(chatPollAfter: TimeInterval?) { self.chatPollAfter = chatPollAfter }
    func set(retryAfter: TimeInterval?) { self.retryAfter = retryAfter }
    func set(isSlow: Bool) { self.isSlow = isSlow }
    /// Each answer takes this long on the test's clock.
    var takes: (@Sendable () -> Void)?
    func set(takes: (@Sendable () -> Void)?) { self.takes = takes }
    private func answerTakes() { takes?() }
    private func refuse() throws {
        if let retryAfter { throw LiveRefused(retryAfter: retryAfter) }
    }
    func set(_ status: LiveStatus, _ streams: [LiveStream]) { lists[status] = streams }
    func set(window from: Int, _ page: LiveChatPage) { windows[from] = page }

    func features() async -> UserFeatures { UserFeatures(on: on) }
    func streams(_ status: LiveStatus, event: LiveEventType?) async throws -> [LiveStream] {
        askedEvent = event
        if status == .live, let heldEvent, event == heldEvent { await withCheckedContinuation { held = $0 } }
        return lists[status] ?? []
    }
    func stream(id: String) async throws -> LiveStream {
        LiveStream(id: id, title: "T", status: current.status, channelID: streamChannelID, channelName: streamChannelName)
    }
    func state(id: String) async throws -> TimedLiveState {
        stateReads += 1
        answerTakes()
        if holdsState { await withCheckedContinuation { heldState = $0 } }
        if isSlow { try await Task.sleep(for: .seconds(60)) }
        try refuse()
        return TimedLiveState(state: current, clockOffset: offset)
    }
    func chat(id: String) async throws -> LiveChatPage {
        chatReads += 1
        chatReadsNow += 1
        mostChatReads = max(mostChatReads, chatReadsNow)
        defer { chatReadsNow -= 1 }
        answerTakes()
        if holdsChat { await withCheckedContinuation { heldChat = $0 } }
        if isSlow { try await Task.sleep(for: .seconds(60)) }
        try refuse()
        if chatFails { throw CoreError.http(status: 503) }
        return LiveChatPage(
            messages: [LiveChatMessage(id: "m", authorName: "A", text: "x", offsetMs: 0)], pinned: pinned,
            pollAfter: chatPollAfter)
    }
    func chatReplay(id: String, fromMs: Int, toMs: Int) async throws -> LiveChatPage {
        windowReads.append(fromMs)
        return windows[fromMs] ?? LiveChatPage(messages: [])
    }
    func beat(id: String, viewerID: String, leaving: Bool) async throws -> Int? {
        // As URLSession: nothing is sent in a cancelled task
        sent.append(leaving)
        // As URLSession: a cancelled task's request ends at once, though the server has it
        if holdsBeats {
            await withTaskCancellationHandler {
                await withCheckedContinuation { heldBeat = $0 }
            } onCancel: {
                Task { await self.releaseBeat() }
            }
            try Task.checkCancellation()
        }
        if beatFails, !leaving { throw CoreError.offline }
        if leaving, !Task.isCancelled { leaves += 1 }
        if !leaving { beats += 1 }
        if !leaving { answerTakes() }
        try refuse()
        return 5
    }
}

/// A catalog whose video is answered when it is released, whether or not its task is cancelled.
actor HeldCatalog: CatalogServicing {
    private var held: CheckedContinuation<Void, Never>?
    private var isReleased = false
    var isHeld: Bool { held != nil }
    func release() {
        isReleased = true
        held?.resume()
        held = nil
    }
    func homeRails(limit: Int) async throws -> [HomeRail] { [] }
    func video(id: String) async throws -> Video {
        if !isReleased { await withCheckedContinuation { held = $0 } }
        return Video(id: id, title: "T", playURL: URL(string: "https://media.test/v.m3u8"), uploadStatus: "ready")
    }
    func subtitles(videoID: String) async throws -> [SubtitleTrack] { [] }
    func chapters(videoID: String) async throws -> [Chapter] { [] }
    func subtitleText(url: URL) async throws -> String { "" }
}

/// A catalog that answers with an error.
struct BrokenCatalog: CatalogServicing {
    let error: CoreError
    func homeRails(limit: Int) async throws -> [HomeRail] { throw error }
    func video(id: String) async throws -> Video { throw error }
    func subtitles(videoID: String) async throws -> [SubtitleTrack] { throw error }
    func chapters(videoID: String) async throws -> [Chapter] { throw error }
    func subtitleText(url: URL) async throws -> String { throw error }
}

extension LiveWatchModel {
    /// One second.
    func tick() async {
        step()
        await poll()
        await settled()
    }
}

/// Waits for what other tasks do.
@MainActor func until(_ done: () async -> Bool) async throws {
    for _ in 0..<500 {
        if await done() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await done())
}
