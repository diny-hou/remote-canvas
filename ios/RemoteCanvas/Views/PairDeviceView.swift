import SwiftUI
import VisionKit

struct PairDeviceView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var computerName = "Windows PC"
    @State private var endpoint = "http://"
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
                        Label("QRコードを読み取る", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(!DataScannerViewController.isSupported || !DataScannerViewController.isAvailable)
                } footer: {
                    Text("Windows版で「端末を追加」を押して表示されたQRコードを読み取ります。")
                }

                Section("6桁コードで追加") {
                    TextField("PC名", text: $computerName)
                        .focused($focusedField, equals: .name)
                    TextField("接続先（例: http://100.x.x.x:47831）", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .endpoint)
                    TextField("6桁コード", text: $pairingCode)
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
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {} footer: {
                    Text("外出先から接続する場合は、両方の端末を同じTailscaleネットワークへ登録し、Windows側の100.xアドレスを入力します。")
                }
            }
            .navigationTitle("PCをペアリング")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isPairing ? "登録中…" : "登録") {
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
            errorMessage = "Windowsに表示された6桁コードを入力してください。"
            return
        }
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }

        do {
            let accessToken = try await LiveRemoteSession.exchangePairingCode(
                endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                code: pairingCode
            )
            try appModel.registerDevice(name: computerName, endpoint: endpoint, accessToken: accessToken)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleScannedPayload(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let pairing = try? JSONDecoder().decode(PairingQRCode.self, from: data),
              pairing.version == 1 else {
            errorMessage = "RemoteCanvasのQRコードではありません。"
            return
        }
        computerName = pairing.name
        endpoint = pairing.endpoint
        pairingCode = pairing.code
        presentedSheet = nil
        Task { await register() }
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
    let endpoint: String
    let code: String
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

                RoundedRectangle(cornerRadius: 22)
                    .stroke(.white, lineWidth: 3)
                    .frame(width: 240, height: 240)
                    .shadow(color: .black.opacity(0.4), radius: 8)
            }
            .navigationTitle("QRコードを読み取る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
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
