import AVFoundation
import SwiftData
import SwiftUI
import UIKit

/// Camera barcode scan for My Bar. Known codes confirm before insert. Unknown codes
/// use the existing add-item sheet. No network lookup.
struct BarcodeScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query(sort: \InventoryItem.name) private var items: [InventoryItem]

    @State private var readiness: BarcodeCameraReadiness?
    @State private var route: ScannerRoute?
    @State private var manualCode = ""
    @State private var manualError: String?
    @State private var scanMessage: String?
    @State private var scanLatch = BarcodeScanLatch()
    @State private var symbologyChoice: BarcodeSymbologyChoice?
    @State private var torchAvailable = false
    @State private var torchOn = false
    @State private var showSaveError = false
    @State private var didRequestPermission = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                switch readiness {
                case .ready:
                    cameraScreen
                case .denied, .restricted, .unavailable:
                    fallbackScreen
                case nil, .needsPermission:
                    ProgressView(readiness == .needsPermission ? "Waiting for camera access…" : "Checking camera…")
                        .font(.body)
                        .foregroundStyle(PourColor.textSecondary)
                        .tint(PourColor.accent)
                        .accessibilityLabel(readiness == .needsPermission ? "Waiting for camera access" : "Checking camera")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PourColor.background)
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityLabel("Close scanner")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .sheet(item: $route, onDismiss: { scanLatch.noteSheetDismissed(now: Date()) }) { route in
                scannerDestination(route)
                    .alert("Bar wasn’t updated", isPresented: $showSaveError) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("Check available device storage and try again.")
                    }
            }
        }
        .task { await prepareCamera() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await prepareCamera() }
            }
        }
    }

    @ViewBuilder
    private func scannerDestination(_ destination: ScannerRoute) -> some View {
        switch destination {
        case .confirm(let draft):
            BarcodeConfirmSheet(draft: draft) { name in
                confirmAdd(name: name, barcode: draft.barcode)
            }
        case .existing(let match):
            BarcodeExistingSheet(match: match) {
                applyExisting(match)
            }
        case .nameEntry(let seed):
            InventoryEditSheet(item: nil, seed: seed) { result in
                switch result {
                case .saved:
                    dismiss()
                case .alreadyInBar(let match):
                    route = .existing(match)
                }
            }
        case .manual:
            BarcodeManualEntrySheet(
                code: $manualCode,
                error: $manualError,
                symbologyChoice: $symbologyChoice,
                onLookup: { lookupManualCode() },
                onPickSymbology: { chooseSymbology($0) }
            ) onAddByName: {
                route = .nameEntry(InventorySeed(
                    name: "",
                    barcode: nil,
                    scanNote: nil
                ))
            }
        }
    }

    private var snapshots: [BarcodeStockSnapshot] {
        items.map { BarcodeStockSnapshot(item: $0) }
    }

    private var cameraScreen: some View {
        ZStack {
            BarcodeCameraPreview(isRunning: route == nil, torchOn: torchOn) { payload, type in
                handleScan(payload: payload, metadataType: type)
            } onUnavailable: {
                readiness = .unavailable
            } onConfigured: { hasTorch in
                torchAvailable = hasTorch
            }
            .accessibilityHidden(true)

            CameraFrameOverlay()
                .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                if let scanMessage {
                    Label(scanMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(PourColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(scanMessage)
                }
                HStack(spacing: 12) {
                    if torchAvailable {
                        Button {
                            torchOn.toggle()
                            Haptics.selection()
                        } label: {
                            Label(torchOn ? "Light on" : "Light", systemImage: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(torchOn ? .black : PourColor.textPrimary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(torchOn ? PourColor.accentFill : PourColor.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .accessibilityLabel(torchOn ? "Turn light off" : "Turn light on")
                        .accessibilityAddTraits(torchOn ? [.isButton, .isSelected] : .isButton)
                    }
                    Button {
                        manualError = nil
                        route = .manual
                    } label: {
                        Text("Enter code")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PourColor.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(PourColor.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .accessibilityLabel("Enter barcode number")
                    .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(PourColor.background.opacity(0.94))
        }
    }

    private var fallbackScreen: some View {
        let title = readiness?.fallbackTitle ?? "Barcode scanning"
        let message = readiness?.fallbackMessage ?? "Enter the numbers under the barcode, or add the bottle by name."
        return ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "barcode.viewfinder")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(PourColor.accent)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.pourTitle2)
                    .foregroundStyle(PourColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.body)
                    .foregroundStyle(PourColor.textSecondary)
                    .multilineTextAlignment(.center)
                if readiness?.offersSettings == true {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .buttonStyle(PourPrimaryButtonStyle())
                    .accessibilityLabel("Open Settings")
                    .accessibilityAddTraits(.isButton)
                }
                BarcodeCodeEntryFields(
                    code: $manualCode,
                    error: $manualError,
                    symbologyChoice: $symbologyChoice,
                    onLookup: { lookupManualCode() },
                    onPickSymbology: { chooseSymbology($0) }
                )
                Button("Add by name") {
                    route = .nameEntry(InventorySeed(name: "", barcode: nil, scanNote: nil))
                }
                .buttonStyle(PourSecondaryButtonStyle())
                .accessibilityLabel("Add bottle by name")
                .accessibilityAddTraits(.isButton)
            }
            .padding(24)
        }
    }

    private func prepareCamera() async {
        let hardware = AVCaptureDevice.default(for: .video) != nil
        let status = CameraAuthorizationState(AVCaptureDevice.authorizationStatus(for: .video))
        var decision = BarcodeCameraPolicy.readiness(hardwarePresent: hardware, authorization: status)
        if decision == .needsPermission {
            readiness = .needsPermission
            guard !didRequestPermission else { return }
            didRequestPermission = true
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            decision = BarcodeCameraPolicy.readiness(
                hardwarePresent: hardware,
                authorization: granted ? .authorized : .denied
            )
        }
        readiness = decision
    }

    private func handleScan(payload: String, metadataType: String) {
        guard route == nil else { return }
        guard scanLatch.receive(payload: payload, now: Date()) else { return }
        guard let parsed = BarcodeParser.parse(payload: payload, metadataType: metadataType) else {
            scanMessage = "That isn’t a product barcode. Try again, enter the code, or add the bottle by name."
            Haptics.warning()
            return
        }
        scanMessage = nil
        Haptics.success()
        present(parsed)
    }

    private func lookupManualCode() {
        switch BarcodeResolver.resolveManualEntry(manualCode, stock: snapshots) {
        case .empty:
            manualError = nil
            symbologyChoice = nil
        case .invalid:
            symbologyChoice = nil
            manualError = "That doesn’t look like a product barcode. Check the digits, or add the bottle by name."
            Haptics.warning()
        case .parsed(let parsed):
            manualError = nil
            symbologyChoice = nil
            present(parsed)
        case .ambiguous(let ean8, let upce):
            manualError = nil
            symbologyChoice = BarcodeSymbologyChoice(ean8: ean8, upce: upce)
            Haptics.warning()
        }
    }

    private func chooseSymbology(_ parsed: ParsedBarcode) {
        manualError = nil
        symbologyChoice = nil
        present(parsed)
    }

    private func present(_ parsed: ParsedBarcode) {
        switch BarcodeResolver.plan(parsed: parsed, stock: snapshots) {
        case .add(let draft):
            route = .confirm(draft)
        case .alreadyInBar(let match):
            Haptics.warning()
            route = .existing(match)
        case .needsName(let barcode):
            Haptics.warning()
            route = .nameEntry(InventorySeed(
                name: "",
                barcode: barcode,
                scanNote: "This barcode isn’t in the offline catalog. Enter the bottle name and Pour will match it on this device."
            ))
        }
    }

    private func confirmAdd(name: String, barcode: String) {
        switch BarcodeResolver.commit(name: name, barcode: barcode, stock: snapshots) {
        case .insert(let confirmed):
            let item = InventoryItem(name: confirmed.name, category: confirmed.category, isInStock: true)
            item.barcode = confirmed.barcode
            modelContext.insert(item)
            guard saveChanges() else { return }
            Haptics.success()
            dismiss()
        case .alreadyInBar(let match):
            route = .existing(match)
            Haptics.warning()
        case nil:
            break
        }
    }

    private func applyExisting(_ match: ExistingBarcodeMatch) {
        let current = Array(items)
        let stock = current.map { BarcodeStockSnapshot(item: $0) }
        guard let index = BarcodeResolver.locate(match, stock: stock) else { return }
        let mutation = BarcodeResolver.mutation(match: match, row: stock[index], update: .confirmedSheet)
        guard mutation.didChange else {
            dismiss()
            return
        }
        let item = current[index]
        item.isInStock = mutation.isInStock
        item.barcode = mutation.barcode
        guard saveChanges() else { return }
        Haptics.success()
        dismiss()
    }

    private func saveChanges() -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            showSaveError = true
            return false
        }
    }
}

private enum ScannerRoute: Identifiable {
    case confirm(BarcodeProductDraft)
    case existing(ExistingBarcodeMatch)
    case nameEntry(InventorySeed)
    case manual

    var id: String {
        switch self {
        case .confirm(let draft): return "confirm-\(draft.id)"
        case .existing(let match): return "existing-\(match.id)"
        case .nameEntry(let seed): return "name-\(seed.barcode ?? "plain")"
        case .manual: return "manual"
        }
    }
}

private extension CameraAuthorizationState {
    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .authorized: self = .authorized
        @unknown default: self = .denied
        }
    }
}

