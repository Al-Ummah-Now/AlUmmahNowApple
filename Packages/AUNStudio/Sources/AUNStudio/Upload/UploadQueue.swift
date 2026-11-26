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
///
/// A file with `preEncode` (desktop Studio, D11) also encodes the server's renditions on this computer while its bytes
/// upload. Only the final complete waits for that, and the creator can skip the wait; whatever happens to it, the
/// upload carries on and the server encodes as usual.
@MainActor @Observable
public final class UploadQueue {
    public internal(set) var jobs: [UploadJob]
    public private(set) var isRunning = false

    private let studio: any StudioServicing
    private let transfer: any TUSTransferring
    let store: UploadStore
    let defaults: UserDefaults
    private let maxParallel: Int
    /// A byte transfer step (token, offset, create, one chunk) with no sign of life this long has stalled (Apple #105).
    private let stallLimit: Duration
    /// A stalled chunk is asked for again once; a second stall stops the job.
    private static let stallRetries = 1
    var tasks: [UUID: Task<Void, Never>] = [:]
    private let preEncoder: PreEncoder?
    private let encoderName: String
    var preEncodeTasks: [UUID: Task<Void, Never>] = [:]
    /// The account each running task belongs to, also once its job is off the list.
    var taskAccounts: [UUID: String] = [:]
    /// Accounts whose uploads stand still while they are being deleted, or while another account signs in for that.
    var heldAccounts: Set<String> = []
    /// Accounts whose uploads were dropped: none of theirs is taken or written back.
    var purgedAccounts: Set<String> = []
    static let pendingPurgesKey = "AUNStudioPendingUploadPurges"
    /// Every queue of this process: on the Mac each window has its own, on one saved file.
    static let queues = NSHashTable<UploadQueue>.weakObjects()
    /// When this process started, near enough: touched by the first queue.
    static let started = Date()
    /// Only jobs of this account run; the token belongs to the active account.
    public var accountID: String? {
        didSet {
            guard accountID != oldValue else { return }
            blockedByTerms = false
            // A running upload belongs to its own account: stop the ones of any other account now, so none of them
            // asks for a token (or retries a chunk) as the account that just became active.
            for job in jobs where job.accountID != accountID { tasks[job.id]?.cancel() }
            kick()
        }
    }
    /// Called when the server refuses for the whole account (pending deletion, ban). The queue pauses rather than
    /// fails its jobs, and runs nothing until `unblock()`.
    var onAccountState: ((Refusal) -> Void)?
    /// Called when the server says uploads are off for the account (`feature_off`, 402, no creator tier). The job is
    /// dropped without a message and Studio reads its features again, which hides the Upload tab.
    var onFeatureOff: (() -> Void)?
    /// Called when an upload fails with `403 terms_required`, carrying the job's account ID so a late response from a
    /// previous account never gates the newly active account.
    var onTermsRequired: ((String) -> Void)?
    private(set) var isBlocked = false
    private var blockedByTerms = false
    /// How often each upload was resumed by itself after `403 terms_required`, while the server called the Terms accepted.
    var termsResumes: [UUID: Int] = [:]
    private static let maxTermsResumes = 2

    init(
        studio: any StudioServicing, transfer: any TUSTransferring, store: UploadStore, maxParallel: Int = 2,
        preEncoder: PreEncoder? = nil, encoderName: String = PreEncoder.encoderName(),
        stallLimit: Duration = .seconds(60), defaults: UserDefaults = .standard
    ) {
        self.stallLimit = stallLimit
        self.studio = studio
        self.transfer = transfer
        self.store = store
        self.defaults = defaults
        self.maxParallel = maxParallel
        self.preEncoder = preEncoder
        self.encoderName = encoderName
        purgedAccounts = Set(defaults.stringArray(forKey: Self.pendingPurgesKey) ?? [])
        jobs = store.load().map(Self.restarted)
        // Finish what an app that was killed, or a file that could not be removed, left of a purge.
        for id in purgedAccounts { removeJobs(of: id) }
        Self.queues.add(self)
        _ = Self.started
        transfer.onOrphanCompletion = { [weak self] in Task { @MainActor in self?.kick() } }
    }

