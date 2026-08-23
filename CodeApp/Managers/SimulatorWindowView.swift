//
//  SimulatorWindowView.swift
//  Code
//
//  Rendering for one floating simulator window. See SimulatorManager.swift
//  for the underlying state model.
//
//  Key fixes in this version:
//
//  1. TOUCH INSIDE THE WEB PAGE: the web view's visual scale/rotation is
//     now applied with a plain UIKit `CGAffineTransform` directly on the
//     WKWebView itself (inside `updateUIView`), not with SwiftUI's
//     `.scaleEffect`/`.rotationEffect` on an ancestor view. SwiftUI's
//     modifiers apply an *external* Core Animation layer transform that
//     WKWebView's own internal touch/JS-event coordinate handling doesn't
//     reliably account for — which is very likely why taps inside the
//     loaded page weren't registering. `UIView.transform` is the
//     long-standing, standard way apps shrink a live, interactive view
//     (e.g. a "live thumbnail") while keeping its own touch handling
//     correctly mapped, since UIKit's hit-testing is built around it.
//
//  2. FREEZE: all pinch/rotate gesture handling is now commit-only — the
//     transform is only recomputed once, in `onEnded`, never on every
//     frame of the gesture. Repeatedly reconciling an external transform
//     over a WKWebView's layer tree at gesture frame-rate is a plausible
//     contributor to the freezing reported earlier; removing that
//     per-frame churn removes the risk regardless of the exact cause.
//
//  3. MOVING THE WINDOW: a plain single-finger drag now works directly on
//     the device bezel itself (in addition to the title bar's own drag),
//     combined with the two-finger pinch/rotate via `SimultaneousGesture`
//     — a single-finger drag and a two-finger pinch/rotate are
//     unambiguous to iOS's gesture system since they involve a different
//     number of touches, so these don't conflict with each other.
//
//  4. Explicit `.zIndex` on the control rows guards against them ever
//     rendering underneath the bezel (reported specifically on iPad).
//

import SwiftUI
import WebKit

/// Wraps a WKWebView inside a plain container. The web view is always
/// built at the device's real point size (correct viewport for the page);
/// its on-screen appearance is scaled/rotated via `UIView.transform`
/// (never SwiftUI's `.scaleEffect`/`.rotationEffect`), and only updated
/// when the committed scale/orientation actually change — not on every
/// SwiftUI re-render, and never live during a gesture.
private struct SimulatorWebView: UIViewRepresentable {
    @ObservedObject var window: SimulatorWindowState

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true

        let nativeSize = window.deviceType.portraitSize
        let webView = WKWebView(frame: CGRect(origin: .zero, size: nativeSize))
        webView.load(URLRequest(url: window.url))
        container.addSubview(webView)

        context.coordinator.webView = webView
        context.coordinator.lastURL = window.url
        context.coordinator.lastReloadToken = window.reloadToken
        context.coordinator.applyLayout(window: window, containerBounds: container.bounds)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard let webView = context.coordinator.webView else { return }

        if context.coordinator.lastURL != window.url
            || context.coordinator.lastReloadToken != window.reloadToken
        {
            context.coordinator.lastURL = window.url
            context.coordinator.lastReloadToken = window.reloadToken
            webView.load(URLRequest(url: window.url))
        }

        context.coordinator.applyLayout(window: window, containerBounds: container.bounds)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var webView: WKWebView?
        var lastURL: URL?
        var lastReloadToken: UUID?
        private var lastScale: CGFloat?
        private var lastOrientation: SimulatorOrientation?

        /// Only touches layout when scale/orientation actually changed —
        /// cheap no-op on ordinary re-renders (drag, etc.).
        ///
        /// The web view's own `.bounds` are swapped for landscape — this
        /// gives the loaded page a genuinely landscape-shaped viewport
        /// (real width/height swap, exactly like an actual device
        /// rotation), so it reflows for real, not just appears rotated.
        /// Only a plain scale is applied visually via `.transform` (no
        /// rotation transform — the bounds swap already handles
        /// orientation). `.bounds`/`.center` are used instead of `.frame`,
        /// since UIKit's own docs say `.frame` is undefined once
        /// `.transform` isn't the identity transform.
        func applyLayout(window: SimulatorWindowState, containerBounds: CGRect) {
            guard let webView = webView else { return }
            guard lastScale != window.displayScale || lastOrientation != window.orientation else {
                return
            }
            lastScale = window.displayScale
            lastOrientation = window.orientation

            let nativeSize = window.deviceType.portraitSize
            let orientedSize =
                window.orientation == .landscape
                ? CGSize(width: nativeSize.height, height: nativeSize.width)
                : nativeSize

            webView.transform = .identity
            webView.bounds = CGRect(origin: .zero, size: orientedSize)
            webView.center = CGPoint(x: containerBounds.midX, y: containerBounds.midY)
            webView.transform = CGAffineTransform(scaleX: window.displayScale, y: window.displayScale)
        }
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
    private static let maxScale: CGFloat = 1.3
    private static let maximizedScale: CGFloat = 1.1
    /// Fixed on-screen width for the control rows and background panel —
    /// intentionally NOT derived from any native-size/scale math, so it
    /// can never drift out of sync with what actually gets rendered.
    private static let barWidth: CGFloat = 220
    private static let rowHeight: CGFloat = 28

