import AppKit
import SwiftUI
import UsageCore

/// What the key window can do with one provider's key.
struct APIKeyActions {
    /// Saves a normalized key.
    var save: (String) throws -> Void
    var remove: () throws -> Void
    /// Tries the typed key, or the saved one when nothing's typed.
    var test: (String?) async -> ConnectionTest
    var hasKey: () -> Bool
}

/// A provider's key: a secure field, Save, Remove and Test connection. The
/// typed key lives only in this view's state and is cleared once saved; it's
/// never shown again, only whether one is saved.
struct APIKeyView: View {
    var name: String
    var hint: String?
    var actions: APIKeyActions

    @State private var typed: String
    @State private var hasKey: Bool
    @State private var status: Status
    @State private var testing = false

    enum Status: Equatable {
        case idle
        case message(String, isProblem: Bool)
    }

    init(name: String, hint: String?, actions: APIKeyActions, typed: String = "", status: Status = .idle) {
        self.name = name
        self.hint = hint
        self.actions = actions
        _typed = State(initialValue: typed)
        _hasKey = State(initialValue: actions.hasKey())
        _status = State(initialValue: status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(name) API key").font(.headline)
            Text(hasKey
                ? "A key is saved in your Keychain. Paste a new one to replace it."
                : "Paste a key to show \(name)'s balance. It's kept in your Keychain and sent only to \(name)'s API.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            SecureField(hasKey ? "Saved key" : "API key", text: $typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack(spacing: 8) {
                statusText
                Spacer(minLength: 8)
                if testing { ProgressView().controlSize(.small) }
            }
            .frame(minHeight: 16)
            HStack {
                Button("Remove", role: .destructive, action: remove).disabled(!hasKey)
                Spacer()
                Button("Test connection", action: test).disabled(testing || (typed.isEmpty && !hasKey))
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(typed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder
    private var statusText: some View {
        if case let .message(text, isProblem) = status {
            Label(text, systemImage: isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(isProblem ? Color.orange : Color.green)
        }
    }

    private func save() {
        guard let key = APIKey.normalized(typed) else {
            status = .message(ConnectionTest.invalidKey.text, isProblem: true)
            return
        }
        do {
            try actions.save(key)
            typed = ""
            hasKey = actions.hasKey()
            status = .message("Saved", isProblem: false)
        } catch {
            status = .message("Couldn't save: \(error)", isProblem: true)
        }
    }

    private func remove() {
        do {
            try actions.remove()
            typed = ""
            hasKey = actions.hasKey()
            status = .message("Removed", isProblem: false)
        } catch {
            status = .message("Couldn't remove: \(error)", isProblem: true)
        }
    }

    private func test() {
        testing = true
        status = .idle
        let candidate = typed
        Task {
            let result = await actions.test(candidate.isEmpty ? nil : candidate)
            testing = false
            status = .message(result.text, isProblem: result != .connected)
        }
    }
}

/// The key window: one at a time, opened from the Providers menu.
@MainActor
final class APIKeyWindow {
    private var panel: NSPanel?

    func show(name: String, hint: String?, actions: APIKeyActions) {
        panel?.close()
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "\(name) API key"
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: APIKeyView(name: name, hint: hint, actions: actions))
        panel.center()
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }
}
