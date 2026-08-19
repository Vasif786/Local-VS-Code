//
//  SimulatorWindowView.swift
//  Code
//
//  Rendering for one floating simulator window. See SimulatorManager.swift
//  for the underlying state model.
//
//  Two important, hard-won fixes baked into this version:
//
//  1. VIEWPORT: the web view is always built at the device's real, native
//     point size (e.g. 390x844 for iPhone 13) — never at the small
//     on-screen window size. The whole composed device (web view + frame
//     image) is scaled down visually with `.scaleEffect`, then re-framed
//     to the scaled-down size so SwiftUI's LAYOUT also shrinks to match.
//     Constraining the web view's own frame directly (the previous
//     version) shrinks the actual viewport a page sees, which breaks
//     responsive layouts (e.g. Flutter's own "bottom overflowed" error),
//     makes everything look zoomed in, and throws off touch coordinates.
//     Scaling a correctly-sized view visually keeps all of that correct.
//
//  2. HIT-TESTING / FREEZE: minimizing no longer keeps the full window
//     (including the WKWebView) mounted at 1% scale + 0% opacity. That
//     technique was meant to preserve page state, but very likely left a
//     large, still-hit-testable view sitting over the whole app,
//     swallowing touches everywhere — matching the "entire app frozen,
//     no button anywhere works" reports. Minimizing now uses plain,
//     bounded conditional rendering instead: a real stability trade-off
//     (the page may reload when un-minimizing) in exchange for the rest
//     of the app reliably staying responsive.
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
/// resize buttons. Everything inside is laid out at the device's REAL
/// native size, then the whole thing is scaled down at the very end.
struct SimulatorDeviceFrameView: View {
    @ObservedObject var window: SimulatorWindowState
    let onClose: () -> Void

    @State private var showSettings = false
    @State private var liveDragOffset: CGSize = .zero
    @EnvironmentObject var simulatorManager: SimulatorManager

    private static let resizeStep: CGFloat = 0.08
    private static let minScale: CGFloat = 0.28
    private static let maxScale: CGFloat = 1.1

    private var nativeSize: CGSize { window.deviceType.portraitSize }
    /// The final, on-screen footprint after scaling — what the rest of the
    /// app (drag math, layout) should treat as this window's size.
    private var scaledSize: CGSize {
        CGSize(width: nativeSize.width * window.displayScale, height: nativeSize.height * window.displayScale)
    }

    var body: some View {
        VStack(spacing: 6) {
            titleBar
            buttonRow
            deviceBezel
            sizeControls
        }
        // Build everything above at native size, then scale the whole
        // composed window down, then re-declare the frame at the scaled
        // size so SwiftUI's layout (and hit-testing bounds) match what's
        // actually visible — this is what keeps a minimized/closed window
        // from leaving an oversized invisible area behind.
        .scaleEffect(window.displayScale, anchor: .topLeading)
        .frame(width: scaledSize.width, height: scaledSize.height, alignment: .topLeading)
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
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.white.opacity(0.55))
            Text(window.deviceType.displayName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(width: nativeSize.width, height: 56)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .gesture(
            // Updates a plain local @State during the drag (cheap — only
            // this one small view re-renders). window.position (the
            // @Published property the whole window observes) is only
            // touched ONCE, at the end — mutating it on every pixel of
            // movement was forcing the entire window, web view included,
            // to re-render dozens of times a second while dragging.
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
        HStack(spacing: 36) {
            simulatorButton("gearshape.fill") { showSettings = true }
            simulatorButton("arrow.clockwise") { window.reloadToken = UUID() }
            simulatorButton("minus.circle.fill") { window.isMinimized = true }
            simulatorButton("xmark.circle.fill", action: onClose)
        }
        .frame(width: nativeSize.width, height: 56)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func simulatorButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 26))
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Device bezel — the real frame image, with the web view (built
    // at the device's real native size) padded to sit inside the frame's
    // transparent screen area.
    private var deviceBezel: some View {
        let insets = window.deviceType.screenInsets
        let leftPad = nativeSize.width * insets.left
        let rightPad = nativeSize.width * insets.right
        let topPad = nativeSize.height * insets.top
        let bottomPad = nativeSize.height * insets.bottom

        return ZStack {
            SimulatorWebView(window: window)
                .frame(width: nativeSize.width, height: nativeSize.height)
                .padding(EdgeInsets(top: topPad, leading: leftPad, bottom: bottomPad, trailing: rightPad))
                .clipShape(RoundedRectangle(cornerRadius: nativeSize.width * 0.05))

            Image(window.deviceType.frameImageName)
                .resizable()
        }
        .frame(width: nativeSize.width, height: nativeSize.height)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }

    // MARK: Size controls — plain +/- buttons, no drag handle.
    private var sizeControls: some View {
        HStack(spacing: 28) {
            simulatorButton("minus.magnifyingglass") {
                window.displayScale = max(Self.minScale, window.displayScale - Self.resizeStep)
            }
            Text("\(Int(window.displayScale * 100))%")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .frame(minWidth: 70)
            simulatorButton("plus.magnifyingglass") {
                window.displayScale = min(Self.maxScale, window.displayScale + Self.resizeStep)
            }
        }
        .padding(.horizontal, 20)
        .frame(width: nativeSize.width, height: 56)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
