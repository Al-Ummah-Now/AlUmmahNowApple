import AUNCoreBridge
import Foundation

/// Where a load stands. A spinner shows only while `loading`; every load ends in content (`ready`), a plain empty
/// state (`empty`), a section that is not shown (`hidden`) or an error with Retry (`failed`). Never a spinner forever.
enum LoadPhase: Equatable, Sendable {
    /// Nothing asked for yet (or the only load was cancelled): nothing to draw, the next appearance loads.
    case idle
    case loading
    case ready
    case empty
    /// The feature is off for this person (`feature_off`, 402, a tier refusal) or the section is not theirs to see
    /// (403): it disappears, with no text.
    case hidden
    case failed

    var isLoading: Bool { self == .loading }

    /// A load that answered: content, or the empty state.
    static func loaded(isEmpty: Bool) -> LoadPhase { isEmpty ? .empty : .ready }

    /// A load that threw, from the phase it started in. Content already shown stays shown: only a cancellation, an
    /// error or a missing route ends without replacing it.
    static func after(_ error: any Error, from previous: LoadPhase) -> LoadPhase {
        let hadContent = previous == .ready || previous == .empty
        if error is CancellationError || (error as? CoreError) == .cancelled {
            return hadContent ? previous : .idle
        }
        switch error as? CoreError {
        case .some(let core) where core.hidesEntryPoint: return .hidden
        case .forbidden: return .hidden
        case .notFound: return hadContent ? previous : .empty
        default: return hadContent ? previous : .failed
        }
    }

    /// Runs one load: `loading` while it runs, then the phase it ends in.
    @MainActor
    static func run(from previous: LoadPhase, set: (LoadPhase) -> Void, _ load: () async throws -> Bool) async {
        set(.loading)
        do {
            set(.loaded(isEmpty: try await load()))
        } catch {
            if !(error is CancellationError) { AUNLog.studio.error("Load failed: \(error)") }
            set(after(error, from: previous))
        }
    }
}
