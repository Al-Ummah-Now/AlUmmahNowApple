import AUNCoreBridge
import Foundation

/// One file on its way to a channel. Saved to disk after every step, so uploads resume after a relaunch.
public struct UploadJob: Identifiable, Hashable, Sendable, Codable {
    public enum State: String, Hashable, Sendable, Codable {
        case waiting, preparing, uploading, finishing, done, failed, paused
    }

    public let id: UUID
    public let batchID: UUID
    public let index: Int
    /// The file to send: a copy in the app's container (iOS) or the picked file (Mac).
    public var file: URL
    /// Security-scoped bookmark of a picked file on the Mac.
    public var bookmark: Data?
    /// Studio made the copy and deletes it when done.
    public var ownsFile: Bool
    public var fileName: String
    public var fileSize: Int64
    public var mimeType: String
    public var title: String
    public var settings: UploadSettings
    public var channelID: String
    public var accountID: String

    public var state: State = .waiting
    /// L10n key of the last failure.
    public var failure: String?
    public var ticket: UploadTicket?
    public var uploadURL: URL?
    public var offset: Int64 = 0
    /// Bytes of the chunk in flight, for progress only.
    public var inFlight: Int64 = 0
    public var languageSet = false
    public var playlistsQueued = false
    public var completed = false
    public var scheduled = false

    public init(
        batchID: UUID, index: Int, file: URL, bookmark: Data? = nil, ownsFile: Bool, fileSize: Int64, mimeType: String,
        title: String, settings: UploadSettings, channelID: String, accountID: String
    ) {
        id = UUID()
        self.batchID = batchID
        self.index = index
        self.file = file
        self.bookmark = bookmark
        self.ownsFile = ownsFile
        fileName = file.lastPathComponent
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.title = title
        self.settings = settings
        self.channelID = channelID
        self.accountID = accountID
    }

    public var videoID: String? { ticket?.videoID }
    public var fraction: Double {
        guard fileSize > 0 else { return state == .done ? 1 : 0 }
        return min(1, Double(offset + inFlight) / Double(fileSize))
    }
    public var isActive: Bool { [.preparing, .uploading, .finishing].contains(state) }
    public var scheduleDate: Date? { settings.scheduleDate(at: index) }

    /// Upload position within the batch, so playlists keep the batch's order.
    public var orderKey: String { "\(batchID.uuidString.lowercased())-\(String(format: "%04d", index))" }

    /// What initiate sends: a scheduled video stays private until its time; a draft is always private.
    public var initiation: UploadInitiation {
        let tags = settings.tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let description = settings.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return UploadInitiation(
            title: title, description: description.isEmpty ? nil : description, fileSize: fileSize, mimeType: mimeType,
            isPublic: settings.visibility == .public && scheduleDate == nil,
            isDraft: settings.visibility == .draft ? true : nil,
            tags: tags.isEmpty ? nil : tags.joined(separator: ","), category: settings.category?.rawValue)
    }
}

/// Saves the queue as JSON in Application Support.
struct UploadStore: Sendable {
    let url: URL

    static func live() -> UploadStore {
        let directory = URL.applicationSupportDirectory.appending(path: "Studio", directoryHint: .isDirectory)
        return UploadStore(url: directory.appending(path: "uploads.json"))
    }

    /// Where Studio keeps copies of picked videos until they are uploaded.
    static var filesDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Studio/Uploads", directoryHint: .isDirectory)
    }

    func load() -> [UploadJob] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([UploadJob].self, from: data)) ?? []
    }

    func save(_ jobs: [UploadJob]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(
                to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            AUNLog.studio.error("Saving the upload queue failed: \(error)")
        }
    }
}
