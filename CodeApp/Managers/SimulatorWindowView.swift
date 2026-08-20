//
//  SimulatorWindowView.swift
//  Code
//
//  Rendering for one floating simulator window. See SimulatorManager.swift
//  for the underlying state model.
//
//  Key fixes in this version:
//
//  1. VIEWPORT: the web view is always built at the device's real, native
//     point size (e.g. 390x844 for iPhone 13) so pages get a correct, real
//     mobile viewport — never at the small on-screen window size (which
//     was making everything look zoomed in, breaking responsive layouts
//     like Flutter's own "bottom overflowed" warning, and throwing off
//     touch coordinates on the loaded page).
//
//  2. SCALING IS SELF-CONTAINED TO THE BEZEL ONLY. The previous version
//     scaled the ENTIRE window (title bar + buttons + bezel + size
//     controls together) with `.scaleEffect`, then re-declared its frame
//     using only the *bezel's* scaled size — which didn't match the
//     window's true total (scaled) height, since it left out the title
//     bar/button row/size-controls rows. That mismatch is the most likely
//     cause of the button row appearing to render behind/under the bezel,
//     the window drifting to the wrong on-screen position, and quite
//     possibly the crash on any button press (SwiftUI reconciling a
//     grossly mismatched frame during a layout pass). Now `.scaleEffect`
//     is applied ONLY inside `deviceBezel`, which is self-contained: its
//     pre-scale frame is exactly what gets scaled, so the frame reclaimed
//     after scaling is always exactly correct — no mismatch possible.
//     Everything else (title bar, buttons, size controls) is sized with
//     small, fixed, directly-chosen values — no scale-then-reframe math
//     for the parts users actually tap.
//
//  3. HIT-TESTING / FREEZE: minimizing uses plain, bounded conditional
//     rendering (not an opacity/scaleEffect "hidden but still mounted"
//     trick), so a minimized or closed window can never leave an
//     oversized, still-tappable area behind that could block touches to
//     the rest of the app.
//

import SwiftUI
import WebKit

/// Thin WKWebView wrapper, always built at the device's real point size.
/// Reloads ONLY when `reloadToken` changes or the URL itself changes —
/// never on ordinary SwiftUI re-renders.
private struct SimulatorWebView: UIViewRepresentable {
    @ObservedObject var window: SimulatorWindowState

