//
//  SimulatorExtension.swift
//  Code
//

import SwiftUI

final class SimulatorExtension: CodeAppExtension {

    override func onInitialize(
        app: MainApp,
        contribution: CodeAppExtension.Contribution
    ) {

        contribution.toolBar.registerItem(
            item: ToolbarItem(
                extenionID:
                    "simulator.button",

                icon: "iphone",

                onClick: {

                    SimulatorManager
                        .shared
                        .showDevicePicker = true
                },

                shouldDisplay: { _ in
                    true
                }
            )
        )
    }
}