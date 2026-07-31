//
//  ToolbarManager.swift
//  Code
//
//  Created by Ken Chung on 14/11/2022.
//

import SwiftUI

struct ToolbarItem: Identifiable {
    let id = UUID()
    var extenionID: String
    var icon: String
    var secondaryIcon: String?
    var onClick: () -> Void
    var shortCut: KeyboardShortcut?
    var panelToFocusOnTap: String?
    var shouldDisplay: (MainApp) -> Bool
    /// Defaults to always-enabled so existing contributions compile unchanged.
    var isEnabled: (MainApp) -> Bool = { _ in true }
}

class ToolbarManager: CodeAppContributionPointManager {
    @Published var items: [ToolbarItem] = []
}
