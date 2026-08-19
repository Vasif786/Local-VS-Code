import SwiftUI

struct IPhone13FrameTestPreview: View {

    var body: some View {
        IPhone13FrameTest(
            url: URL(
                string: "http://10.103.60.191:8080"
            )!
        )
    }
}

#Preview {
    IPhone13FrameTestPreview()
}