    convenience init(services: StudioServices, defaults: UserDefaults = .standard) {
        let store =
            services.persistsUploads
            ? UploadStore.live()
            : UploadStore(url: FileManager.default.temporaryDirectory.appending(path: "studio-uploads-\(UUID().uuidString).json"))
        let preEncoder = services.renditionPackaging.map {
            PreEncoder(packaging: $0, renditions: services.renditions, workRoot: PreEncoder.defaultWorkRoot)
        }
        self.init(
            studio: services.studio, transfer: services.transfer, store: store, preEncoder: preEncoder,
            stallLimit: Self.fixtureStallLimit(services) ?? .seconds(60), defaults: defaults)
    }

    /// UI tests shorten the stall limit (`-AUNUploadStallSeconds 3`) to show a stalled upload without a minute's wait. Only
    /// in a debug build, and only on fixtures (they never persist uploads); a release build ignores it.
    private static func fixtureStallLimit(_ services: StudioServices) -> Duration? {
        #if DEBUG
            guard !services.persistsUploads else { return nil }
            let seconds = UserDefaults.standard.double(forKey: "AUNUploadStallSeconds")
            return seconds > 0 ? .seconds(seconds) : nil
        #else
            return nil
        #endif
    }

    /// True when this build can pre-encode renditions (desktop Studio with Core's packaging).
    public var canPreEncode: Bool { preEncoder != nil }

    // MARK: Queue changes

    public func enqueue(_ new: [UploadJob]) {
        var accepted: [UploadJob] = []
        for job in new {
            if purgedAccounts.contains(job.accountID) {
                // The account is gone from this device: its staged copy must not stay on disk.
                if job.ownsFile { try? FileManager.default.removeItem(at: job.file) }
                continue
            }
            accepted.append(job)
        }
        guard !accepted.isEmpty else { return }
        jobs += accepted
        save()
        kick()
    }

    public func pause(_ id: UUID) {
        tasks[id]?.cancel()
        preEncodeTasks[id]?.cancel()
        update(id) { $0.state = .paused }
    }

    public func resume(_ id: UUID) {
        termsResumes[id] = nil
        update(id) {
            $0.state = .waiting
            $0.failure = nil
        }
        kick()
    }

    /// Removes a job from the list. A started upload stays on the server as an unfinished video.
    public func remove(_ id: UUID) {
        tasks[id]?.cancel()
        preEncodeTasks[id]?.cancel()
        if let job = jobs.first(where: { $0.id == id }), job.ownsFile { try? FileManager.default.removeItem(at: job.file) }
        jobs.removeAll { $0.id == id }
        termsResumes[id] = nil
        save()
    }

    /// The account may write again (an admin restored it): resume the jobs the refusal paused.
    func unblock() {
        guard isBlocked else { return }
        isBlocked = false
        blockedByTerms = false
        for job in jobs where job.state == .paused && job.failure == Self.accountStateKey {
            update(job.id) {
                $0.state = .waiting
                $0.failure = nil
            }
        }
        kick()
    }

    static let accountStateKey = "studio.account.pendingDeletion"
    static let termsRequiredKey = "studio.terms.title"

