import AUNCoreBridge
import Foundation
import Observation
import UniformTypeIdentifiers

/// A video picked for upload, before it joins the queue.
public struct PickedVideo: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var file: URL
    public var bookmark: Data?
    public var ownsFile: Bool
    public var fileSize: Int64
    public var mimeType: String
    /// A title typed for this file only; otherwise the pattern decides.
    public var titleOverride: String?

    public var fileName: String { file.lastPathComponent }

    /// Reads size and type; nil when the file is not a video.
    public static func make(file: URL, ownsFile: Bool, bookmark: Data? = nil) -> PickedVideo? {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let type = UTType(filenameExtension: file.pathExtension)
        guard size > 0, let type, type.conforms(to: .movie) || type.conforms(to: .video) else { return nil }
        let mime = type.preferredMIMEType.flatMap { $0.hasPrefix("video/") ? $0 : nil } ?? "video/mp4"
        return PickedVideo(file: file, bookmark: bookmark, ownsFile: ownsFile, fileSize: size, mimeType: mime)
    }
}

/// The upload form: picked files and the values set for all of them.
@MainActor @Observable
public final class UploadComposer {
    public var files: [PickedVideo] = []
    public var settings = UploadSettings()
    public var scheduleEnabled = false {
        didSet { if scheduleEnabled, settings.scheduleAt == nil { settings.scheduleAt = Self.earliestSchedule() } }
    }
    public var tagsText = ""
    public private(set) var playlists: [StudioPlaylist] = []
    public private(set) var playlistsFailed = false
    public private(set) var playlistsLoading = false
    /// The server refuses a publish time less than 5 minutes ahead; the form asks for 10.
    public static let minimumLead: TimeInterval = 10 * 60

    public init() {}

    public static func earliestSchedule(from now: Date = Date()) -> Date {
        let start = now.addingTimeInterval(60 * 60)
        let hour = Calendar.current.dateInterval(of: .hour, for: start)?.start ?? start
        return hour
    }

    public func add(_ picked: [PickedVideo]) {
        let known = Set(files.map(\.file))
        files += picked.filter { !known.contains($0.file) }
    }

    public func remove(_ id: UUID) {
        if let file = files.first(where: { $0.id == id }), file.ownsFile { try? FileManager.default.removeItem(at: file.file) }
        files.removeAll { $0.id == id }
    }

    public func loadPlaylists(channelID: String, studio: any StudioServicing) async {
        playlistsLoading = true
        defer { playlistsLoading = false }
        do {
            playlists = try await studio.playlists(channelID: channelID)
            playlistsFailed = false
            settings.playlistIDs = settings.playlistIDs.filter { id in playlists.contains { $0.id == id } }
        } catch {
            playlistsFailed = true
        }
    }

    public func togglePlaylist(_ id: String) {
        if let index = settings.playlistIDs.firstIndex(of: id) {
            settings.playlistIDs.remove(at: index)
        } else {
            settings.playlistIDs.append(id)
        }
    }

    public func title(at index: Int, channelName: String, language: AppLanguage, now: Date = Date()) -> String {
        guard files.indices.contains(index) else { return "" }
        if let custom = files[index].titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        return TitlePattern.render(
            settings.titlePattern,
            .init(
                filename: files[index].fileName, index: index, firstEpisode: settings.firstEpisode, channelName: channelName,
                date: now, language: language))
    }

    /// Why the form cannot be sent yet, as an L10n key; nil when it can.
    public func problem(now: Date = Date()) -> String? {
        if files.isEmpty { return "studio.upload.problem.noFiles" }
        if scheduleEnabled, let date = settings.scheduleAt, date < now.addingTimeInterval(Self.minimumLead) {
            return "studio.upload.problem.scheduleSoon"
        }
        return nil
    }

    /// Turns the form into queue jobs and clears it.
    public func makeJobs(channel: StudioChannel, accountID: String, language: AppLanguage, now: Date = Date()) -> [UploadJob] {
        var values = settings
        values.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !scheduleEnabled { values.scheduleAt = nil }
        let batch = UUID()
        let channelName = channel.displayName(language)
        let jobs = files.enumerated().map { index, file in
            UploadJob(
                batchID: batch, index: index, file: file.file, bookmark: file.bookmark, ownsFile: file.ownsFile,
                fileSize: file.fileSize, mimeType: file.mimeType,
                title: title(at: index, channelName: channelName, language: language, now: now), settings: values,
                channelID: channel.id, accountID: accountID)
        }
        files = []
        return jobs
    }
}
