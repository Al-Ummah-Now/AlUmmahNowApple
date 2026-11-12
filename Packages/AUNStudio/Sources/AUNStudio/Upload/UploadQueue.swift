import AUNCoreBridge
import Foundation
import Observation

#if canImport(UIKit)
    import UIKit
#endif

/// Uploads Studio files one step at a time, two at once, and resumes them after a relaunch.
///
/// Steps per file: initiate → language and playlists → TUS chunks through the api-videos proxy → complete →
/// schedule. Every step is saved, so a later run continues from the first step not done.
@MainActor @Observable
public final class UploadQueue {
    public private(set) var jobs: [UploadJob]
    public private(set) var isRunning = false

    private let studio: any StudioServicing
    private let transfer: any TUSTransferring
    private let store: UploadStore
    private let maxParallel: Int
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Only jobs of this account run; the token belongs to the active account.
    public var accountID: String? {
        didSet { if accountID != oldValue { kick() } }
    }
    /// Called when the server refuses for the whole account (pending deletion, ban). The queue pauses rather than
    /// fails its jobs, and runs nothing until `unblock()`.
    var onAccountState: ((Refusal) -> Void)?
    private(set) var isBlocked = false

    init(studio: any StudioServicing, transfer: any TUSTransferring, store: UploadStore, maxParallel: Int = 2) {
        self.studio = studio
        self.transfer = transfer
        self.store = store
        self.maxParallel = maxParallel
        jobs = store.load().map { job in
            var job = job
            if job.isActive { job.state = .waiting }
            job.inFlight = 0
            return job
        }
        transfer.onOrphanCompletion = { [weak self] in Task { @MainActor in self?.kick() } }
    }

    convenience init(services: StudioServices) {
        let store =
            services.persistsUploads
            ? UploadStore.live()
            : UploadStore(url: FileManager.default.temporaryDirectory.appending(path: "studio-uploads-\(UUID().uuidString).json"))
        self.init(studio: services.studio, transfer: services.transfer, store: store)
    }

    // MARK: Queue changes

    public func enqueue(_ new: [UploadJob]) {
        jobs += new
        save()
        kick()
    }

    public func pause(_ id: UUID) {
        tasks[id]?.cancel()
        update(id) { $0.state = .paused }
    }

    public func resume(_ id: UUID) {
        update(id) {
            $0.state = .waiting
            $0.failure = nil
        }
        kick()
    }

    /// Removes a job from the list. A started upload stays on the server as an unfinished video.
    public func remove(_ id: UUID) {
        tasks[id]?.cancel()
        if let job = jobs.first(where: { $0.id == id }), job.ownsFile { try? FileManager.default.removeItem(at: job.file) }
        jobs.removeAll { $0.id == id }
        save()
    }

    /// Drops the uploads of an account that signed out of this device; they cannot continue without it.
    public func discardJobs(of accountID: String) {
        for job in jobs where job.accountID == accountID {
            tasks[job.id]?.cancel()
            if job.ownsFile { try? FileManager.default.removeItem(at: job.file) }
        }
        jobs.removeAll { $0.accountID == accountID }
        save()
    }

    public func clearFinished() {
        for job in jobs where job.state == .done && job.ownsFile { try? FileManager.default.removeItem(at: job.file) }
        jobs.removeAll { $0.state == .done }
        save()
    }

    /// The account may write again (an admin restored it): resume the jobs the refusal paused.
    func unblock() {
        guard isBlocked else { return }
        isBlocked = false
        for job in jobs where job.state == .paused && job.failure == Self.accountStateKey {
            update(job.id) {
                $0.state = .waiting
                $0.failure = nil
            }
        }
        kick()
    }

    static let accountStateKey = "studio.account.pendingDeletion"

