import AUNCoreBridge
import Foundation

extension UploadQueue {
    // MARK: Holding and purging an account's uploads

    /// Thrown when an account's uploads did not stand still in time.
    struct NotHeld: Error {}

    /// Holds the uploads of an account, in every window, and returns once nothing of them is under way. Bytes on the wire
    /// are cut (they resume); a step the server may already be acting on (initiate, complete, schedule) gets its answer.
    func hold(_ accountID: String, within limit: Duration = .seconds(90)) async throws {
        let peers = self.peers
        for queue in peers { queue.stop(accountID) }
        let deadline = ContinuousClock.now + limit
        while peers.contains(where: { $0.isUnderWay(accountID) }) {
            guard ContinuousClock.now < deadline else {
                release(accountID)
                throw NotHeld()
            }
            try? await Task.sleep(for: .milliseconds(25))
            // A pre-encode or a chunk that started while a step was waited for.
            for queue in peers { queue.stop(accountID) }
        }
    }

    /// Lets the account's uploads go on, in every window.
    func release(_ accountID: String) {
        for queue in peers where queue.heldAccounts.remove(accountID) != nil { queue.kick() }
    }

    private var peers: [UploadQueue] {
        let others = Self.queues.allObjects.filter { $0 !== self && $0.store.url == store.url }
        return [self] + others
    }

    private func stop(_ accountID: String) {
        heldAccounts.insert(accountID)
        for job in jobs where job.accountID == accountID {
            preEncodeTasks[job.id]?.cancel()
            if job.state == .uploading { tasks[job.id]?.cancel() }
        }
    }

    private func isUnderWay(_ accountID: String) -> Bool {
        taskAccounts.values.contains(accountID)
            || jobs.contains { $0.accountID == accountID && preEncodeTasks[$0.id] != nil }
    }

    /// Drops the uploads of an account that signed out on this device. A file that can't be removed is tried again at the
    /// next start.
    @discardableResult
    public func discardJobs(of accountID: String) -> Bool {
        mark(accountID)
        guard removeJobs(of: accountID) else { return false }
        unmark(accountID)
        return true
    }

    /// Drops the uploads of a deleted account in every window, and keeps the mark: an upload that was still running, or
    /// another window, can't write one back. Throws when something of them is left.
    func purgeJobs(of accountID: String) throws {
        var clean = true
        for queue in peers {
            queue.mark(accountID)
            if !queue.removeJobs(of: accountID) { clean = false }
        }
        removeForgottenCopies()
        guard clean else { throw CoreError.upload("staged files left") }
    }

    /// The account signed in again: its uploads are taken again.
    public func clearPendingPurge(for accountID: String) {
        for queue in peers { queue.unmark(accountID) }
    }

    private func mark(_ accountID: String) {
        purgedAccounts.insert(accountID)
        savePurged()
    }

    private func unmark(_ accountID: String) {
        guard purgedAccounts.remove(accountID) != nil else { return }
        savePurged()
    }

    private func savePurged() { defaults.set(purgedAccounts.sorted(), forKey: Self.pendingPurgesKey) }

    /// Removes the account's jobs and staged files, from this window's list and from the saved queue as it is now: other
    /// windows, also ones closed since, keep theirs. False when a staged file or the saved queue could not be changed.
    @discardableResult
    func removeJobs(of accountID: String) -> Bool {
        let saved: [UploadJob]
        do {
            saved = try store.read()
        } catch {
            AUNLog.studio.error("The saved upload queue can't be read: \(error)")
            return false
        }
        for job in jobs where job.accountID == accountID {
            tasks[job.id]?.cancel()
            preEncodeTasks[job.id]?.cancel()
        }
        let mine = jobs.filter { $0.accountID == accountID }
        let theirs = saved.filter { job in job.accountID == accountID && !mine.contains { $0.id == job.id } }
        let left = Set((mine + theirs).filter { !Self.removeCopy(of: $0) }.map(\.id))
        // A file that can't be removed keeps its job, so the next start finds it again.
        jobs.removeAll { $0.accountID == accountID && !left.contains($0.id) }
        termsResumes = termsResumes.filter { id, _ in jobs.contains { $0.id == id } }
        let kept = saved.filter { $0.accountID != accountID || left.contains($0.id) }
        let written = kept.count == saved.count || store.save(kept)
        takeOver(kept)
        return written && left.isEmpty
    }

    /// Jobs of a window that was closed: this one goes on with them, so its next save keeps them too.
    private func takeOver(_ saved: [UploadJob]) {
        let known = Set(peers.flatMap { $0.jobs.map(\.id) })
        jobs += saved.filter { !known.contains($0.id) && !purgedAccounts.contains($0.accountID) }.map(Self.restarted)
    }

    private static func removeCopy(of job: UploadJob) -> Bool {
        guard job.ownsFile, FileManager.default.fileExists(atPath: job.file.path) else { return true }
        do {
            try FileManager.default.removeItem(at: job.file)
            return true
        } catch {
            AUNLog.studio.error(
                "Failed removing staged upload file \(job.file.lastPathComponent, privacy: .public): \(error)")
            return false
        }
    }

    /// Copies from before this start that no queued upload and no form has: picked, and never sent. Whose they were is not
    /// known any more, and nobody can send them.
    private func removeForgottenCopies() {
        guard let saved = try? store.read() else { return }
        let wanted = (saved + jobs).map(\.file) + UploadComposer.pickedFiles
        let folders =
            (try? FileManager.default.contentsOfDirectory(at: store.copies, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            let made = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let path = folder.standardizedFileURL.path
            guard made < Self.started, !wanted.contains(where: { $0.standardizedFileURL.path.hasPrefix(path) }) else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
