import SwiftUI
import UsageCore

/// What the update line's buttons do.
struct UpdateActions {
    /// Starts the one-click update, or tries it again.
    var install: () -> Void = {}
    /// Reveals the update log in Finder.
    var showLog: () -> Void = {}
    /// Copies a notify-only build's command.
    var copy: (String) -> Void = { _ in }
    /// Opens the release's page.
    var openPage: (URL) -> Void = { _ in }
}

/// The update line above the footer: "Update to v1.1.0" as a button, the
/// progress of an update, a failure with its log, or, for a build that
/// can't update itself, the command to run.
struct UpdateBannerView: View {
    var banner: UpdateBanner
    var actions: UpdateActions

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor(palette))
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title).font(.system(size: 12, weight: .semibold))
                if let detail = banner.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let command = banner.command {
                    Text(command)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.button, in: RoundedRectangle(cornerRadius: 5))
                }
                if let log = banner.logPath {
                    Text("Log: \(log)")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.muted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttons(palette: palette)
            }
            Spacer(minLength: 0)
            if banner.style == .available {
                Button(action: actions.install) {
                    Text("Update")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(palette.fill(.normal), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(banner.title)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(palette.divider).frame(height: 1) }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func buttons(palette: Palette) -> some View {
        switch banner.style {
        case .failed:
            HStack(spacing: 6) {
                if banner.logPath != nil { small("Show log", palette: palette, action: actions.showLog) }
                small("Try again", palette: palette, action: actions.install)
            }
            .padding(.top, 2)
        case .notifyOnly:
            HStack(spacing: 6) {
                if let command = banner.command { small("Copy command", palette: palette) { actions.copy(command) } }
                if let page = banner.page { small("Release notes", palette: palette) { actions.openPage(page) } }
            }
            .padding(.top, 2)
        case .available, .working:
            EmptyView()
        }
    }

    private func small(_ title: String, palette: Palette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(palette.button, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
    }

    private var icon: String {
        switch banner.style {
        case .available, .notifyOnly: "arrow.down.circle.fill"
        case .working: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func iconColor(_ palette: Palette) -> Color {
        switch banner.style {
        case .available, .notifyOnly: palette.fill(.normal)
        case .working: palette.muted
        case .failed: palette.fill(.warning)
        }
    }
}
