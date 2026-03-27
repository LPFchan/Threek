import SwiftUI
import AppKit

// ---------------------------------------------------------------------------
// MARK: - SelectorPopup
// ---------------------------------------------------------------------------
// Root SwiftUI view rendered inside the floating NSPanel HUD.
// Renders one of three layouts depending on how many apps are active.
// ---------------------------------------------------------------------------

struct SelectorPopup: View {
    @ObservedObject var viewModel: SelectorViewModel

    var body: some View {
        ZStack {
            // Vibrancy background fills the entire popup
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 20))

            content
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
        }
        .fixedSize()  // Size wraps content
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()

        case .showing(let apps) where apps.count == 2:
            twoAppLayout(apps: apps)

        case .showing(let apps):
            threeAppLayout(apps: apps)

        case .selecting(let apps, let selectedIndex):
            scrollSelectorLayout(apps: apps, selectedIndex: selectedIndex)
        }
    }

    // MARK: - 2-app layout: [⏮ app0]   [app1 ⏭]

    private func twoAppLayout(apps: [NowPlayingApp]) -> some View {
        HStack(spacing: 24) {
            AppIconView(app: apps[0], label: "backward.fill")
            AppIconView(app: apps[1], label: "forward.fill")
        }
    }

    // MARK: - 3-app layout: [⏮ app0]  [⏯ app1]  [app2 ⏭]

    private func threeAppLayout(apps: [NowPlayingApp]) -> some View {
        HStack(spacing: 24) {
            AppIconView(app: apps[0], label: "backward.fill")
            AppIconView(app: apps[1], label: "playpause.fill")
            AppIconView(app: apps[2], label: "forward.fill")
        }
    }

    // MARK: - 4+ app layout: scrollable row with selection ring

    private func scrollSelectorLayout(apps: [NowPlayingApp], selectedIndex: Int) -> some View {
        VStack(spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                            AppIconView(
                                app: app,
                                label: "",
                                isSelected: index == selectedIndex
                            )
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxWidth: 400)
                .onChange(of: selectedIndex) { newIndex in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }

            // Key hint row: ⏮ move left · ⏯ confirm · ⏭ move right
            HStack(spacing: 32) {
                Image(systemName: "backward.fill")
                Image(systemName: "playpause.fill")
                Image(systemName: "forward.fill")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - VisualEffectView (AppKit NSVisualEffectView wrapped for SwiftUI)
// ---------------------------------------------------------------------------

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
