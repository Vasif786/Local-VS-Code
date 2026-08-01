//
//  RemoteRunExtension.swift
//  Code
//
//  Wires the Run/Stop button and its status bar indicator into the
//  existing extension/contribution system (see CodeAppExtension,
//  ToolbarManager, StatusBarManager). All execution logic lives in
//  MainApp.remoteExecutionManager — this file only registers UI
//  contribution points and forwards taps to it.
//

import Combine
import SwiftUI

class RemoteRunExtension: CodeAppExtension {

    private var runToolbarItemId: UUID?
    private var cancellables = Set<AnyCancellable>()

    override func onInitialize(app: MainApp, contribution: CodeAppExtension.Contribution) {
        registerToolbarItem(app: app, contribution: contribution)

        contribution.statusBar.registerItem(
            item: StatusBarItem(
                extensionID: "remoteRun.status",
                view: AnyView(RemoteRunStatusView(manager: app.remoteExecutionManager)),
                shouldDisplay: { mainApp in
                    mainApp.workSpaceStorage.remoteConnected
                        && mainApp.remoteExecutionManager.state != .idle
                },
                positionPreference: .left
            )
        )

        // ToolbarItem's icon is fixed at registration time, so swap the
        // registered item whenever the run/stop state actually changes.
        app.remoteExecutionManager.$state
            .removeDuplicates()
            .sink { [weak self, weak app] _ in
                guard let self = self, let app = app else { return }
                self.registerToolbarItem(app: app, contribution: contribution)
            }
            .store(in: &cancellables)
    }

    private func registerToolbarItem(app: MainApp, contribution: CodeAppExtension.Contribution) {
        if let existingId = runToolbarItemId {
            contribution.toolBar.deregisterItem(id: existingId)
        }

        let isRunning = app.remoteExecutionManager.isRunning
        let item = ToolbarItem(
            extenionID: "remoteRun.button",
            icon: isRunning ? "stop.fill" : "play.fill",
            onClick: { [weak app] in
                guard let app = app else { return }
                if app.remoteExecutionManager.isRunning {
                    app.remoteExecutionManager.stop(app: app)
                } else {
                    Task { await app.remoteExecutionManager.runCurrentFile(app: app) }
                }
            },
            shouldDisplay: { mainApp in
                mainApp.remoteExecutionManager.shouldShowRunButton(app: mainApp)
            },
            isEnabled: { mainApp in
                mainApp.remoteExecutionManager.isRunButtonEnabled(app: mainApp)
            }
        )

        contribution.toolBar.registerItem(item: item)
        runToolbarItemId = item.id
    }
}

/// Status bar contents for the Run/Stop feature: Running… / Finished (exit
/// code, duration) / an error message. Reactive on its own via
/// `@ObservedObject`, independent of the toolbar re-registration above.
private struct RemoteRunStatusView: View {
    @ObservedObject var manager: RemoteExecutionManager

    var body: some View {
        switch manager.state {
        case .idle:
            EmptyView()
        case .running(_, let command):
            Text("Running: \(command)")
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(Color.init("statusBar.foreground"))
        case .finished(let exitCode, let duration):
            Text("Finished · Exit \(exitCode) · \(String(format: "%.1fs", duration))")
                .font(.system(size: 12))
                .foregroundColor(Color.init("statusBar.foreground"))
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.red)
        }
    }
}
