//
//  SimulatorWindowView.swift
//  Code
//

import SwiftUI
import WebKit

// MARK: - Interactive WebView

/// WKWebView always uses the real device's logical viewport. We then scale
/// the complete device visually. Therefore changing the simulator size does
/// NOT change the website's CSS viewport or button dimensions.
private struct SimulatorWebView: UIViewRepresentable {
    @ObservedObject var window: SimulatorWindowState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.isUserInteractionEnabled = true
        webView.scrollView.isUserInteractionEnabled = true
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        // A real device viewport should not be automatically enlarged or
        // shrunk to the surrounding frame.
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.zoomScale = 1.0

        context.coordinator.webView = webView
        context.coordinator.loadIfNeeded(url: window.url, token: window.reloadToken)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadIfNeeded(url: window.url, token: window.reloadToken)
    }

    final class Coordinator {
        weak var webView: WKWebView?
        private var lastURL: URL?
        private var lastToken: UUID?

        func loadIfNeeded(url: URL, token: UUID) {
            guard let webView else { return }
            guard lastURL != url || lastToken != token else { return }

            lastURL = url
            lastToken = token
            webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy))
        }
    }
}

// MARK: - Device frame

struct SimulatorDeviceFrameView: View {
    @ObservedObject var window: SimulatorWindowState
    let onClose: () -> Void

    @State private var showSettings = false
    @State private var dragStart: CGPoint?
    @EnvironmentObject private var simulatorManager: SimulatorManager

    private static let minScale: CGFloat = 0.30
    private static let maxScale: CGFloat = 1.25
    private static let resizeStep: CGFloat = 0.05
    private static let controlHeight: CGFloat = 32

    private var frameSize: CGSize {
        SimulatorLayout.frameSize(for: window)
    }

    private var portraitFrameSize: CGSize {
        SimulatorLayout.portraitFrameSize(for: window)
    }

    private var portraitScreenRect: CGRect {
        SimulatorLayout.portraitScreenRect(for: window)
    }

    private var logicalViewport: CGSize {
        window.deviceType.viewportSize
    }

