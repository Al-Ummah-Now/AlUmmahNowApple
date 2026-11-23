import Foundation

/// Calls the current api-videos endpoints. Replaced by `aun-api` when the core ships.
public struct NativeCatalogService: CatalogServicing {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let detailCache = DetailCache()
    private static let maxConcurrentDetails = 6

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
            return try Date.ISO8601FormatStyle().parse(text)
        }
    }

    private struct DataEnvelope<T: Decodable>: Decodable { let data: T }
    private struct ResultEnvelope<T: Decodable>: Decodable { let result: T }
    private struct StreamBox: Decodable { let stream: LiveStream }
    private struct MessageBox: Decodable { let message: LiveChatMessage }
    private struct ViewersBox: Decodable { let viewers: Int? }
    private struct TracksBody: Decodable { let tracks: [SubtitleTrack] }
    private struct ChaptersEnvelope: Decodable {
        struct Inner: Decodable { let chapters: [Chapter] }
        let chapters: Inner
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw CoreError.notFound }
        return try await fetch(url)
    }

    private func sendJSON(_ method: String, path: String, body: [String: Any]? = nil, contentType: String = "application/json")
        async throws -> Data
    {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setAUNClient()
        if let body {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 404,
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                (obj["code"] as? String) == Refusal.featureOff
            {
                throw CoreError.featureOff
            }
            if let refusal = Refusal.parse(data) { throw CoreError.refused(refusal) }
            throw status == 404 ? CoreError.notFound : CoreError.http(status: status)
        }
        return data
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setAUNClient()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 404,
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                (obj["code"] as? String) == Refusal.featureOff
            {
                throw CoreError.featureOff
            }
            AUNLog.network.error("GET \(url.path, privacy: .public) failed: \(status)")
            throw status == 404 ? CoreError.notFound : CoreError.http(status: status)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            AUNLog.network.error("Decoding \(String(describing: type), privacy: .public) failed: \(error)")
            throw CoreError.decoding
        }
    }

    public func homeRails(limit: Int) async throws -> [HomeRail] {
        let fetched = await withTaskGroup(of: (HomeRailKind, [Video]?).self) { group in
            for kind in HomeRailKind.allCases {
                group.addTask {
                    let data = try? await get(
                        "/api/videos/sections/\(kind.rawValue)", query: [URLQueryItem(name: "limit", value: String(limit))])
                    guard let data else { return (kind, nil) }
                    return (kind, try? decode(DataEnvelope<[Video]>.self, from: data).data)
                }
            }
            var results: [HomeRailKind: [Video]?] = [:]
            for await (kind, videos) in group { results[kind] = videos }
            return results
        }
        guard fetched.values.contains(where: { $0 != nil }) else { throw CoreError.http(status: 0) }
        // Section payloads omit localized titles, channel names and upload status, so each unique video is
        // completed from its detail record. Videos that are not playable yet are removed from the rails.
        let ids = Array(Set(fetched.values.flatMap { ($0 ?? []).map(\.id) }))
        let details = await details(ids: ids)
        return HomeRailKind.allCases.compactMap { kind in
            guard let videos = fetched[kind] ?? nil else { return nil }
            let completed = videos.compactMap { details[$0.id] }.filter(\.isPlayable)
            return completed.isEmpty ? nil : HomeRail(kind: kind, videos: completed)
        }
    }

    private func details(ids: [String]) async -> [String: Video] {
        await withTaskGroup(of: Video?.self) { group in
            var result: [String: Video] = [:]
            var pending = ids[...]
            func addNext() {
                guard let id = pending.popFirst() else { return }
                group.addTask { try? await video(id: id) }
            }
            for _ in 0..<Self.maxConcurrentDetails { addNext() }
            for await video in group {
                if let video { result[video.id] = video }
                addNext()
            }
            return result
        }
    }

    public func video(id: String) async throws -> Video {
        if let cached = await detailCache.value(for: id) { return cached }
        let video = try decode(Video.self, from: try await get("/api/videos/\(id)"))
        await detailCache.store(video)
        return video
    }

    public func subtitles(videoID: String) async throws -> [SubtitleTrack] {
        let data = try await get("/api/videos/\(videoID)/subtitles")
        return try decode(DataEnvelope<TracksBody>.self, from: data).data.tracks
    }

    public func chapters(videoID: String) async throws -> [Chapter] {
        let data = try await get("/api/videos/\(videoID)/chapters")
        return try decode(ChaptersEnvelope.self, from: data).chapters.chapters
    }

    public func subtitleText(url: URL) async throws -> String {
        guard let text = String(data: try await fetch(url), encoding: .utf8) else { throw CoreError.decoding }
        return text
    }

    public func liveStreams(
        status: LiveStreamStatus? = .live, eventType: LiveEventType? = nil, limit: Int = 20
    ) async throws -> [LiveStream] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let status { query.append(URLQueryItem(name: "status", value: status.rawValue)) }
        if let eventType { query.append(URLQueryItem(name: "eventType", value: eventType.rawValue)) }
        let data = try await get("/api/live-streams", query: query)
        if let wrapped = try? decode(ResultEnvelope<DataEnvelope<[LiveStream]>>.self, from: data) {
            return wrapped.result.data
        }
        return try decode(DataEnvelope<[LiveStream]>.self, from: data).data
    }

    public func liveStream(id: String) async throws -> LiveStream {
        let data = try await get("/api/live-streams/\(id)")
        if let wrapped = try? decode(ResultEnvelope<StreamBox>.self, from: data) {
            return wrapped.result.stream
        }
        return try decode(LiveStream.self, from: data)
    }

    public func liveStreamState(id: String) async throws -> LiveStreamState {
        let data = try await get("/api/live-streams/\(id)/state")
        if let wrapped = try? decode(ResultEnvelope<LiveStreamState>.self, from: data) {
            return wrapped.result
        }
        return try decode(LiveStreamState.self, from: data)
    }

    public func beatLiveViewer(streamID: String, viewerID: String, leaving: Bool = false) async throws -> Int? {
        var payload: [String: Any] = ["viewerId": viewerID]
        if leaving { payload["leaving"] = true }
        let data = try await sendJSON(
            "POST", path: "/api/live-streams/\(streamID)/viewers", body: payload, contentType: "text/plain")
        return (try? decode(ResultEnvelope<ViewersBox>.self, from: data))?.result.viewers
    }

    public func liveChatMessages(
        streamID: String, afterID: String? = nil, afterOffsetMs: Int? = nil, toOffsetMs: Int? = nil, limit: Int = 50
    ) async throws -> LiveChatPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let afterID { query.append(URLQueryItem(name: "afterId", value: afterID)) }
        if let afterOffsetMs { query.append(URLQueryItem(name: "afterOffsetMs", value: String(afterOffsetMs))) }
        if let toOffsetMs { query.append(URLQueryItem(name: "toOffsetMs", value: String(toOffsetMs))) }
        let data = try await get("/api/live-streams/\(streamID)/chat", query: query)
        if let wrapped = try? decode(ResultEnvelope<LiveChatPage>.self, from: data) {
            return wrapped.result
        }
        return try decode(LiveChatPage.self, from: data)
    }

    public func postLiveChatMessage(streamID: String, text: String) async throws -> LiveChatMessage {
        let data = try await sendJSON("POST", path: "/api/live-streams/\(streamID)/chat", body: ["text": text])
        if let wrapped = try? decode(ResultEnvelope<MessageBox>.self, from: data) {
            return wrapped.result.message
        }
        return try decode(LiveChatMessage.self, from: data)
    }

    public func moderateLiveChatMessage(
        streamID: String, messageID: String, action: LiveModerationAction
    ) async throws {
        _ = try await sendJSON(
            "POST", path: "/api/live-streams/\(streamID)/chat/\(messageID)/moderate",
            body: ["action": action.rawValue])
    }

    public func reportLiveChatMessage(
        messageID: String, reason: LiveReportReason, description: String? = nil
    ) async throws {
        var payload: [String: Any] = [
            "entityType": "live_chat",
            "entityId": messageID,
            "reason": reason.rawValue,
        ]
        if let description, !description.isEmpty { payload["description"] = description }
        _ = try await sendJSON("POST", path: "/api/reports", body: payload)
    }

    public func setLiveReminder(streamID: String, subscribed: Bool) async throws -> LiveReminderStatus {
        let data = try await sendJSON(
            subscribed ? "POST" : "DELETE", path: "/api/live-streams/\(streamID)/reminders")
        if let wrapped = try? decode(ResultEnvelope<LiveReminderStatus>.self, from: data) {
            return wrapped.result
        }
        return try decode(LiveReminderStatus.self, from: data)
    }
}

/// Short-lived, because detail records carry signed URLs and live counters.
private actor DetailCache {
    private var entries: [String: (video: Video, stored: Date)] = [:]
    private let lifetime: TimeInterval = 300

    func value(for id: String) -> Video? {
        guard let entry = entries[id], Date().timeIntervalSince(entry.stored) < lifetime else { return nil }
        return entry.video
    }

    func store(_ video: Video) { entries[video.id] = (video, Date()) }
}
