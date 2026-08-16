//
//  SimulatorExtension.swift
//  Code
//
//  Registers the phone-icon toolbar button that opens the iPhone/iPad
//  picker. Works for both local and SSH-connected projects — the
//  simulator is just a web view in a device frame, unrelated to the
//  workspace connection type — so unlike the Run button it has no
//  connection-based visibility guard.
//

import SwiftUI

class SimulatorExtension: CodeAppExtension {
    override func onInitialize(app: MainApp, contribution: CodeAppExtension.Contribution) {
        contribution.toolBar.registerItem(
            item: ToolbarItem(
                extenionID: "simulator.button",
                icon: "iphone",
                onClick: {
                    SimulatorManager.shared.showDevicePicker = true
                },
                shouldDisplay: { _ in true }
            ))
    }
}
