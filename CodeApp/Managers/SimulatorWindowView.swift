//
//  SimulatorWindowView.swift
//  Code
//
//  Rendering for one floating simulator window. See SimulatorManager.swift
//  for the underlying state model.
//

import SwiftUI
import WebKit

/// Thin WKWebView wrapper. Reloads ONLY when `reloadToken` changes or the
/// URL itself changes — never on ordinary SwiftUI re-renders (dragging,
/// resizing, rotating), so the loaded page's state isn't lost by those.
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

/// The floating device frame: mini control bar + bezel + web view.
/// Deliberately never removed from the view hierarchy while its window
/// still exists (see `SimulatorWindowsOverlay`) — minimizing only shrinks
/// and hides it, so `SimulatorWebView` (and the WKWebView inside it) is
/// never destroyed/recreated, which is what keeps the loaded page intact.
struct SimulatorDeviceFrameView: View {
    @ObservedObject var window: SimulatorWindowState
    let onClose: () -> Void

    @State private var dragTranslation: CGSize = .zero
    @State private var resizeStartScale: CGFloat = 0.45
    @State private var showSettings = false
    @EnvironmentObject var simulatorManager: SimulatorManager

    private var logicalSize: CGSize {
        let base = window.deviceType.portraitSize
        return window.orientation == .portrait
            ? base : CGSize(width: base.height, height: base.width)
    }

    private var displaySize: CGSize {
        CGSize(
            width: logicalSize.width * window.displayScale,
            height: logicalSize.height * window.displayScale)
    }

    var body: some View {
        VStack(spacing: 6) {
            controlBar
            deviceBezel
            resizeHandle
        }
        .position(
            x: window.position.x + dragTranslation.width,
            y: window.position.y + dragTranslation.height
        )
        .popover(isPresented: $showSettings) {
            SimulatorSettingsView(deviceType: window.deviceType)
                .environmentObject(simulatorManager)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            Text(window.deviceType.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
            }
            Button { window.reloadToken = UUID() } label: {
                Image(systemName: "arrow.clockwise")
            }
            Button { window.orientation = window.orientation == .portrait ? .landscape : .portrait } label: {
                Image(systemName: "rotate.right")
            }
            Button { window.isMinimized = true } label: {
                Image(systemName: "minus.circle.fill")
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
            }
        }
        .font(.system(size: 13))
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .frame(width: displaySize.width, height: 28)
        .background(Color.black.opacity(0.88))
        .clipShape(Capsule())
        // Only the control bar drags the window — dragging inside the web
        // view itself should scroll the page, not move the window.
        .gesture(
            DragGesture()
                .onChanged { dragTranslation = $0.translation }
                .onEnded { value in
                    window.position.x += value.translation.width
                    window.position.y += value.translation.height
                    dragTranslation = .zero
                }
        )
    }

    private var deviceBezel: some View {
        let insets = window.deviceType.screenInsets
        let portraitDisplaySize = CGSize(
            width: window.deviceType.portraitSize.width * window.displayScale,
            height: window.deviceType.portraitSize.height * window.displayScale)
        let screenWidth = portraitDisplaySize.width * (1 - insets.left - insets.right)
        let screenHeight = portraitDisplaySize.height * (1 - insets.top - insets.bottom)
        let screenCenterX = portraitDisplaySize.width * (insets.left + (1 - insets.left - insets.right) / 2)
        let screenCenterY = portraitDisplaySize.height * (insets.top + (1 - insets.top - insets.bottom) / 2)

        return ZStack {
            SimulatorWebView(window: window)
                .clipShape(RoundedRectangle(cornerRadius: screenWidth * 0.06))
                .frame(width: screenWidth, height: screenHeight)
                .position(x: screenCenterX, y: screenCenterY)

            // The real device frame — its transparent "screen hole" (see
            // SimulatorManager.screenInsets, measured from this exact
            // image) lines up with the web view positioned above.
            Image(window.deviceType.frameImageName)
                .resizable()
                .frame(width: portraitDisplaySize.width, height: portraitDisplaySize.height)
        }
        .frame(width: portraitDisplaySize.width, height: portraitDisplaySize.height)
        // Rotate the whole portrait-shaped composition as one piece for
        // landscape, rather than stretching the frame image into a
        // landscape box — keeps the device frame looking correct (not
        // squished) in both orientations.
        .rotationEffect(.degrees(window.orientation == .landscape ? 90 : 0))
        .frame(width: displaySize.width, height: displaySize.height)
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }

    private var resizeHandle: some View {
        HStack {
            Spacer()
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
                .padding(7)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let delta = (value.translation.width + value.translation.height) / 2
                            window.displayScale = min(max(resizeStartScale + delta / 500, 0.28), 1.1)
                        }
                        .onEnded { _ in resizeStartScale = window.displayScale }
                )
        }
        .frame(width: displaySize.width)
    }
}

private struct SimulatorSettingsView: View {
    let deviceType: SimulatorDeviceType
    @EnvironmentObject var simulatorManager: SimulatorManager
    @Environment(\.dismiss) private var dismiss
    @State private var urlText: String = ""

    var body: some View {
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
        }
        .padding()
        .frame(width: 300)
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
        .position(x: window.position.x, y: window.position.y)
    }
}

/// Renders every open simulator window, plus the iPhone/iPad picker sheet
/// triggered from the toolbar. Add this once near the top of the app's
/// main view hierarchy (see MainScene.swift), above everything else, the
/// same way `NotificationCentreView` is already added there.
struct SimulatorWindowsOverlay: View {
    @ObservedObject var manager = SimulatorManager.shared

    var body: some View {
        ZStack {
            ForEach(manager.windows) { window in
                // Always mounted — minimizing only hides/shrinks it, it's
                // never removed from the tree, so the WKWebView inside
                // never gets destroyed and recreated (which would reload
                // the page). See the file header for why.
                SimulatorDeviceFrameView(window: window, onClose: { manager.close(window) })
                    .environmentObject(manager)
                    .opacity(window.isMinimized ? 0 : 1)
                    .scaleEffect(window.isMinimized ? 0.01 : 1)
                    .allowsHitTesting(!window.isMinimized)

                if window.isMinimized {
                    SimulatorMinimizedDockView(window: window)
                }
            }
        }
        .confirmationDialog(
            "Open Simulator", isPresented: $manager.showDevicePicker, titleVisibility: .visible
        ) {
            Button("iPhone") { manager.open(deviceType: .iPhone13Pro) }
            Button("iPad") { manager.open(deviceType: .iPadPro) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
