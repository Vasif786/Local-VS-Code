import SwiftUI

struct IPhone13TestScreen: View {

    private let url = URL(
        string: "http://10.103.60.191:8080"
    )!

    var body: some View {
        ZStack {
            Color.gray
                .ignoresSafeArea()

            IPhone13FrameTest(url: url)
        }
    }
}