    private var nativeSize: CGSize { window.deviceType.portraitSize }
    /// The device's own footprint, swapped for landscape — a clean 90°
    /// swap has an exact, simple bounding box (unlike a partial rotation
    /// angle, whose bounding box changes continuously).
    private var orientedNativeSize: CGSize {
        window.orientation == .landscape
            ? CGSize(width: nativeSize.height, height: nativeSize.width)
            : nativeSize
    }
    /// The bezel's own on-screen size — always based on the COMMITTED
    /// scale (never a live/in-progress gesture value), so it's always
    /// self-consistent with what's actually rendered.
    private var scaledBezelSize: CGSize {
        CGSize(
            width: orientedNativeSize.width * window.displayScale,
            height: orientedNativeSize.height * window.displayScale)
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

    /// Shared single-finger drag-to-move, used by both the title bar and
    /// the bezel itself. Updates a plain local @State during the drag
    /// (cheap — only this view re-renders); window.position (the
    /// @Published property the whole window observes) is only touched
    /// ONCE, at the end.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                liveDragOffset = value.translation
            }
            .onEnded { value in
                window.position.x += value.translation.width
                window.position.y += value.translation.height
                liveDragOffset = .zero
            }
    }

    // MARK: Title bar
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
        .zIndex(2)
        .gesture(moveGesture)
    }

    // MARK: Button row — plain taps only, no gesture attached to this
    // row or anything in it.
    private var buttonRow: some View {
        HStack(spacing: 18) {
            simulatorButton("gearshape.fill") { showSettings = true }
            simulatorButton("arrow.clockwise") { window.reloadToken = UUID() }
            simulatorButton("arrow.up.left.and.arrow.down.right") {
                window.displayScale = Self.maximizedScale
            }
            simulatorButton("minus.circle.fill") { window.isMinimized = true }
            simulatorButton("xmark.circle.fill", action: onClose)
        }
        .frame(width: max(Self.barWidth, scaledBezelSize.width), height: Self.rowHeight)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .zIndex(2)
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
    // transparent screen area.
    //
    // The web view's own visual scale/rotation is handled entirely
    // inside `SimulatorWebView` via `UIView.transform` (see its doc
    // comment) — NOT here. Only the non-interactive frame IMAGE uses
    // SwiftUI's `.scaleEffect`/`.rotationEffect`, which is perfectly safe
    // since a plain `Image` has no touch handling of its own to conflict
    // with.
    //
    // Two-finger gestures: pinch resizes, a two-finger twist past ~30°
    // snaps portrait/landscape — both commit-only (no live preview during
    // the gesture), combined with the single-finger move-drag via
    // `SimultaneousGesture` (different touch counts, so they never
    // conflict with each other).
    private var deviceBezel: some View {
        let insets = window.deviceType.screenInsets
        let portraitTopPad = nativeSize.height * insets.top
        let portraitRightPad = nativeSize.width * insets.right
        let portraitBottomPad = nativeSize.height * insets.bottom
        let portraitLeftPad = nativeSize.width * insets.left

        // The frame image rotates 90° for landscape, so its screen hole
        // rotates with it: what was the top edge becomes the right edge,
        // and so on around — these are NOT just portrait/landscape
        // swapped, they're rotated.
        let topPad: CGFloat
        let rightPad: CGFloat
        let bottomPad: CGFloat
        let leftPad: CGFloat
        if window.orientation == .landscape {
            topPad = portraitLeftPad
            rightPad = portraitTopPad
            bottomPad = portraitRightPad
            leftPad = portraitBottomPad
        } else {
            topPad = portraitTopPad
            rightPad = portraitRightPad
            bottomPad = portraitBottomPad
            leftPad = portraitLeftPad
        }

        return ZStack {
            SimulatorWebView(window: window)
                .padding(
                    EdgeInsets(
                        top: topPad * window.displayScale, leading: leftPad * window.displayScale,
                        bottom: bottomPad * window.displayScale, trailing: rightPad * window.displayScale)
                )
                .clipShape(RoundedRectangle(cornerRadius: scaledBezelSize.width * 0.05))

            Image(window.deviceType.frameImageName)
                .resizable()
                .frame(width: nativeSize.width, height: nativeSize.height)
                .rotationEffect(.degrees(window.orientation == .landscape ? 90 : 0))
                .frame(width: orientedNativeSize.width, height: orientedNativeSize.height)
                .scaleEffect(window.displayScale)
                .frame(width: scaledBezelSize.width, height: scaledBezelSize.height)
        }
        .frame(width: scaledBezelSize.width, height: scaledBezelSize.height)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .zIndex(1)
        .gesture(
            SimultaneousGesture(
                moveGesture,
                SimultaneousGesture(
                    MagnificationGesture()
                        .onEnded { value in
                            window.displayScale = min(max(window.displayScale * value, Self.minScale), Self.maxScale)
                        },
                    RotationGesture()
                        .onEnded { angle in
                            if abs(angle.degrees) > 30 {
                                window.orientation = window.orientation == .portrait ? .landscape : .portrait
                            }
                        }
                )
            )
        )
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
        .zIndex(2)
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
            Button("iPhone") { manager.open(deviceType: .iPhone14Pro) }
            Button("iPad") { manager.open(deviceType: .iPadPro) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
