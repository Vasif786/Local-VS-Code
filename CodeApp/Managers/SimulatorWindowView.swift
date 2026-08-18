//
//  SimulatorWindowView.swift
//  Code
//
//  Rendering for one floating simulator window. See SimulatorManager.swift
//  for the underlying state model.
//
//  Safety-first design (rewritten after the drag/resize/rotate gestures
//  caused the whole screen to become unresponsive): every interactive
//  control here is a plain SwiftUI Button (tap only). There is exactly
//  ONE DragGesture in this entire file — on a dedicated grip handle that
//  has no other control anywhere near or inside it — so it can never
//  compete with a button's own tap recognition. Resize is +/- buttons,
//  not a drag handle. Rotation is a plain frame-dimension swap, not a
//  `.rotationEffect` transform (combining rotation transforms with
//  reactive `.frame()` sizing is a known source of SwiftUI layout
//  thrashing, and was the most likely cause of the freeze).
//

import SwiftUI
import WebKit

/// Thin WKWebView wrapper. Reloads ONLY when `reloadToken` changes or the
/// URL itself changes — never on ordinary SwiftUI re-renders, so the
/// loaded page's state isn't lost by those.
private struct SimulatorWebView: UIViewRepresentable {
    @ObservedObject var window: SimulatorWindowState

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
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
    @EnvironmentObject var simulatorManager: SimulatorManager

    private static let resizeStep: CGFloat = 0.08
    private static let minScale: CGFloat = 0.28
    private static let maxScale: CGFloat = 1.1

    /// Portrait frame size (the only orientation the frame image has).
    private var portraitDisplaySize: CGSize {
        CGSize(
            width: window.deviceType.portraitSize.width * window.displayScale,
            height: window.deviceType.portraitSize.height * window.displayScale)
    }

    var body: some View {
        VStack(spacing: 6) {
            titleBar
            buttonRow
            deviceBezel
            sizeControls
        }
        .offset(x: window.position.x, y: window.position.y)
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: portraitDisplaySize.width, height: 26)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    window.position.x = window.dragStartPosition.x + value.translation.width
                    window.position.y = window.dragStartPosition.y + value.translation.height
                }
                .onEnded { _ in
                    window.dragStartPosition = window.position
                }
        )
        .onAppear { window.dragStartPosition = window.position }
    }

    // MARK: Button row — plain taps only, no gesture attached to this
    // row or anything in it.
    private var buttonRow: some View {
        HStack(spacing: 18) {
            simulatorButton("gearshape.fill") { showSettings = true }
            simulatorButton("arrow.clockwise") { window.reloadToken = UUID() }
            simulatorButton("rectangle.landscape.rotate") {
                window.orientation = window.orientation == .portrait ? .landscape : .portrait
            }
            simulatorButton("minus.circle.fill") { window.isMinimized = true }
            simulatorButton("xmark.circle.fill", action: onClose)
        }
        .frame(width: portraitDisplaySize.width, height: 26)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func simulatorButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Device bezel — the real frame image, with the web view's
    // content area sized (not rotated) according to orientation.
    private var deviceBezel: some View {
        let insets = window.deviceType.screenInsets
        let portraitScreenWidth = portraitDisplaySize.width * (1 - insets.left - insets.right)
        let portraitScreenHeight = portraitDisplaySize.height * (1 - insets.top - insets.bottom)
        let screenCenterX = portraitDisplaySize.width * (insets.left + (1 - insets.left - insets.right) / 2)
        let screenCenterY = portraitDisplaySize.height * (insets.top + (1 - insets.top - insets.bottom) / 2)

        // Landscape: swap the WEB VIEW CONTENT's width/height so its
        // contents resize accordingly, letterboxed within the same
        // portrait screen-hole area — no transform on the frame image
        // itself (the frame art only exists in portrait).
        let contentWidth = window.orientation == .portrait ? portraitScreenWidth : portraitScreenHeight
        let contentHeight = window.orientation == .portrait ? portraitScreenHeight : portraitScreenWidth

        return ZStack {
            SimulatorWebView(window: window)
                .clipShape(RoundedRectangle(cornerRadius: min(contentWidth, contentHeight) * 0.05))
                .frame(width: contentWidth, height: contentHeight)
                .position(x: screenCenterX, y: screenCenterY)
                .frame(width: portraitScreenWidth, height: portraitScreenHeight)
                .position(x: screenCenterX, y: screenCenterY)
                .clipped()

            Image(window.deviceType.frameImageName)
                .resizable()
                .frame(width: portraitDisplaySize.width, height: portraitDisplaySize.height)
        }
        .frame(width: portraitDisplaySize.width, height: portraitDisplaySize.height)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }

    // MARK: Size controls — plain +/- buttons, no drag handle.
    private var sizeControls: some View {
        HStack(spacing: 14) {
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
        .frame(height: 26)
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
                ToolbarItem(placement: .navigationBarTrailing) {
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
                // Always mounted — minimizing only hides/shrinks it, it's
                // never removed from the tree, so the WKWebView inside
                // never gets destroyed and recreated (which would reload
                // the page).
                SimulatorDeviceFrameView(window: window, onClose: { manager.close(window) })
                    .environmentObject(manager)
                    .opacity(window.isMinimized ? 0 : 1)
                    .scaleEffect(window.isMinimized ? 0.01 : 1, anchor: .topLeading)
                    .allowsHitTesting(!window.isMinimized)

                if window.isMinimized {
                    SimulatorMinimizedDockView(window: window)
                }
            }
        }
        // With no windows open, this overlay must not swallow taps meant
        // for the rest of the app underneath it.
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
