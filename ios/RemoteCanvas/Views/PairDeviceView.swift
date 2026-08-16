import SwiftUI
import VisionKit

struct PairDeviceView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var computerName = "Windows PC"
    @State private var endpoint = "https://"
    @State private var pairingCode = ""
    @State private var errorMessage: String?
    @State private var isPairing = false
    @State private var presentedSheet: PresentedSheet?
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        presentedSheet = .qrScanner
                    } label: {
                        Label("Scan QR", systemImage: "qrcode.viewfinder")
                    }
                    .disabled(!DataScannerViewController.isSupported || !DataScannerViewController.isAvailable)
                }

                Section {
                    TextField("Name", text: $computerName)
                        .focused($focusedField, equals: .name)
                    TextField("https://192.168.x.x:47831", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .endpoint)
                    TextField("Code", text: $pairingCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .focused($focusedField, equals: .code)
                        .onChange(of: pairingCode) { _, newValue in
                            pairingCode = String(newValue.filter(\.isNumber).prefix(6))
                        }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isPairing ? "Adding…" : "Add") {
                        Task { await register() }
                    }
                    .fontWeight(.semibold)
                    .disabled(endpoint.isEmpty || pairingCode.count != 6 || isPairing)
                    .accessibilityIdentifier("confirm-pairing")
                }
            }
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .qrScanner:
                    QRScannerSheet { payload in
                        handleScannedPayload(payload)
                    }
                }
            }
        }
    }

    private func register() async {
        guard pairingCode.count == 6 else {
            errorMessage = "Enter the 6-digit code from Windows."
            return
        }
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }

        do {
            let result = try await LiveRemoteSession.exchangePairingCode(
                endpoints: [endpoint.trimmingCharacters(in: .whitespacesAndNewlines)],
                code: pairingCode,
                certSha256: nil
            )
            try appModel.registerDevice(
                name: computerName,
                endpoints: result.endpoints,
                accessToken: result.accessToken,
                certSha256: result.certSha256
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func registerScanned(_ pairing: PairingQRCode) async {
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }
        do {
            let result = try await LiveRemoteSession.exchangePairingCode(
                endpoints: pairing.resolvedEndpoints,
                code: pairing.code,
                certSha256: pairing.certSha256
            )
            try appModel.registerDevice(
                name: pairing.name,
                endpoints: result.endpoints,
                accessToken: result.accessToken,
                certSha256: result.certSha256
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleScannedPayload(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let pairing = try? JSONDecoder().decode(PairingQRCode.self, from: data),
              pairing.version == 1 || pairing.version == 2 else {
            errorMessage = "Not a RemoteCanvas QR code."
            return
        }
        computerName = pairing.name
        endpoint = pairing.resolvedEndpoints.first ?? pairing.endpoint ?? endpoint
        pairingCode = pairing.code
        presentedSheet = nil
        Task { await registerScanned(pairing) }
    }
}

private extension PairDeviceView {
    enum PresentedSheet: String, Identifiable {
        case qrScanner
        var id: String { rawValue }
    }

    enum Field {
        case name
        case endpoint
        case code
    }
}

private struct PairingQRCode: Decodable {
    let version: Int
    let name: String
    let code: String
    let certSha256: String?
    let endpoint: String?
    let endpoints: [String]?

    var resolvedEndpoints: [String] {
        if let endpoints, !endpoints.isEmpty { return endpoints }
        if let endpoint { return [endpoint] }
        return []
    }
}

private struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                QRDataScanner { payload in
                    onScan(payload)
                    dismiss()
                }
                .ignoresSafeArea()

                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white, lineWidth: 2)
                    .frame(width: 240, height: 240)
            }
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct QRDataScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var hasScanned = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasScanned else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue {
                    hasScanned = true
                    onScan(payload)
                    return
                }
            }
        }
    }
}

#Preview {
    PairDeviceView()
        .environment(AppModel(devices: []))
}
