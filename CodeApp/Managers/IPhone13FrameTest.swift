import SwiftUI

struct IPhone13FrameTest: View {

    let url: URL

    var body: some View {
        ZStack {

            // iPhone body
            RoundedRectangle(cornerRadius: 46)
                .fill(Color.black)
                .frame(
                    width: 390,
                    height: 780
                )

            // Screen
            IPhone13WebViewTest(url: url)
                .frame(
                    width: 368,
                    height: 758
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 40
                    )
                )

            // Dynamic Island
            VStack {
                Capsule()
                    .fill(Color.black)
                    .frame(
                        width: 105,
                        height: 30
                    )
                    .padding(.top, 10)

                Spacer()
            }
            .frame(
                width: 368,
                height: 758
            )

            // Left buttons
            VStack(spacing: 12) {

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black)
                    .frame(
                        width: 5,
                        height: 55
                    )

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black)
                    .frame(
                        width: 5,
                        height: 30
                    )

            }
            .offset(
                x: -197,
                y: -40
            )

            // Right power button
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black)
                .frame(
                    width: 5,
                    height: 75
                )
                .offset(
                    x: 197,
                    y: 0
                )
        }
        .frame(
            width: 410,
            height: 800
        )
        .shadow(
            radius: 20
        )
    }
}