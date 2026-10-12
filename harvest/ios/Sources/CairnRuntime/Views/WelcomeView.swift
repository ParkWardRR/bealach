import SwiftUI

public struct WelcomeView: View {
    @State private var page = 0
    let onFinish: () -> Void

    public init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    private let pages: [(symbol: String, title: String, body: String, accent: Color)] = [
        ("car.side.rear.and.collision.and.car.side.front",
         "Your driving log",
         "Cairn is a small dongle that plugs into your car's OBD-II port. It records GPS position, speed, engine data, and more — every drive, automatically.",
         .blue),
        ("iphone.radiowaves.left.and.right",
         "This app connects to it",
         "Your phone pairs with the dongle over Bluetooth. It sends your phone's GPS to improve accuracy, and shows live data while you drive.",
         .green),
        ("lock.shield",
         "Your data stays yours",
         "Everything is stored on your own server — you choose where. The app works fully offline too. No accounts, no cloud services, no tracking.",
         .purple),
    ]

    public var body: some View {
        VStack(spacing: 0) {
            let p = pages[page]
            WelcomePage(symbol: p.symbol, title: p.title, message: p.body, accent: p.accent)
                .id(page)
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            HStack(spacing: 8) {
                ForEach(0..<pages.count, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, 24)

            VStack(spacing: 12) {
                if page == pages.count - 1 {
                    Button(action: onFinish) {
                        Text("Get Started")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) { page += 1 }
                    } label: {
                        Text("Next")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .background(Backdrop().ignoresSafeArea())
    }
}

private struct WelcomePage: View {
    let symbol: String
    let title: String
    let message: String
    let accent: Color

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: symbol)
                .font(.system(size: 64))
                .foregroundStyle(accent)
                .symbolRenderingMode(.hierarchical)

            Text(title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
            Spacer()
        }
    }
}