private struct CameraFrameOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let frameWidth = min(geo.size.width - 48, 320)
            let frameHeight = max(frameWidth * 0.52, 140)
            VStack(spacing: 0) {
                dim
                HStack(spacing: 0) {
                    dim
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(PourColor.accent, lineWidth: 3)
                        .frame(width: frameWidth, height: frameHeight)
                        .accessibilityHidden(true)
                    dim
                }
                .frame(height: frameHeight)
                dim
            }
            .overlay(alignment: .top) {
                Text("Align the barcode in the frame")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PourColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(PourColor.background.opacity(0.92), in: Capsule())
                    .padding(.top, 20)
                    .padding(.horizontal, 24)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    private var dim: some View {
        Color.black.opacity(0.45)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BarcodeCodeEntryFields: View {
    @Binding var code: String
    @Binding var error: String?
    @Binding var symbologyChoice: BarcodeSymbologyChoice?
    var onLookup: () -> Void
    var onPickSymbology: (ParsedBarcode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Barcode number", text: $code)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospacedDigit())
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .background(PourColor.surface, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("Barcode number")
                .onSubmit(onLookup)
                .onChange(of: code) { _, _ in
                    error = nil
                    symbologyChoice = nil
                }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(PourColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(error)
            }
            if let symbologyChoice {
                Text("These digits can be an EAN-8 or a UPC-E. Pick the type printed on the bottle.")
                    .font(.subheadline)
                    .foregroundStyle(PourColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                symbologyButton(title: "EAN-8", code: symbologyChoice.ean8.normalizedCode, parsed: symbologyChoice.ean8)
                symbologyButton(
                    title: "UPC-E",
                    code: BarcodeFormatting.grouped(symbologyChoice.upce.normalizedCode),
                    parsed: symbologyChoice.upce
                )
            }
            Button("Look up code", action: onLookup)
                .buttonStyle(PourPrimaryButtonStyle())
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                .accessibilityLabel("Look up barcode")
                .accessibilityAddTraits(.isButton)
        }
    }

    private func symbologyButton(title: String, code: String, parsed: ParsedBarcode) -> some View {
        Button {
            onPickSymbology(parsed)
        } label: {
            VStack(spacing: 2) {
                Text(title)
                Text(code)
                    .font(.subheadline.monospacedDigit())
            }
        }
        .buttonStyle(PourSecondaryButtonStyle())
        .accessibilityLabel("Use \(title), \(code)")
        .accessibilityAddTraits(.isButton)
    }
}

private struct BarcodeManualEntrySheet: View {
    @Binding var code: String
    @Binding var error: String?
    @Binding var symbologyChoice: BarcodeSymbologyChoice?
    var onLookup: () -> Void
    var onPickSymbology: (ParsedBarcode) -> Void
    var onAddByName: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Enter the digits printed under the barcode. Pour matches them on this device.")
                        .font(.body)
                        .foregroundStyle(PourColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    BarcodeCodeEntryFields(
                        code: $code,
                        error: $error,
                        symbologyChoice: $symbologyChoice,
                        onLookup: onLookup,
                        onPickSymbology: onPickSymbology
                    )
                    Button("Add by name", action: onAddByName)
                        .buttonStyle(PourSecondaryButtonStyle())
                        .accessibilityLabel("Add bottle by name")
                        .accessibilityAddTraits(.isButton)
                }
                .padding(24)
            }
            .background(PourColor.background)
            .navigationTitle("Enter code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityLabel("Cancel")
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
    }
}

private struct BarcodeConfirmSheet: View {
    let draft: BarcodeProductDraft
    var onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(draft: BarcodeProductDraft, onAdd: @escaping (String) -> Void) {
        self.draft = draft
        self.onAdd = onAdd
        _name = State(initialValue: draft.displayName)
    }

    private var canAdd: Bool {
        BarcodeConfirmedItem.make(name: name, barcode: draft.barcode) != nil
    }

    private var category: InventoryCategory {
        IngredientNormalizer.category(for: name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Found offline", systemImage: "checkmark.circle")
                        .foregroundStyle(PourColor.textPrimary)
                        .accessibilityLabel("Found in the offline catalog")
                    TextField("Bottle name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("Bottle name")
                    Label(category.displayName, systemImage: category.symbol)
                        .foregroundStyle(PourColor.textSecondary)
                        .accessibilityLabel("Category, \(category.displayName)")
                } header: {
                    Text("Ingredient")
                } footer: {
                    Text(matchingCaption)
                }
                Section("Barcode") {
                    Text(BarcodeFormatting.grouped(draft.barcode))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(PourColor.textPrimary)
                        .accessibilityLabel("Barcode \(draft.barcode)")
                }
            }
            .scrollContentBackground(.hidden)
            .background(PourColor.background)
            .navigationTitle("Confirm ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityLabel("Cancel")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Add to My Bar") { onAdd(name) }
                    .buttonStyle(PourPrimaryButtonStyle())
                    .disabled(!canAdd)
                    .opacity(canAdd ? 1 : 0.45)
                    .padding()
                    .background(PourColor.background)
                    .accessibilityLabel("Add to My Bar")
                    .accessibilityHint(canAdd ? "Adds the bottle to My Bar" : "Enter a bottle name first")
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    private var matchingCaption: String {
        if IngredientNormalizer.normalize(name).isEmpty {
            return "Enter the bottle name. Pour matches it to a recipe ingredient on this device."
        }
        return "Maps to “\(IngredientNormalizer.canonicalName(for: name))” for matching. The barcode stays on this device."
    }
}

struct BarcodeExistingSheet: View {
    let match: ExistingBarcodeMatch
    var onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var action: BarcodeExistingAction {
        BarcodeResolver.existingAction(isInStock: match.isInStock, canAttachBarcode: match.canAttachBarcode)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(PourColor.accent)
                    .accessibilityHidden(true)
                Text(match.name)
                    .font(.pourTitle2)
                    .foregroundStyle(PourColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Label(match.isInStock ? "In stock" : "Out of stock", systemImage: match.isInStock ? "checkmark.circle.fill" : "circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(match.isInStock ? PourColor.canMake : PourColor.textSecondary)
                    .accessibilityLabel(match.isInStock ? "In stock" : "Out of stock")
                Text(explanation)
                    .font(.body)
                    .foregroundStyle(PourColor.textSecondary)
                    .multilineTextAlignment(.center)
                Text(BarcodeFormatting.grouped(match.scannedCode))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(PourColor.textTertiary)
                    .accessibilityLabel("Barcode \(match.scannedCode)")
                Button(action.buttonTitle) {
                    if action == .none {
                        dismiss()
                    } else {
                        onApply()
                    }
                }
                .buttonStyle(PourPrimaryButtonStyle())
                .accessibilityLabel(action.buttonTitle)
                .accessibilityAddTraits(.isButton)
                if action != .none {
                    Button("Not now") { dismiss() }
                        .buttonStyle(PourSecondaryButtonStyle())
                        .accessibilityLabel("Not now")
                        .accessibilityAddTraits(.isButton)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PourColor.background)
            .navigationTitle("Already in your bar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityLabel("Close")
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    private var explanation: String {
        switch action {
        case .markInStockAndSaveBarcode:
            return "\(match.name) is already in your bar and marked out of stock. You can mark it in stock and keep this barcode on it."
        case .markInStock:
            if match.holdsScannedCode {
                return "\(match.name) is already in your bar and marked out of stock."
            }
            return "\(match.name) is already in your bar with a different barcode, so this code wasn’t added. It’s marked out of stock."
        case .saveBarcode:
            return "\(match.name) is already in your bar. Save this barcode on it so the next scan finds it."
        case .none:
            if match.holdsScannedCode {
                return "\(match.name) is already in your bar with this barcode."
            }
            return "\(match.name) is already in your bar with a different barcode, so this code wasn’t added."
        }
    }
}

private struct PourSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(PourColor.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(PourColor.surface.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(PourColor.border, lineWidth: 1))
    }
}

private struct BarcodeCameraPreview: UIViewControllerRepresentable {
    var isRunning: Bool
    var torchOn: Bool
    var onCode: (String, String) -> Void
    var onUnavailable: () -> Void
    var onConfigured: (Bool) -> Void

    func makeUIViewController(context: Context) -> BarcodeCaptureViewController {
        let controller = BarcodeCaptureViewController()
        controller.onCode = onCode
        controller.onUnavailable = onUnavailable
        controller.onConfigured = onConfigured
        return controller
    }

    func updateUIViewController(_ controller: BarcodeCaptureViewController, context: Context) {
        controller.onCode = onCode
        controller.onUnavailable = onUnavailable
        controller.onConfigured = onConfigured
        controller.setRunning(isRunning)
        controller.setTorch(torchOn)
    }

    static func dismantleUIViewController(_ controller: BarcodeCaptureViewController, coordinator: ()) {
        controller.stop()
    }
}

private final class BarcodeCaptureViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String, String) -> Void)?
    var onUnavailable: (() -> Void)?
    var onConfigured: ((Bool) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.devin.pour.barcode-session")
    private var isConfigured = false
    private var wantsRunning = false
    private var desiredTorch = false
    private var device: AVCaptureDevice?
    private var didReportUnavailable = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let preview = BarcodePreviewView()
        preview.frame = view.bounds
        preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        preview.videoLayer.session = session
        preview.videoLayer.videoGravity = .resizeAspectFill
        view.addSubview(preview)
        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let connection = (view.subviews.first as? BarcodePreviewView)?.videoLayer.connection else { return }
        let angle: CGFloat = 90
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    func setRunning(_ running: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = running
            self.applyRunning()
        }
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.desiredTorch = on
            self.applyTorch()
        }
    }

    func stop() {
        setRunning(false)
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let symbols: [BarcodeSymbol] = metadataObjects.compactMap { object in
            guard let code = object as? AVMetadataMachineReadableCodeObject,
                  let value = code.stringValue,
                  !value.isEmpty else { return nil }
            return BarcodeSymbol(payload: value, type: code.type.rawValue)
        }
        guard let chosen = BarcodeCaptureSelection.preferred(symbols) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onCode?(chosen.payload, chosen.type)
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high
        session.automaticallyConfiguresApplicationAudioSession = false
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            reportUnavailable()
            return
        }
        self.device = device
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            reportUnavailable()
            return
        }
        session.addOutput(output)
        // The delegate queue has to differ from the queue that calls startRunning.
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        session.commitConfiguration()
        let wanted: [AVMetadataObject.ObjectType] = [
            .ean13, .ean8, .upce, .code128, .code39, .itf14, .interleaved2of5, .qr,
        ]
        let supported = wanted.filter { output.availableMetadataObjectTypes.contains($0) }
        if !supported.isEmpty {
            output.metadataObjectTypes = supported
        }
        isConfigured = true
        applyRunning()
        let hasTorch = device.hasTorch
        DispatchQueue.main.async { [weak self] in
            self?.onConfigured?(hasTorch)
        }
    }

    private func applyRunning() {
        guard isConfigured else { return }
        if wantsRunning {
            if !session.isRunning { session.startRunning() }
            applyTorch()
        } else if session.isRunning {
            session.stopRunning()
        }
    }

    private func applyTorch() {
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if desiredTorch, wantsRunning {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
        } catch {
            // Leave the light unchanged when the device rejects the configuration.
        }
    }

    private func reportUnavailable() {
        guard !didReportUnavailable else { return }
        didReportUnavailable = true
        DispatchQueue.main.async { [weak self] in
            self?.onUnavailable?()
        }
    }
}

private final class BarcodePreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
