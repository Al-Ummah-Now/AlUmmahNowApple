import Foundation
import Testing

@testable import AUNCoreBridge

private let base = URL(string: "https://api.test")!

@Suite struct LiveServiceTests {
    private func service(_ answer: @escaping @Sendable (URLRequest) -> (Int, [String: String], Data)) -> NativeLiveService {
        NativeLiveService(baseURL: base, session: StubURLProtocol.session(handler: answer))
    }

    @Test func listsWhatIsOnWithItsTagAndSkipsWhatItCannotRead() async throws {
        let live = service { request in
            let query = request.url?.query ?? ""
            guard query.contains("status=live"), query.contains("eventType=halqa") else { return (400, [:], Data()) }
            let body = """
                {"success":true,"result":{"data":[
                {"id":"a","title":"T","status":"live","channelName":"C","currentViewers":4,"eventType":"halqa","actualStartTime":"2026-11-24T18:00:00.000Z"},
                {"id":"b","title":"P","status":"paused"},
                {"id":"c","title":"P","status":"live","kind":"premiere","eventType":"unknown","thumbnailUrl":""}],"cursor":""}}
                """
            return (200, [:], Data(body.utf8))
        }
        let list = try await live.streams(.live, event: .halqa)
        #expect(list.map(\.id) == ["a", "c"])
        #expect(list[0].eventType == .halqa)
        #expect(list[0].viewers == 4)
        #expect(list[1].kind == .premiere)
        #expect(list[1].eventType == nil)
    }

    @Test func anOlderServersStateHasNoChatAndNoPremiere() async throws {
        let live = service { _ in
            let body = #"{"result":{"status":"live","sessionStatus":"live","playbackUrl":"https://x.test/p.m3u8"}}"#
            return (200, [:], Data(body.utf8))
        }
        let timed = try await live.state(id: "s")
        #expect(timed.state.kind == .live)
        #expect(timed.state.chat == .init(enabled: false, replay: false))
        #expect(timed.clockOffset == 0)
    }

    @Test func theServersClockIsTakenFromTheMiddleOfTheRequest() {
        let sent = Date(timeIntervalSince1970: 1_000)
        let timed = TimedLiveState(
            state: LiveState(status: .live, serverNow: 1_021_000), sentAt: sent, receivedAt: sent.addingTimeInterval(2))
        #expect(abs(timed.clockOffset - 20) < 0.001)
    }

    @Test func aPrivateStreamIsNotFoundAndFeaturesFailClosed() async {
        let live = service { _ in (404, [:], Data(#"{"code":"not_found"}"#.utf8)) }
        await #expect(throws: CoreError.notFound) { _ = try await live.state(id: "s") }
        #expect(await live.features() == .none)
    }

    @Test func chatAndItsReplay() async throws {
        let live = service { request in
            let isReplay = request.url?.query?.contains("fromMs=60000&toMs=120000") == true
            let body = """
                {"success":true,"result":{"messages":[{"id":"m","authorName":"A","authorRole":"moderator","text":"x","offsetMs":\(isReplay ? 61_000 : 5)}],
                "pinned":null,"truncated":\(isReplay)}}
                """
            return (200, [:], Data(body.utf8))
        }
        #expect(try await live.chat(id: "s").messages[0].authorRole == .moderator)
        let window = try await live.chatReplay(id: "s", fromMs: 60_000, toMs: 120_000)
        #expect(window.messages[0].offsetMs == 61_000)
        #expect(window.truncated == true)
    }

    @Test func readsWhenToAskAgainAndABadValueIsAsIfAbsent() async throws {
        for (value, seconds) in [
            ("30000", 30), ("12000.5", 12.0005), ("\"30000\"", nil), ("null", nil), ("{}", nil), ("0", nil), ("-5", nil),
            ("1e999", nil),
        ] as [(String, TimeInterval?)] {
            let live = service { request in
                let isState = request.url?.path.hasSuffix("/state") == true
                let body = isState ? #""status":"live""# : #""messages":[]"#
                return (200, [:], Data("{\"result\":{\(body),\"pollAfterMs\":\(value)}}".utf8))
            }
            #expect(try await live.state(id: "s").state.pollAfter == seconds, "\(value)")
            #expect(try await live.chat(id: "s").pollAfter == seconds, "\(value)")
        }
    }

    @Test func aRefusalSaysWhenToAskAgain() async {
        let refused = service { request in
            (request.httpMethod == "POST" ? 503 : 429, ["Retry-After": "30"], Data())
        }
        await #expect(throws: LiveRefused(retryAfter: 30)) { _ = try await refused.chat(id: "s") }
        await #expect(throws: LiveRefused(retryAfter: 30)) { _ = try await refused.beat(id: "s", viewerID: "v", leaving: false) }
        for (status, headers) in [(503, [:]), (429, ["Retry-After": "soon"]), (500, ["Retry-After": "30"])]
            as [(Int, [String: String])]
        {
            let live = service { _ in (status, headers, Data()) }
            await #expect(throws: CoreError.http(status: status)) { _ = try await live.chat(id: "s") }
        }
    }

    @Test func countsTheViewer() async throws {
        let live = service { request in
            let isBeat = request.httpMethod == "POST" && request.url?.path == "/api/live-streams/s/viewers"
            guard isBeat else { return (404, [:], Data()) }
            return (200, [:], Data(#"{"success":true,"result":{"viewers":7}}"#.utf8))
        }
        #expect(try await live.beat(id: "s", viewerID: "v", leaving: false) == 7)
    }
}
