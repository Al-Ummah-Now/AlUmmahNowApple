import Foundation

/// Undo and redo over whole snapshots (the editor keeps project JSON, the caption editor its cues). Bounded, so a long
/// session never grows without limit; recording a new state clears the redo side.
public struct SnapshotHistory<State: Equatable & Sendable>: Sendable {
    public private(set) var current: State
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    public let limit: Int

    public init(_ initial: State, limit: Int = 200) {
        current = initial
        self.limit = max(1, limit)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Makes `state` current. A state equal to the current one is not an edit.
    public mutating func record(_ state: State) {
        guard state != current else { return }
        undoStack.append(current)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
        current = state
    }

    /// Replaces the current state without a new undo step (typing in the same field keeps one step).
    public mutating func amend(_ state: State) {
        guard canUndo else { return record(state) }
        current = state
        redoStack.removeAll()
    }

    @discardableResult
    public mutating func undo() -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        current = previous
        return previous
    }

    @discardableResult
    public mutating func redo() -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        current = next
        return next
    }

    /// Starts over from `state` (a reload from the server), dropping both sides.
    public mutating func reset(_ state: State) {
        current = state
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