    func makeUIView(context: Context) -> WKWebView {
        let nativeSize = window.deviceType.portraitSize
        let webView = WKWebView(frame: CGRect(origin: .zero, size: nativeSize))
        webView.load(URLRequest(url: window.url))
        context.coordinator.lastURL = window.url
        context.coordinator.lastReloadToken = window.reloadToken
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastURL != window.url
            || context.coordinator.lastReloadToken != window.reloadToken
        else {
            return
        }
        context.coordinator.lastURL = window.url
        context.coordinator.lastReloadToken = window.reloadToken
        webView.load(URLRequest(url: window.url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastURL: URL?
        var lastReloadToken: UUID?
    }
}

/// The floating device frame: grip handle + title, button row, bezel,
/// resize buttons.
struct SimulatorDeviceFrameView: View {
    @ObservedObject var window: SimulatorWindowState
    let onClose: () -> Void

    @State private var showSettings = false
    @State private var liveDragOffset: CGSize = .zero
    @EnvironmentObject var simulatorManager: SimulatorManager

    private static let resizeStep: CGFloat = 0.08
    private static let minScale: CGFloat = 0.28
    private static let maxScale: CGFloat = 1.1
    /// Fixed on-screen width for the control rows and background panel —
    /// intentionally NOT derived from any native-size/scale math, so it
    /// can never drift out of sync with what actually gets rendered.
    private static let barWidth: CGFloat = 220
    private static let rowHeight: CGFloat = 28

    private var nativeSize: CGSize { window.deviceType.portraitSize }
    /// The bezel's own on-screen size — this is the ONLY place scaling
    /// happens, and it's self-consistent by construction (see deviceBezel).
    private var scaledBezelSize: CGSize {
        CGSize(width: nativeSize.width * window.displayScale, height: nativeSize.height * window.displayScale)
    }
    /// True total on-screen footprint of the whole window (title bar +
    /// button row + bezel + size controls + spacing) — used for the
    /// background panel and to keep the window on-screen. Computed once,
    /// directly, so it can never mismatch the actual rendered content.
    private var totalWindowSize: CGSize {
        let height = Self.rowHeight * 3 + 18 + scaledBezelSize.height  // 3 rows + 3×6pt spacing
        return CGSize(width: max(Self.barWidth, scaledBezelSize.width) + 16, height: height + 16)
    }

    var body: some View {
        VStack(spacing: 6) {
            titleBar
            buttonRow
            deviceBezel
            sizeControls
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.init("sideBar.background"))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        )
        .offset(x: window.position.x + liveDragOffset.width, y: window.position.y + liveDragOffset.height)
        .sheet(isPresented: $showSettings) {
            SimulatorSettingsView(deviceType: window.deviceType)
                .environmentObject(simulatorManager)
        }
    }

    // MARK: Title bar — the ONLY draggable area in this whole view, and
    // nothing else lives inside it, so there is no button for a drag to
    // ever compete with.
    private var titleBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
            Text(window.deviceType.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: max(Self.barWidth, scaledBezelSize.width), height: Self.rowHeight)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .gesture(
            // Updates a plain local @State during the drag (cheap — only
            // this one small view re-renders). window.position (the
            // @Published property the whole window observes) is only
            // touched ONCE, at the end.
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    liveDragOffset = value.translation
                }
                .onEnded { value in
                    window.position.x += value.translation.width
                    window.position.y += value.translation.height
                    liveDragOffset = .zero
                }
        )
    }

    // MARK: Button row — plain taps only, no gesture attached to this
    // row or anything in it.
    private var buttonRow: some View {
        HStack(spacing: 22) {
            simulatorButton("gearshape.fill") { showSettings = true }
            simulatorButton("arrow.clockwise") { window.reloadToken = UUID() }
            simulatorButton("minus.circle.fill") { window.isMinimized = true }
            simulatorButton("xmark.circle.fill", action: onClose)
        }
        .frame(width: max(Self.barWidth, scaledBezelSize.width), height: Self.rowHeight)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func simulatorButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Device bezel — the real frame image, with a web view built at
    // the device's true native size padded to sit inside the frame's
    // transparent screen area. Scaling is entirely self-contained here:
    // the `.frame()` right before `.scaleEffect` is exactly what gets
    // scaled, so the `.frame()` right after is always exactly correct —
    // there is no other content mixed into this calculation.
    private var deviceBezel: some View {
        let insets = window.deviceType.screenInsets
        let leftPad = nativeSize.width * insets.left
        let rightPad = nativeSize.width * insets.right
        let topPad = nativeSize.height * insets.top
        let bottomPad = nativeSize.height * insets.bottom

        let bezelContent = ZStack {
            SimulatorWebView(window: window)
                .frame(width: nativeSize.width, height: nativeSize.height)
                .padding(EdgeInsets(top: topPad, leading: leftPad, bottom: bottomPad, trailing: rightPad))
                .clipShape(RoundedRectangle(cornerRadius: nativeSize.width * 0.05))

            Image(window.deviceType.frameImageName)
                .resizable()
        }
        .frame(width: nativeSize.width, height: nativeSize.height)

        return bezelContent
            .scaleEffect(window.displayScale)
            .frame(width: scaledBezelSize.width, height: scaledBezelSize.height)
    }

    // MARK: Size controls — plain +/- buttons, no drag handle.
    private var sizeControls: some View {
        HStack(spacing: 16) {
            simulatorButton("minus.magnifyingglass") {
                window.displayScale = max(Self.minScale, window.displayScale - Self.resizeStep)
            }
            Text("\(Int(window.displayScale * 100))%")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .frame(minWidth: 34)
            simulatorButton("plus.magnifyingglass") {
                window.displayScale = min(Self.maxScale, window.displayScale + Self.resizeStep)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: max(Self.barWidth, scaledBezelSize.width), height: Self.rowHeight)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SimulatorSettingsView: View {
    let deviceType: SimulatorDeviceType
    @EnvironmentObject var simulatorManager: SimulatorManager
    @Environment(\.dismiss) private var dismiss
    @State private var urlText: String = ""

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(deviceType.displayName) URL")
                    .font(.headline)
                TextField("https://example.com", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                Text("Saved permanently — reopening the simulator later loads this URL again.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Save & Reload") {
                    guard let url = URL(string: urlText), url.scheme != nil else { return }
                    simulatorManager.saveURL(url, for: deviceType)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(URL(string: urlText)?.scheme == nil)
                Spacer()
            }
            .padding()
            .navigationTitle("Simulator Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SwiftUI.ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            urlText = simulatorManager.urlDrafts[deviceType] ?? simulatorManager.savedURL(for: deviceType).absoluteString
        }
    }
}

private struct SimulatorMinimizedDockView: View {
    @ObservedObject var window: SimulatorWindowState

    var body: some View {
        Button { window.isMinimized = false } label: {
            VStack(spacing: 3) {
                Image(systemName: window.deviceType.sfSymbol)
                    .font(.system(size: 20))
                Text(window.deviceType.displayName)
                    .font(.system(size: 9))
                    .lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(10)
            .frame(width: 70)
            .background(Color.black.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 6)
        }
        .buttonStyle(.plain)
        .offset(x: window.position.x, y: window.position.y)
    }
}

/// Renders every open simulator window, plus the iPhone/iPad picker sheet
/// triggered from the toolbar. Add this once near the top of the app's
/// main view hierarchy (see MainScene.swift), above everything else, the
/// same way `NotificationCentreView` is already added there.
///
/// Deliberately plain `if/else` per window (not opacity/scaleEffect
/// tricks to "hide but keep mounted") — each branch only occupies its own
/// small, real bounds, so there's no way for a minimized or closed window
/// to leave an oversized, still-tappable area behind that could block
/// touches to the rest of the app.
struct SimulatorWindowsOverlay: View {
    @ObservedObject var manager = SimulatorManager.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(manager.windows) { window in
                if window.isMinimized {
                    SimulatorMinimizedDockView(window: window)
                } else {
                    SimulatorDeviceFrameView(window: window, onClose: { manager.close(window) })
                        .environmentObject(manager)
                }
            }
        }
        .allowsHitTesting(!manager.windows.isEmpty)
        .confirmationDialog(
            "Open Simulator", isPresented: $manager.showDevicePicker, titleVisibility: .visible
        ) {
            Button("iPhone") { manager.open(deviceType: .iPhone13Pro) }
            Button("iPad") { manager.open(deviceType: .iPadPro) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
