import SwiftUI

struct IPhone13StandalonePreview: View {

    var body: some View {
        GeometryReader { geometry in

            ZStack {
                Color(.systemGray6)
                    .ignoresSafeArea()

                // iPhone ko left side par rakho
                iPhone13Body
                    .frame(width: 390, height: 780)
                    .scaleEffect(
                        min(
                            1.0,
                            (geometry.size.height - 40) / 780
                        )
                    )
                    .position(
                        x: 215,
                        y: geometry.size.height / 2
                    )
            }
        }
    }

    private var iPhone13Body: some View {
        ZStack {

            // MARK: - Outer iPhone body

            RoundedRectangle(cornerRadius: 48)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(white: 0.08),
                            Color.black,
                            Color(white: 0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 48)
                        .stroke(
                            Color(white: 0.30),
                            lineWidth: 2
                        )
                )

            // MARK: - Screen

            RoundedRectangle(cornerRadius: 42)
                .fill(Color.black)
                .frame(width: 366, height: 756)
                .overlay {

                    RoundedRectangle(cornerRadius: 38)
                        .fill(Color(.systemBackground))
                        .frame(width: 358, height: 748)
                }

            // MARK: - Notch

            VStack {
                Capsule()
                    .fill(Color.black)
                    .frame(width: 125, height: 32)
                    .overlay {

                        HStack(spacing: 14) {
                            Circle()
                                .fill(Color(white: 0.08))
                                .frame(
                                    width: 12,
                                    height: 12
                                )

                            Circle()
                                .fill(Color(white: 0.04))
                                .frame(
                                    width: 18,
                                    height: 18
                                )
                        }
                    }
                    .padding(.top, 12)

                Spacer()
            }
            .frame(width: 358, height: 748)

            // MARK: - Left volume buttons

            VStack(spacing: 14) {

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(white: 0.35),
                                Color(white: 0.08)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 6, height: 42)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(white: 0.35),
                                Color(white: 0.08)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 6, height: 42)
            }
            .position(x: 3, y: 315)

            // MARK: - Silent switch

            Capsule()
                .fill(Color(white: 0.18))
                .frame(width: 6, height: 26)
                .position(x: 3, y: 245)

            // MARK: - Right power button

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(white: 0.35),
                            Color(white: 0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 6, height: 82)
                .position(x: 387, y: 350)

            // MARK: - Screen reflection

            RoundedRectangle(cornerRadius: 42)
                .stroke(
                    Color.white.opacity(0.12),
                    lineWidth: 1
                )
                .frame(width: 366, height: 756)
        }
        .shadow(
            color: .black.opacity(0.35),
            radius: 25,
            x: 10,
            y: 15
        )
    }
}