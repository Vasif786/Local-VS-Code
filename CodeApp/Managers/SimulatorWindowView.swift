//
//  SimulatorWindowView.swift
//  Code
//

import SwiftUI
import WebKit

// MARK: - Interactive WebView

private struct SimulatorWebView: UIViewRepresentable {
    @ObservedObject var window: SimulatorWindowState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = false

        // Explicitly keep the WKWebView interactive.
        webView.isUserInteractionEnabled = true
        webView.scrollView.isUserInteractionEnabled = true

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

            if lastURL != url || lastToken != token {
                lastURL = url
                lastToken = token
                webView.load(URLRequest(url: url))
            }
        }
    }
}

// MARK: - Frame

struct SimulatorDeviceFrameView: View {
    @ObservedObject var window: SimulatorWindowState
    let onClose: () -> Void

    @State private var showSettings = false
    @State private var showPositionMenu = false
    @State private var dragStart: CGPoint?
    @EnvironmentObject private var simulatorManager: SimulatorManager

    private static let minScale: CGFloat = 0.30
    private static let maxScale: CGFloat = 1.25
    private static let resizeStep: CGFloat = 0.05
    private static let barWidth: CGFloat = 220
    private static let rowHeight: CGFloat = 30

    private var frameSize: CGSize {
        SimulatorLayout.frameSize(for: window)
    }

    private var screenRect: CGRect {
        SimulatorLayout.screenRect(for: window)
    }

    var body: some View {
        VStack(spacing: 6) {
            titleBar
            controls
            simulatorScreen
            zoomBar
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
        .confirmationDialog(
            "Simulator Position",
            isPresented: $showPositionMenu,
            titleVisibility: .visible
        ) {
            ForEach(SimulatorPositionPreset.allCases) { preset in
                Button(preset.title) {
                    // Use the parent view size if available. The GeometryReader
                    // below supplies it through the position helper.
                    positionUsingPreset(preset)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Title / drag

    private var titleBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))

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
        .frame(width: max(Self.barWidth, frameSize.width), height: Self.rowHeight)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
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
        )
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 14) {
            simulatorButton("gearshape.fill") {
                showSettings = true
            }

            simulatorButton("arrow.clockwise") {
                window.reloadToken = UUID()
            }

            simulatorButton("rotate.right") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    window.orientation =
                        window.orientation == .portrait ? .landscape : .portrait
                }
            }

            simulatorButton("location.fill") {
                showPositionMenu = true
            }

            simulatorButton("arrow.up.left.and.arrow.down.right") {
                window.displayScale = 1.0
            }

            simulatorButton("minus.circle.fill") {
                window.isMinimized = true
            }

            simulatorButton("xmark.circle.fill", action: onClose)
        }
        .frame(width: max(Self.barWidth, frameSize.width), height: Self.rowHeight)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func simulatorButton(
        _ image: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 25, height: 25)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Actual simulator

    private var simulatorScreen: some View {
        ZStack(alignment: .topLeading) {
            // IMPORTANT:
            // The WKWebView is the hit-testable layer.
            // The frame image below has allowsHitTesting(false), so it can
            // never steal taps/clicks from the webpage.
            SimulatorWebView(window: window)
                .frame(width: screenRect.width, height: screenRect.height)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: min(screenRect.width, screenRect.height) * 0.045
                    )
                )
                .position(
                    x: screenRect.midX,
                    y: screenRect.midY
                )
                .zIndex(1)

            Image(window.deviceType.frameImageName)
                .resizable()
                .aspectRatio(window.deviceType.frameAspectRatio, contentMode: .fit)
                .frame(width: frameSize.width, height: frameSize.height)
                .rotationEffect(.degrees(window.orientation == .landscape ? -90 : 0))
                .allowsHitTesting(false)
                .zIndex(2)
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .clipped()
        .contentShape(Rectangle())
    }

    // MARK: Zoom

    private var zoomBar: some View {
        HStack(spacing: 16) {
            simulatorButton("minus.magnifyingglass") {
                window.displayScale = max(
                    Self.minScale,
                    window.displayScale - Self.resizeStep
                )
            }

            Text("\(Int(window.displayScale * 100))%")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .frame(minWidth: 42)

            simulatorButton("plus.magnifyingglass") {
                window.displayScale = min(
                    Self.maxScale,
                    window.displayScale + Self.resizeStep
                )
            }
        }
        .padding(.horizontal, 10)
        .frame(width: max(Self.barWidth, frameSize.width), height: Self.rowHeight)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Position helper

    private func positionUsingPreset(_ preset: SimulatorPositionPreset) {
        // The simulator is floating in the parent coordinate space. Since
        // SwiftUI does not expose that size here directly, use the screen
        // bounds as a safe approximation and clamp to positive coordinates.
        let screen = UIScreen.main.bounds.size
        simulatorManager.setPosition(preset, for: window, in: screen)
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
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)

                    Button("Save & Reload") {
                        guard
                            let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
                            url.scheme != nil
                        else { return }

                        simulatorManager.saveURL(url, for: deviceType)
                        dismiss()
                    }
                    .disabled(
                        URL(
                            string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                        )?.scheme == nil
                    )
                }

                Section("Simulator") {
                    Text("Device: \(deviceType.displayName)")
                    Text("Web content is interactive. Tap, scroll, type and use links normally.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Simulator Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SwiftUI.ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            urlText =
                simulatorManager.urlDrafts[deviceType]
                ?? simulatorManager.savedURL(for: deviceType).absoluteString
        }
    }
}

// MARK: - Minimized

private struct SimulatorMinimizedDockView: View {
    @ObservedObject var window: SimulatorWindowState

    var body: some View {
        Button {
            window.isMinimized = false
        } label: {
            VStack(spacing: 3) {
                Image(systemName: window.deviceType.sfSymbol)
                    .font(.system(size: 20))

                Text(window.deviceType.displayName)
                    .font(.system(size: 9))
                    .lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(10)
            .frame(width: 90)
            .background(Color.black.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 6)
        }
        .buttonStyle(.plain)
        .offset(x: window.position.x, y: window.position.y)
    }
}

// MARK: - Overlay

struct SimulatorWindowsOverlay: View {
    @ObservedObject var manager = SimulatorManager.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(manager.windows) { window in
                if window.isMinimized {
                    SimulatorMinimizedDockView(window: window)
                } else {
                    SimulatorDeviceFrameView(
                        window: window,
                        onClose: { manager.close(window) }
                    )
                    .environmentObject(manager)
                }
            }
        }
        // Do NOT put a full-screen .allowsHitTesting(true) overlay over the
        // editor. The individual WKWebView receives touches itself.
        .allowsHitTesting(true)
        .confirmationDialog(
            "Open Simulator",
            isPresented: $manager.showDevicePicker,
            titleVisibility: .visible
        ) {
            Button("iPhone 14 Pro") {
                manager.open(deviceType: .iPhone14Pro)
            }

            Button("iPad Pro") {
                manager.open(deviceType: .iPadPro)
            }

            Button("Cancel", role: .cancel) {}
        }
    }
}
