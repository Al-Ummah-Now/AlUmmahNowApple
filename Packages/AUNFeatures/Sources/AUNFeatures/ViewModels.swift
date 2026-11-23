import AUNCoreBridge
import AUNPlayer
import Observation

public enum LoadState<Value: Sendable>: Sendable {
    case loading
    case loaded(Value)
    case failed
}

@MainActor @Observable
public final class HomeViewModel {
    public private(set) var state: LoadState<[HomeRail]> = .loading
    private let catalog: any CatalogServicing
    static let railLimit = 12

    public init(catalog: any CatalogServicing) { self.catalog = catalog }

    public func load() async {
        do {
            state = .loaded(try await catalog.homeRails(limit: Self.railLimit))
        } catch is CancellationError {
            return
        } catch {
            AUNLog.network.error("Home failed: \(error)")
            state = .failed
        }
    }
}

public struct WatchContent: Sendable {
    public var video: Video
    public var chapters: [Chapter]
    /// Other videos to watch next, as the web and Android watch pages list them; empty when they can't load.
    public var upNext: [Video] = []

    /// At most `limit` distinct videos from `rails`, in rail order, without the one being watched.
    static func upNext(from rails: [HomeRail], excluding id: String, limit: Int = 6) -> [Video] {
        var seen: Set<String> = [id]
        return Array(rails.flatMap(\.videos).filter { seen.insert($0.id).inserted }.prefix(limit))
    }
}

@MainActor @Observable
public final class WatchViewModel {
    public private(set) var state: LoadState<WatchContent> = .loading
    public let player: PlayerController
    private let catalog: any CatalogServicing
    private let videoID: String

    public init(videoID: String, catalog: any CatalogServicing) {
        self.videoID = videoID
        self.catalog = catalog
        player = PlayerController { url in try await catalog.subtitleText(url: url) }
    }

    /// Loads the page and starts this video. The next video never starts by itself (spec 21.6).
    public func load(language: AppLanguage, autoplay: Bool = true) async {
        state = .loading
        do {
            let video = try await catalog.video(id: videoID)
            // Subtitles and chapters are optional extras: the video should still play if they fail.
            async let tracks = try? catalog.subtitles(videoID: videoID)
            async let chapters = try? catalog.chapters(videoID: videoID)
            // Up next comes from the home rails; the page is complete without it.
            async let rails = try? catalog.homeRails(limit: 12)
            let (loadedTracks, loadedChapters, loadedRails) = await (tracks ?? [], chapters ?? [], rails ?? [])
            state = .loaded(
                WatchContent(
                    video: video, chapters: loadedChapters,
                    upNext: WatchContent.upNext(from: loadedRails, excluding: videoID)))
            guard video.isPlayable, let url = video.playURL else { return }
            player.load(
                PlaybackItem(
                    url: url, title: video.displayTitle(language), subtitle: video.displayChannelName(language),
                    resolutions: video.availableResolutions, subtitles: loadedTracks, chapters: loadedChapters),
                autoplay: autoplay)
        } catch is CancellationError {
            return
        } catch {
            AUNLog.network.error("Watch failed: \(error)")
            state = .failed
        }
    }
}

extension HomeRailKind {
    var titleKey: String { "rail.\(rawValue)" }
}
