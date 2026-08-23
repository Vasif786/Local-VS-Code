//
//  SimulatorWindowView.swift
//  Code
//
//  Rendering for one floating simulator window. See SimulatorManager.swift
//  for the underlying state model.
//
//  IMPORTANT — why this version has no pinch/rotate gestures:
//  Combining a drag gesture with MagnificationGesture and RotationGesture
//  as simultaneous recognizers on the same view is what brought the
//  freeze back after it had been fixed. Having three gesture recognizers
//  concurrently active on one view is a well-known source of instability
//  in SwiftUI. Resize and rotate are now plain buttons — the same kind of
//  control as reload/minimize/close, which have never been reported as
//  unstable. If two-finger gestures are wanted again later, they should
//  be reintroduced as an isolated, separately-tested step, not bundled
//  with everything else.
//
//  Other fixes in this version:
//
//  1. TOUCH INSIDE THE WEB PAGE: the web view's visual scale/rotation is
//     applied with a plain UIKit `CGAffineTransform` directly on the
//     WKWebView itself (inside `updateUIView`), not with SwiftUI's
//     `.scaleEffect`/`.rotationEffect` on an ancestor view — SwiftUI's
//     modifiers apply an external Core Animation layer transform that
//     WKWebView's own internal touch/JS-event handling doesn't reliably
//     account for. `UIView.transform` is the standard way apps shrink a
//     live, interactive view while keeping its own touch handling correct.
//
//  2. "WEB VIEW DOESN'T FIT": layout (position + transform) is now
//     recomputed on EVERY `updateUIView` call, not just when
//     scale/orientation change. The previous version skipped the update
//     whenever those two values were unchanged, but the container's
//     `.bounds` can change independently of them (most notably right
//     after the very first layout pass, when bounds go from zero to
//     their real size) — that's very likely why the web view sometimes
//     never got positioned correctly. Repositioning a view is a cheap
//     operation, so there's no real cost to always doing it.
//
//  3. ROTATION DIRECTION: reversed to -90° (was +90°), with the
//     screen-hole inset remapping reversed to match, fixing the reported
//     "rotates the wrong way".
//

import SwiftUI
import WebKit

/// Wraps a WKWebView inside a plain container. The web view is always
/// built at the device's real point size (correct viewport for the page,
/// swapped for landscape so the page gets a genuinely landscape-shaped
/// viewport, exactly like a real device rotation); its on-screen
/// appearance is scaled via `UIView.transform` — never SwiftUI's
/// `.scaleEffect`.
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

        // Always reposition — see file header for why this is no longer
        // gated behind "did scale/orientation change".
        context.coordinator.applyLayout(window: window, containerBounds: container.bounds)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var webView: WKWebView?
        var lastURL: URL?
        var lastReloadToken: UUID?
        private var lastAppliedKey: String?

        /// The web view's own `.bounds` are swapped for landscape — a
        /// real width/height swap, giving the page a genuinely
        /// landscape-shaped viewport so it reflows for real, not just
        /// appears rotated. Only a plain scale is applied visually via
        /// `.transform` — no rotation transform, the bounds swap already
        /// handles orientation. `.bounds`/`.center` are used instead of
        /// `.frame`, since UIKit's own docs say `.frame` is undefined
        /// once `.transform` isn't the identity transform.
        func applyLayout(window: SimulatorWindowState, containerBounds: CGRect) {
            guard let webView = webView, containerBounds.width > 0, containerBounds.height > 0 else {
                return
            }
            // Cheap guard against redundant identical work within the same
            // layout pass, WITHOUT skipping genuine bounds changes (unlike
            // the old scale/orientation-only check).
            let key =
                "\(window.displayScale)|\(window.orientation)|\(containerBounds.width)|\(containerBounds.height)"
            guard key != lastAppliedKey else { return }
            lastAppliedKey = key

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
/// resize/rotate controls.
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
    /// swap has an exact, simple bounding box.
    private var orientedNativeSize: CGSize {
        window.orientation == .landscape
            ? CGSize(width: nativeSize.height, height: nativeSize.width)
            : nativeSize
    }
    /// The bezel's own on-screen size.
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

    // MARK: Title bar — the ONLY draggable area anywhere in this view.
    // Nothing else has a gesture attached at all — resize/rotate are
    // plain buttons (see the note at the top of this file).
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
        .gesture(
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

    // MARK: Button row — plain taps only.
    private var buttonRow: some View {
        HStack(spacing: 18) {
            simulatorButton("gearshape.fill") { showSettings = true }
            simulatorButton("arrow.clockwise") { window.reloadToken = UUID() }
            simulatorButton("rotate.right") {
                window.orientation = window.orientation == .portrait ? .landscape : .portrait
            }
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
                .font(.system(size: 13))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Device bezel — the real frame image, with a web view built at
    // the device's true native size padded to sit inside the frame's
    // transparent screen area. No gestures live here at all.
    private var deviceBezel: some View {
        let insets = window.deviceType.screenInsets
        let portraitTopPad = nativeSize.height * insets.top
        let portraitRightPad = nativeSize.width * insets.right
        let portraitBottomPad = nativeSize.height * insets.bottom
        let portraitLeftPad = nativeSize.width * insets.left

        // The frame image rotates -90° (counter-clockwise) for landscape,
        // so its screen hole rotates with it: the top edge becomes the
        // LEFT edge, and so on around.
        let topPad: CGFloat
        let rightPad: CGFloat
        let bottomPad: CGFloat
        let leftPad: CGFloat
        if window.orientation == .landscape {
            topPad = portraitRightPad
            rightPad = portraitBottomPad
            bottomPad = portraitLeftPad
            leftPad = portraitTopPad
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
                .rotationEffect(.degrees(window.orientation == .landscape ? -90 : 0))
                .frame(width: orientedNativeSize.width, height: orientedNativeSize.height)
                .scaleEffect(window.displayScale)
                .frame(width: scaledBezelSize.width, height: scaledBezelSize.height)
        }
        .frame(width: scaledBezelSize.width, height: scaledBezelSize.height)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .zIndex(1)
    }

    // MARK: Size controls — plain +/- buttons.
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
