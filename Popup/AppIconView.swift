import SwiftUI
import AppKit

// ---------------------------------------------------------------------------
// MARK: - AppIconView
// ---------------------------------------------------------------------------
// A single app icon (64 pt) with an SF Symbol label below it.
// Used for each app slot in the popup.
// ---------------------------------------------------------------------------

struct AppIconView: View {
    let app: NowPlayingApp
    let label: String       // SF Symbol name, e.g. "backward.fill"
    var isSelected: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Selection ring for 4+ selector mode
                if isSelected {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.accentColor, lineWidth: 2.5)
                        .frame(width: 76, height: 76)
                }

                // App icon
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .frame(width: 64, height: 64)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)

            // Key hint label (SF Symbol)
            Image(systemName: label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
    }
}