    var body: some View {
        VStack(spacing: 6) {
            titleBar
            topControls
            zoomBar
            deviceView
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color("sideBar.background"))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        )
        .offset(x: window.position.x, y: window.position.y)
        .sheet(isPresented: $showSettings) {
            SimulatorSettingsView(deviceType: window.deviceType)
                .environmentObject(simulatorManager)
        }
    }

    // MARK: Title

    private var titleBar: some View {
        HStack(spacing: 7) {
            Image(systemName: window.isMoveMode ? "hand.draw.fill" : "lock.fill")
                .font(.system(size: 11))
                .foregroundColor(window.isMoveMode ? .white : .white.opacity(0.55))

            Text(window.deviceType.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(window.orientation.title)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(.horizontal, 10)
        .frame(height: Self.controlHeight)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .gesture(moveGesture)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                // Position is locked unless the move button is enabled.
                guard window.isMoveMode else { return }

                if dragStart == nil {
                    dragStart = window.position
                }

                guard let start = dragStart else { return }
                window.position = CGPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height
                )
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    // MARK: Controls

    /// The move/location button is a LOCK switch:
    ///  - unlocked: drag the title bar to reposition
    ///  - locked: dragging does nothing
    /// Pressing the same button again saves/locks the current position.
    private var topControls: some View {
        HStack(spacing: 14) {
            simulatorButton("gearshape.fill") {
                showSettings = true
            }

            simulatorButton("arrow.clockwise") {
                window.reloadToken = UUID()
            }

            simulatorButton(
                window.orientation == .portrait ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate"
            ) {
                withAnimation(.easeInOut(duration: 0.22)) {
                    window.orientation =
                        window.orientation == .portrait ? .landscape : .portrait
                }
            }

            simulatorButton(window.isMoveMode ? "lock.open.fill" : "location.fill") {
                // No menu/presets. The same button simply toggles move/lock.
                withAnimation(.easeOut(duration: 0.12)) {
                    window.isMoveMode.toggle()
                }
            }

            simulatorButton("arrow.up.left.and.arrow.down.right") {
                window.displayScale = 0.70
            }

            simulatorButton("xmark.circle.fill", action: onClose)
        }
        .frame(height: Self.controlHeight)
        .padding(.horizontal, 10)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func simulatorButton(_ image: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 25, height: 25)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Zoom controls

    /// Zoom is deliberately ABOVE the device and the buttons never scale.
    private var zoomBar: some View {
        HStack(spacing: 12) {
            simulatorButton("minus.magnifyingglass") {
                window.displayScale = max(Self.minScale, window.displayScale - Self.resizeStep)
            }

            Text("\(Int(window.displayScale * 100))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 48)

            simulatorButton("plus.magnifyingglass") {
                window.displayScale = min(Self.maxScale, window.displayScale + Self.resizeStep)
            }
        }
        .frame(height: Self.controlHeight)
        .padding(.horizontal, 10)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Device / WebView

    private var deviceView: some View {
        // Build the device in portrait coordinates and rotate THE WHOLE
        // device for landscape. This keeps the WebView and frame perfectly
        // synchronized in both orientations.
        ZStack(alignment: .topLeading) {
            webViewLayer
            Image(window.deviceType.frameImageName)
                .resizable()
                .frame(width: portraitFrameSize.width, height: portraitFrameSize.height)
                .allowsHitTesting(false)
        }
        .frame(width: portraitFrameSize.width, height: portraitFrameSize.height)
        .rotationEffect(
            .degrees(window.orientation == .landscape ? -90 : 0),
            anchor: .center
        )
        .frame(width: frameSize.width, height: frameSize.height)
        .clipped()
    }

    private var webViewLayer: some View {
        // The WebView itself is laid out at the REAL logical viewport size.
        // It is then visually scaled to the frame's screen hole. The scaling
        // happens to the UIView, so WKWebView still receives transformed
        // touches correctly instead of using a different CSS viewport.
        let hole = portraitScreenRect
        let viewport = logicalViewport

        let fitScale = min(
            hole.width / viewport.width,
            hole.height / viewport.height
        )
        let renderedSize = CGSize(
            width: viewport.width * fitScale,
            height: viewport.height * fitScale
        )
        let x = hole.midX - renderedSize.width / 2
        let y = hole.midY - renderedSize.height / 2

        return SimulatorWebView(window: window)
            .frame(width: viewport.width, height: viewport.height)
            .scaleEffect(fitScale, anchor: .topLeading)
            .frame(width: renderedSize.width, height: renderedSize.height)
            .position(
                x: x + renderedSize.width / 2,
                y: y + renderedSize.height / 2
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: max(8, min(renderedSize.width, renderedSize.height) * 0.045)
                )
            )
            .zIndex(1)
    }
}

// MARK: - Settings

private struct SimulatorSettingsView: View {
    let deviceType: SimulatorDeviceType

    @EnvironmentObject private var simulatorManager: SimulatorManager
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Web URL") {
                    TextField("https://example.com", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)

                    Button("Save & Reload") {
                        let value = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let url = URL(string: value), url.scheme != nil else { return }
                        simulatorManager.saveURL(url, for: deviceType)
                        dismiss()
                    }
                    .disabled(
                        URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme == nil
                    )
                }

                Section("Simulator") {
                    Text("Device: \(deviceType.displayName)")
                    Text("Viewport: \(Int(deviceType.viewportSize.width)) × \(Int(deviceType.viewportSize.height))")
                    Text("Changing simulator size only changes the visual size. The website keeps the real device viewport and fixed UI proportions.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Simulator Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SwiftUI.ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            urlText = simulatorManager.urlDrafts[deviceType]
                ?? simulatorManager.savedURL(for: deviceType).absoluteString
        }
    }
}

// MARK: - Overlay

struct SimulatorWindowsOverlay: View {
    @ObservedObject var manager = SimulatorManager.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(manager.windows) { window in
                SimulatorDeviceFrameView(
                    window: window,
                    onClose: { manager.close(window) }
                )
                .environmentObject(manager)
            }
        }
        .allowsHitTesting(true)
        .confirmationDialog(
            "Open Simulator",
            isPresented: $manager.showDevicePicker,
            titleVisibility: .visible
        ) {
            Button("iPhone 14 Pro") {
                manager.open(deviceType: .iPhone14Pro)
            }

            Button("iPad (5th generation)") {
                manager.open(deviceType: .iPadPro)
            }

            Button("Cancel", role: .cancel) {}
        }
    }
}