    /// Starts as many waiting jobs of the active account as the parallel limit allows.
    public func kick() {
        guard let accountID, !isBlocked, !heldAccounts.contains(accountID) else { return }
        let running = jobs.filter { tasks[$0.id] != nil }.count
        let ready = jobs.filter { $0.state == .waiting && $0.accountID == accountID && tasks[$0.id] == nil }
        for job in ready.prefix(max(0, maxParallel - running)) {
            let id = job.id
            taskAccounts[id] = job.accountID
            tasks[id] = Task { [weak self] in
                await self?.run(id)
                self?.tasks[id] = nil
                self?.taskAccounts[id] = nil
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
        guard let job = job(id), !heldAccounts.contains(job.accountID) else { return }
        let scoped = job.bookmark.flatMap(Self.resolve) ?? job.file
        let accessing = scoped.startAccessingSecurityScopedResource()
        defer { if accessing { scoped.stopAccessingSecurityScopedResource() } }
        // However the run ends, a pre-encode still going stops with it (it is never resumed).
        defer { preEncodeTasks[id]?.cancel() }
        do {
            let ticket = try await prepare(id)
            startPreEncode(id, ticket: ticket, file: scoped)
            try await transmit(id, ticket: ticket, file: scoped)
            try await publish(id, ticket: ticket)
            update(id) {
                $0.state = .done
                $0.failure = nil
            }
            termsResumes[id] = nil
            if job.ownsFile { try? FileManager.default.removeItem(at: job.file) }
        } catch {
            handleRunFailure(error, for: job)
        }
    }

    private func putBack(_ id: UUID) {
        update(id) {
            $0.inFlight = 0
            if $0.state != .paused { $0.state = .waiting }
        }
    }

    /// Between two requests of a job: goes no further once its account is held.
    private func checkHeld(_ id: UUID) throws {
        try Task.checkCancellation()
        if let account = taskAccounts[id], heldAccounts.contains(account) { throw CancellationError() }
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
        try checkHeld(id)
        guard let ticket = job.ticket else { throw CancellationError() }
        if let language = job.settings.language, !job.languageSet {
            try await studio.setLanguage(language, videoID: ticket.videoID, channelID: job.channelID)
            update(id) { $0.languageSet = true }
        }
        try checkHeld(id)
        if !job.settings.playlistIDs.isEmpty, !job.playlistsQueued {
            try await studio.addToPlaylists(
                job.settings.playlistIDs, videoID: ticket.videoID, orderKey: job.orderKey, channelID: job.channelID)
            update(id) { $0.playlistsQueued = true }
        }
        try checkHeld(id)
        return ticket
    }

    /// The bytes, then complete (once).
    private func transmit(_ id: UUID, ticket: UploadTicket, file: URL) async throws {
        guard let job = job(id), !job.completed else { return }
        update(id) { $0.state = .uploading }
        try await sendBytes(id, file: file)
        update(id) { $0.state = .finishing }
        // The renditions must be complete before the original is, or the server has already encoded.
        await waitForPreEncode(id)
        try checkHeld(id)
        try await studio.completeUpload(videoID: ticket.videoID, fileSize: job.fileSize, channelID: job.channelID)
        update(id) { $0.completed = true }
    }

    // MARK: Pre-encoded renditions (D11)

    /// Starts encoding the file's renditions alongside its upload, once per file.
    private func startPreEncode(_ id: UUID, ticket: UploadTicket, file: URL) {
        guard let preEncoder, let job = job(id), job.settings.preEncode, job.preEncode == nil, !job.completed,
            preEncodeTasks[id] == nil
        else { return }
        update(id) {
            $0.preEncode = .running
            $0.preEncodeFraction = 0
            $0.preEncodeRung = nil
        }
        let channelID = job.channelID
        let encoder = encoderName
        preEncodeTasks[id] = Task { [weak self] in
            let outcome = await preEncoder.run(
                source: file, videoID: ticket.videoID, channelID: channelID, encoder: encoder
            ) { [weak self] status in
                await self?.update(id, save: false) {
                    $0.preEncodeFraction = status.fraction
                    if case .encoding(let rung, _, _) = status.phase { $0.preEncodeRung = rung }
                    if status.phase == .uploading { $0.preEncodeRung = nil }
                }
            }
            self?.finishPreEncode(id, outcome)
        }
    }

    private func finishPreEncode(_ id: UUID, _ outcome: RenditionUploader.Outcome) {
        preEncodeTasks[id] = nil
        update(id) {
            $0.preEncode = Self.preEncodeState(outcome)
            $0.preEncodeRung = nil
            if outcome == .ready { $0.preEncodeFraction = 1 }
        }
    }

    static func preEncodeState(_ outcome: RenditionUploader.Outcome) -> UploadJob.PreEncodeState {
        switch outcome {
        case .ready: .ready
        case .tooLate, .cancelled: .skipped
        case .failed: .failed
        }
    }

    /// Waits for a running pre-encode; cancelling the upload cancels it too.
    private func waitForPreEncode(_ id: UUID) async {
        guard let task = preEncodeTasks[id] else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Stops pre-encoding a file; its upload continues at once and the server encodes it.
    public func skipPreEncode(_ id: UUID) {
        preEncodeTasks[id]?.cancel()
    }

    /// The publish time, when the batch is scheduled (once).
    private func publish(_ id: UUID, ticket: UploadTicket) async throws {
        guard let job = job(id), let date = job.scheduleDate, !job.scheduled else { return }
        try checkHeld(id)
        try await studio.schedule(videoID: ticket.videoID, at: date, timeZone: .current, channelID: job.channelID)
        update(id) { $0.scheduled = true }
    }

    /// The TUS upload URL and how much the server has: the saved upload, the reused one, or a new one.
    private func locate(_ id: UUID, endpoint: URL, headers: [String: String]) async throws -> (URL, Int64) {
        guard var job = job(id), var ticket = job.ticket else { throw CancellationError() }
        let transfer = self.transfer
        var location = job.uploadURL
        if location == nil, let reused = ticket.tusUploadID { location = endpoint.appending(path: reused) }
        if let known = location {
            do {
                return (
                    known, try await guardedByStall(limit: stallLimit) { try await transfer.offset(of: known, headers: headers) }
                )
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
        let size = job.fileSize
        let metadata = [
            "tusSessionId": ticket.tusSessionID, "videoId": ticket.videoID, "filename": job.fileName,
            "filetype": job.mimeType,
        ]
        let created = try await guardedByStall(limit: stallLimit) {
            try await transfer.create(endpoint: endpoint, headers: headers, size: size, metadata: metadata)
        }
        update(id) { $0.uploadURL = created }
        return (created, 0)
    }

    /// The upload endpoint and the token of the job's own account, under the stall guard. It refuses (cancels) when
    /// another account has become the active one: that token is not this job's.
    private func endpoint(for id: UUID) async throws -> (url: URL, headers: [String: String]) {
        guard let job = job(id), job.accountID == accountID else { throw CancellationError() }
        let studio = self.studio
        return try await guardedByStall(limit: stallLimit) { try await studio.tusEndpoint() }
    }

    /// Sends the bytes the server does not have yet, one chunk file at a time.
    private func sendBytes(_ id: UUID, file: URL) async throws {
        guard let job = job(id), let ticket = job.ticket else { return }
        let transfer = self.transfer
        var (endpoint, headers) = try await self.endpoint(for: id)
        let (location, start) = try await locate(id, endpoint: endpoint, headers: headers)
        var offset = start
        update(id) { $0.offset = offset }

        let chunkSize = Int64(max(1 << 20, min(self.job(id)?.ticket?.chunkSize ?? ticket.chunkSize, 90 << 20)))
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let chunkFile = FileManager.default.temporaryDirectory.appending(path: "studio-chunk-\(id.uuidString)")
        defer { try? FileManager.default.removeItem(at: chunkFile) }
        var attempts = 0
        var stalls = 0
        while offset < job.fileSize {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: Int(min(chunkSize, job.fileSize - offset))) ?? Data()
            guard !data.isEmpty else { throw CoreError.upload("file ended early") }
            try data.write(to: chunkFile, options: .atomic)
            do {
                let start = offset
                let activity = UploadActivity()
                let sendHeaders = headers
                offset = try await guardedByStall(limit: stallLimit, activity: activity) {
                    try await transfer.send(chunk: chunkFile, to: location, offset: start, headers: sendHeaders) {
                        [weak self] sent in
                        activity.touch()
                        Task { @MainActor in self?.update(id, save: false) { $0.inFlight = sent } }
                    }
                }
                attempts = 0
                stalls = 0
                update(id) {
                    $0.offset = offset
                    $0.inFlight = 0
                }
            } catch let error as CoreError where error == .signInRequired && attempts == 0 {
                attempts += 1
                (endpoint, headers) = try await self.endpoint(for: id)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CoreError where error.refusal != nil {
                throw error
            } catch is UploadStalled {
                // Nothing moved for the whole limit: ask the server where it is and send the chunk again, once.
                stalls += 1
                guard stalls <= Self.stallRetries else { throw UploadStalled() }
                (endpoint, headers) = try await self.endpoint(for: id)
                let current = headers
                // The chunk may have landed before the silence: take the server's offset, and save it. An offset that
                // stalls too, or a session that is gone (404), ends the job here; Retry opens the upload again.
                offset = try await guardedByStall(limit: stallLimit) { try await transfer.offset(of: location, headers: current) }
                update(id) {
                    $0.offset = offset
                    $0.inFlight = 0
                }
            } catch {
                attempts += 1
                guard attempts <= 4 else { throw error }
                try await Task.sleep(for: .seconds(Double(attempts * attempts)))
                (endpoint, headers) = try await self.endpoint(for: id)
                let current = headers
                offset =
                    (try? await guardedByStall(limit: stallLimit) { try await transfer.offset(of: location, headers: current) })
                    ?? offset
                update(id) { $0.inFlight = 0 }
            }
        }
    }
}

extension UploadQueue {
    /// A saved job as a new start finds it.
    static func restarted(_ saved: UploadJob) -> UploadJob {
        var job = saved
        if job.isActive { job.state = .waiting }
        job.inFlight = 0
        // A pre-encode cut short by a relaunch is not resumed: the server encodes that file.
        if job.preEncode == .running { job.preEncode = .skipped }
        return job
    }

    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        #if os(macOS)
            return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        #else
            return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        #endif
    }

    /// The job's failure text, or nil when uploads are off for the account (nothing is said; the tab goes away).
    static func failureKey(_ error: any Error) -> String? {
        if error is UploadStalled { return "studio.upload.error.stalled" }
        if let core = error as? CoreError, core.hidesEntryPoint { return nil }
        if let refusal = (error as? CoreError)?.refusal { return StudioFailure.refusalMessage(refusal) }
        return switch error as? CoreError {
        case .offline: "studio.error.offline"
        case .signInRequired: "studio.error.signIn"
        case .forbidden: "studio.upload.error.forbidden"
        case .http(let status) where status == 429: "studio.upload.error.limit"
        case .invalid: "studio.upload.error.invalid"
        default: "studio.upload.error.generic"
        }
    }

    public func clearFinished() {
        for job in jobs where job.state == .done && job.ownsFile { try? FileManager.default.removeItem(at: job.file) }
        jobs.removeAll { $0.state == .done }
        save()
    }
}

extension UploadQueue {
    /// Resumes the uploads of `targetAccountID` that `403 terms_required` paused, and only those. `automatic` (the server
    /// calls the Terms accepted although it refused the upload) resumes each upload `maxTermsResumes` times at most.
    /// Returns whether none of them stays paused.
    @discardableResult
    func unblockTerms(forAccount targetAccountID: String, automatic: Bool = false) -> Bool {
        let paused = jobs.filter {
            $0.accountID == targetAccountID && $0.state == .paused && $0.failure == Self.termsRequiredKey
        }
        if !automatic { for job in jobs where job.accountID == targetAccountID { termsResumes[job.id] = nil } }
        let ready = automatic ? paused.filter { termsResumes[$0.id, default: 0] < Self.maxTermsResumes } : paused
        guard !ready.isEmpty || (paused.isEmpty && blockedByTerms && accountID == targetAccountID) else { return paused.isEmpty }
        if accountID == targetAccountID {
            blockedByTerms = false
            if !jobs.contains(where: {
                $0.accountID == targetAccountID && $0.state == .paused && $0.failure == Self.accountStateKey
            }) {
                isBlocked = false
            }
        }
        for job in ready {
            if automatic { termsResumes[job.id, default: 0] += 1 }
            update(job.id) {
                $0.state = .waiting
                $0.failure = nil
            }
        }
        kick()
        return ready.count == paused.count
    }

    func handleRunFailure(_ error: Error, for job: UploadJob) {
        let id = job.id
        // A request that was cancelled under it says so in its own words.
        if error is CancellationError || Task.isCancelled { return putBack(id) }
        if let coreError = error as? CoreError, coreError.refusal?.code == Refusal.termsRequired {
            // Pause the job cleanly and reopen the Creator Terms gate for its account; accepting resumes it via `unblockTerms()`.
            if job.accountID == accountID {
                isBlocked = true
                blockedByTerms = true
            }
            update(id) {
                $0.state = .paused
                $0.inFlight = 0
                $0.failure = Self.termsRequiredKey
            }
            onTermsRequired?(job.accountID)
            return
        }
        if let coreError = error as? CoreError, let refusal = coreError.refusal, refusal.isAccountState {
            // Not a failure of this file: pause it, keep its progress, and wait for the account to be restored.
            isBlocked = true
            update(id) {
                $0.state = .paused
                $0.inFlight = 0
                $0.failure = Self.accountStateKey
            }
            onAccountState?(refusal)
            return
        }
        AUNLog.studio.error("Upload \(id, privacy: .public) failed: \(error)")
        guard let key = Self.failureKey(error) else {
            remove(id)
            onFeatureOff?()
            return
        }
        update(id) {
            $0.state = .failed
            $0.inFlight = 0
            $0.failure = key
        }
    }
}
