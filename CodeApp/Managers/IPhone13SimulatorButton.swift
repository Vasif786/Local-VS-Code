import SwiftUI

struct IPhone13SimulatorButton: View {

    @State private var showSimulator = false

    var body: some View {
        Button {
            showSimulator = true
        } label: {
            Label("iPhone 13", systemImage: "iphone")
        }
        .sheet(isPresented: $showSimulator) {
            IPhone13TestScreen()
        }
    }
}