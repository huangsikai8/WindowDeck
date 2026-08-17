import AppKit
import SwiftUI

/// Captures the next key combination pressed.
///
/// Rejects a bare key with no modifier: registering one globally would swallow
/// that key across the whole system, so pressing `k` once would mean never
/// typing a `k` in any app again.
final class ShortcutRecorderView: NSView {

    var onRecord: ((Shortcut) -> Void)?
    var onRejectBareKey: (() -> Void)?
    var onCancel: (() -> Void)?

    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }

    func beginRecording() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }

            if event.keyCode == 53 {           // Escape cancels
                self.stop()
                self.onCancel?()
                return nil
            }

            if let shortcut = Shortcut(event: event) {
                self.stop()
                self.onRecord?(shortcut)
            } else {
                self.onRejectBareKey?()
            }
            return nil                          // Never let it reach anything else
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onRecord: (Shortcut) -> Void
    let onRejectBareKey: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onRecord = { shortcut in
            onRecord(shortcut)
            isRecording = false
        }
        view.onRejectBareKey = onRejectBareKey
        view.onCancel = { isRecording = false }
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        if isRecording {
            view.beginRecording()
        } else {
            view.stop()
        }
    }
}

/// One editable binding: its name, current combination, and record/clear buttons.
struct ShortcutRow: View {
    let action: ShortcutAction
    let shortcut: Shortcut?
    let isRegistered: Bool
    let onRecord: (Shortcut) -> Void
    let onClear: () -> Void

    @State private var isRecording = false
    @State private var showBareKeyWarning = false

    var body: some View {
        HStack {
            Text(action.label)
            Spacer()

            if showBareKeyWarning {
                Text("Needs a modifier")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if shortcut != nil, !isRegistered {
                // Registration failed, which nearly always means macOS already
                // owns the combination.
                Text("In use by macOS")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button {
                showBareKeyWarning = false
                isRecording.toggle()
            } label: {
                Text(buttonTitle)
                    .font(.system(size: 11, design: .rounded))
                    .frame(minWidth: 76)
            }
            .background(
                ShortcutRecorder(
                    isRecording: $isRecording,
                    onRecord: onRecord,
                    onRejectBareKey: { showBareKeyWarning = true }
                )
                .frame(width: 0, height: 0)
            )

            Button {
                onClear()
                isRecording = false
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(shortcut == nil)
            .help("Remove this shortcut")
        }
    }

    private var buttonTitle: String {
        if isRecording { return "Press keys…" }
        return shortcut?.displayString ?? "Not set"
    }
}