    /// Starts as many waiting jobs of the active account as the parallel limit allows.
    public func kick() {
        guard let accountID, !isBlocked else { return }
        let running = jobs.filter { tasks[$0.id] != nil }.count
        let ready = jobs.filter { $0.state == .waiting && $0.accountID == accountID && tasks[$0.id] == nil }
        for job in ready.prefix(max(0, maxParallel - running)) {
            let id = job.id
            tasks[id] = Task { [weak self] in
                await self?.run(id)
                self?.tasks[id] = nil
                self?.kick()
            }
        }
        isRunning = !tasks.isEmpty
    }

    // MARK: Running a job

    private func job(_ id: UUID) -> UploadJob? { jobs.first { $0.id == id } }

    private func update(_ id: UUID, save persist: Bool = true, _ change: (inout UploadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        if persist { save() }
    }

    private func save() { store.save(jobs) }

    private func run(_ id: UUID) async {
        #if canImport(UIKit)
            let background = UIApplication.shared.beginBackgroundTask(withName: "studio-upload")
            defer { UIApplication.shared.endBackgroundTask(background) }
        #endif
        guard let job = job(id) else { return }
        let scoped = job.bookmark.flatMap(Self.resolve) ?? job.file
        let accessing = scoped.startAccessingSecurityScopedResource()
        defer { if accessing { scoped.stopAccessingSecurityScopedResource() } }
        do {
            let ticket = try await prepare(id)
            try await transmit(id, ticket: ticket, file: scoped)
            try await publish(id, ticket: ticket)
            update(id) {
                $0.state = .done
                $0.failure = nil
            }
            if job.ownsFile { try? FileManager.default.removeItem(at: job.file) }
        } catch is CancellationError {
            update(id) { if $0.state != .paused { $0.state = .waiting } }
        } catch let error as CoreError where error.refusal?.isAccountState == true {
            // Not a failure of this file: pause it, keep its progress, and wait for the account to be restored.
            isBlocked = true
            update(id) {
                $0.state = .paused
                $0.inFlight = 0
                $0.failure = Self.accountStateKey
            }
            if let refusal = error.refusal { onAccountState?(refusal) }
        } catch {
            AUNLog.studio.error("Upload \(id, privacy: .public) failed: \(error)")
            update(id) {
                $0.state = .failed
                $0.inFlight = 0
                $0.failure = Self.failureKey(error)
            }
        }
    }

    /// Initiate (once), then the language and playlists that initiate does not take.
    private func prepare(_ id: UUID) async throws -> UploadTicket {
        update(id) { $0.state = .preparing }
        guard var job = job(id) else { throw CancellationError() }
        if job.ticket == nil {
            let ticket = try await studio.initiateUpload(job.initiation, channelID: job.channelID)
            update(id) { $0.ticket = ticket }
            job.ticket = ticket
        }
        guard let ticket = job.ticket else { throw CancellationError() }
        if let language = job.settings.language, !job.languageSet {
            try await studio.setLanguage(language, videoID: ticket.videoID, channelID: job.channelID)
            update(id) { $0.languageSet = true }
        }
        if !job.settings.playlistIDs.isEmpty, !job.playlistsQueued {
            try await studio.addToPlaylists(
                job.settings.playlistIDs, videoID: ticket.videoID, orderKey: job.orderKey, channelID: job.channelID)
            update(id) { $0.playlistsQueued = true }
        }
        return ticket
    }

    /// The bytes, then complete (once).
    private func transmit(_ id: UUID, ticket: UploadTicket, file: URL) async throws {
        guard let job = job(id), !job.completed else { return }
        update(id) { $0.state = .uploading }
        try await sendBytes(id, file: file)
        update(id) { $0.state = .finishing }
        try await studio.completeUpload(videoID: ticket.videoID, fileSize: job.fileSize, channelID: job.channelID)
        update(id) { $0.completed = true }
    }

    /// The publish time, when the batch is scheduled (once).
    private func publish(_ id: UUID, ticket: UploadTicket) async throws {
        guard let job = job(id), let date = job.scheduleDate, !job.scheduled else { return }
        try await studio.schedule(videoID: ticket.videoID, at: date, timeZone: .current, channelID: job.channelID)
        update(id) { $0.scheduled = true }
    }

    /// The TUS upload URL and how much the server has: the saved upload, the reused one, or a new one.
    private func locate(_ id: UUID, endpoint: URL, headers: [String: String]) async throws -> (URL, Int64) {
        guard var job = job(id), var ticket = job.ticket else { throw CancellationError() }
        var location = job.uploadURL
        if location == nil, let reused = ticket.tusUploadID { location = endpoint.appending(path: reused) }
        if let known = location {
            do {
                return (known, try await transfer.offset(of: known, headers: headers))
            } catch CoreError.notFound {
                // The proxy session expired: ask for a new one and start a new TUS upload.
                ticket = try await studio.resumeUpload(videoID: ticket.videoID, channelID: job.channelID)
                let fresh = ticket
                update(id) {
                    $0.ticket = fresh
                    $0.uploadURL = nil
                }
                job.ticket = ticket
            }
        }
        let created = try await transfer.create(
            endpoint: endpoint, headers: headers, size: job.fileSize,
            metadata: [
                "tusSessionId": ticket.tusSessionID, "videoId": ticket.videoID, "filename": job.fileName,
                "filetype": job.mimeType,
            ])
        update(id) { $0.uploadURL = created }
        return (created, 0)
    }

    /// Sends the bytes the server does not have yet, one chunk file at a time.
    private func sendBytes(_ id: UUID, file: URL) async throws {
        guard let job = job(id), let ticket = job.ticket else { return }
        var (endpoint, headers) = try await studio.tusEndpoint()
        let (location, start) = try await locate(id, endpoint: endpoint, headers: headers)
        var offset = start
        update(id) { $0.offset = offset }

        let chunkSize = Int64(max(1 << 20, min(self.job(id)?.ticket?.chunkSize ?? ticket.chunkSize, 90 << 20)))
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let chunkFile = FileManager.default.temporaryDirectory.appending(path: "studio-chunk-\(id.uuidString)")
        defer { try? FileManager.default.removeItem(at: chunkFile) }
        var attempts = 0
        while offset < job.fileSize {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: Int(min(chunkSize, job.fileSize - offset))) ?? Data()
            guard !data.isEmpty else { throw CoreError.upload("file ended early") }
            try data.write(to: chunkFile, options: .atomic)
            do {
                let start = offset
                offset = try await transfer.send(chunk: chunkFile, to: location, offset: start, headers: headers) {
                    [weak self] sent in
                    Task { @MainActor in self?.update(id, save: false) { $0.inFlight = sent } }
                }
                attempts = 0
                update(id) {
                    $0.offset = offset
                    $0.inFlight = 0
                }
            } catch let error as CoreError where error == .signInRequired && attempts == 0 {
                attempts += 1
                (endpoint, headers) = try await studio.tusEndpoint()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CoreError where error.refusal != nil {
                throw error
            } catch {
                attempts += 1
                guard attempts <= 4 else { throw error }
                try await Task.sleep(for: .seconds(Double(attempts * attempts)))
                (endpoint, headers) = try await studio.tusEndpoint()
                offset = (try? await transfer.offset(of: location, headers: headers)) ?? offset
                update(id) { $0.inFlight = 0 }
            }
        }
    }

    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        #if os(macOS)
            return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        #else
            return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        #endif
    }

    static func failureKey(_ error: any Error) -> String {
        if let refusal = (error as? CoreError)?.refusal {
            return refusal.code == Refusal.upgradeRequired ? "studio.content.limit" : StudioFailure.refusalMessage(refusal).key
        }
        return switch error as? CoreError {
        case .offline: "studio.error.offline"
        case .signInRequired: "studio.error.signIn"
        case .forbidden: "studio.upload.error.forbidden"
        case .http(let status) where status == 429 || status == 402: "studio.upload.error.limit"
        case .invalid: "studio.upload.error.invalid"
        default: "studio.upload.error.generic"
        }
    }
}
