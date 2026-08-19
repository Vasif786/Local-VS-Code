import SwiftUI

class SimulatorExtension: CodeAppExtension {

    override func onInitialize(
        app: MainApp,
        contribution: CodeAppExtension.Contribution
    ) {

        // Existing Simulator button
        contribution.toolBar.registerItem(
            item: ToolbarItem(
                extenionID: "simulator.button",
                icon: "iphone",
                onClick: {
                    SimulatorManager.shared.showDevicePicker = true
                },
                shouldDisplay: { _ in true }
            )
        )

        // NEW iPhone 13 button
        contribution.toolBar.registerItem(
            item: ToolbarItem(
                extenionID: "iphone13.button",
                icon: "iphone",
                onClick: {
                    SimulatorManager.shared.showIPhone13 = true
                },
                shouldDisplay: { _ in true }
            )
        )
    }
}