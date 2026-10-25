import SwiftUI
import VisionKit

/// Live QR scanner for the dashboard's pair-a-device card. Wraps VisionKit's
/// `DataScannerViewController` restricted to QR codes; the first QR payload is
/// handed back (parsing/validation happens in the caller via `PairingPayload`).
/// Presenting it triggers the camera-permission prompt (`NSCameraUsageDescription`).
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    /// Whether this device can run the live scanner at all.
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        try? vc.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: QRScannerView
        private var handled = false
        init(_ parent: QRScannerView) { self.parent = parent }

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            deliverFirstQR(in: addedItems)
        }

        func dataScanner(_ scanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            deliverFirstQR(in: [item])
        }

        private func deliverFirstQR(in items: [RecognizedItem]) {
            guard !handled else { return }
            for case let .barcode(barcode) in items {
                if let value = barcode.payloadStringValue {
                    handled = true
                    parent.onScan(value)
                    return
                }
            }
        }
    }
}
