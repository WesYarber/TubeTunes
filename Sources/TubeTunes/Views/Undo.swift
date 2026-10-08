import AppKit
import SwiftUI

/// Undo/redo for one download's tracks. Each edit records the previous track list;
/// rapid edits with the same name (dragging an edge, moving a slider) collapse into one step.
///
/// Music itself isn't touched by these edits — changes reach Music on "Update in Music" —
/// so undo can always restore a previous state safely.
@MainActor
final class SegmentHistory {
    let itemID: UUID
    weak var undoManager: UndoManager?

    private var lastName = ""
    private var lastChange: Date?
    private var lib: Library { .shared }
    private var current: [Segment] { lib.item(itemID)?.segments ?? [] }

    init(itemID: UUID) { self.itemID = itemID }

    func change(_ name: String, coalesce: Bool = false, _ body: (inout [Segment]) -> Void) {
        let before = current
        var after = before
        body(&after)
        after.sort { $0.start < $1.start }
        guard after != before else { return }
        write(after)

        let now = Date()
        if coalesce, name == lastName, let last = lastChange, now.timeIntervalSince(last) < 1.0 {
            lastChange = now
            return
        }
        register(restoring: before, name: name)
        lastName = coalesce ? name : ""
        lastChange = coalesce ? now : nil
    }

    func detach() {
        undoManager?.removeAllActions(withTarget: self)
    }

    private func register(restoring state: [Segment], name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(state, name: name) }
        }
        undoManager.setActionName(name)
    }

    private func restore(_ state: [Segment], name: String) {
        let now = current
        // Whether a track is in Music isn't undoable; keep the live IDs for tracks that still exist.
        let live = Dictionary(uniqueKeysWithValues: now.map { ($0.id, $0) })
        let restored = state.map { seg -> Segment in
            guard let cur = live[seg.id] else { return seg }
            var s = seg
            s.musicPersistentID = cur.musicPersistentID
            s.addedToMusicAt = cur.addedToMusicAt
            return s
        }
        write(restored)
        lastChange = nil
        register(restoring: now, name: name)   // registered during undo = redo
    }

    private func write(_ segments: [Segment]) {
        lib.update(itemID) { item in
            item.segments = segments
            if item.status == .added { item.status = .needsReview }   // edits waiting for "Update in Music"
        }
    }
}

/// Catches trackpad pinch and scroll events over the view it backs, without stealing clicks.
struct ScrollZoomCatcher: NSViewRepresentable {
    /// Horizontal and vertical scroll in points, plus whether ⌥ was held.
    var onScroll: (CGFloat, CGFloat, Bool, CGFloat) -> Void
    /// Pinch magnification delta and the pointer's x position as a fraction of the width.
    var onMagnify: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGFloat, Bool, CGFloat) -> Void)?
        var onMagnify: ((CGFloat, CGFloat) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p), self.bounds.width > 0 else { return event }
                let fx = p.x / self.bounds.width
                if event.type == .magnify {
                    self.onMagnify?(event.magnification, fx)
                } else {
                    let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                    self.onScroll?(event.scrollingDeltaX * scale, event.scrollingDeltaY * scale,
                                   event.modifierFlags.contains(.option), fx)
                }
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// Text field that edits a draft and writes it back on Return or when focus leaves,
/// so each field edit is one undo step (typing undo inside the field still works natively).
struct CommitTextField: View {
    let label: String
    @Binding var text: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    init(_ label: String, text: Binding<String>) {
        self.label = label
        self._text = text
    }

    var body: some View {
        TextField(label, text: $draft)
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { _, v in if !focused { draft = v } }
            .onSubmit(commit)
            .onChange(of: focused) { _, f in if !f { commit() } }
            .onDisappear(perform: commit)
    }

    private func commit() {
        if draft != text { text = draft }
    }
}

/// Calls `action` when Space is pressed in this view's window, unless a text field is being edited
/// or a sheet is open.
struct SpacebarCatcher: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.keyCode == 49, window.attachedSheet == nil,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      !(window.firstResponder is NSText) else { return event }
                self.action?()
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
