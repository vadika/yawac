import SwiftUI

struct LoginView: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair yawac")
                .font(.title2).bold()
            Text("On your phone: WhatsApp → Settings → Linked Devices → Link a Device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            if let code = session.qrCode {
                QRCodeView(payload: code)
            } else {
                ProgressView("Waiting for QR…")
            }
        }
        .padding(40)
    }
}
