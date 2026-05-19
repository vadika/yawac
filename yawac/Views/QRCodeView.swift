import SwiftUI
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    let payload: String

    var body: some View {
        if let img = make(payload) {
            Image(nsImage: img)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 280, height: 280)
                .padding()
                .background(.background)
                .clipShape(.rect(cornerRadius: 12))
        } else {
            ProgressView()
        }
    }

    private func make(_ s: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(s.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: .init(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
