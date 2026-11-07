import Foundation

/// Camera permission and hardware, reduced to values the scanner UI and tests can share.
enum CameraAuthorizationState: Equatable {
    case notDetermined
    case restricted
    case denied
    case authorized
}

enum BarcodeCameraReadiness: Equatable {
    case ready
    case needsPermission
    case denied
    case restricted
    case unavailable

    /// Title for the non-camera fallback. Nil while the camera can run.
    var fallbackTitle: String? {
        switch self {
        case .ready, .needsPermission: return nil
        case .denied: return "Camera access is off"
        case .restricted: return "Camera is restricted"
        case .unavailable: return "No camera on this device"
        }
    }

    /// Honest explanation plus the typed-code and add-by-name fallbacks.
    var fallbackMessage: String? {
        switch self {
        case .ready, .needsPermission:
            return nil
        case .denied:
            return "Pour needs the camera to scan a barcode. You can allow access in Settings, enter the numbers under the barcode, or add the bottle by name."
        case .restricted:
            return "This device doesn’t allow Pour to use the camera. Enter the numbers under the barcode, or add the bottle by name."
        case .unavailable:
            return "Pour can’t scan a barcode on this device. Enter the numbers under the barcode, or add the bottle by name."
        }
    }

    var offersSettings: Bool { self == .denied }
}

enum BarcodeCameraPolicy {
    static func readiness(hardwarePresent: Bool, authorization: CameraAuthorizationState) -> BarcodeCameraReadiness {
        guard hardwarePresent else { return .unavailable }
        switch authorization {
        case .authorized: return .ready
        case .notDetermined: return .needsPermission
        case .denied: return .denied
        case .restricted: return .restricted
        }
    }
}

enum BarcodeSymbology: String, Equatable {
    case ean13
    case ean8
    case upca
    case upce
    case itf14
    case code128
    case other
}

struct ParsedBarcode: Equatable {
    var rawPayload: String
    var normalizedCode: String
    var symbology: BarcodeSymbology
    /// Keys to try against the offline catalog, most specific first.
    var lookupKeys: [String]
}

enum BarcodeManualEntryResult: Equatable {
    case parsed(ParsedBarcode)
    /// Eight digits that are a valid EAN-8 and a valid UPC-E. The two readings are different products.
    case ambiguous(ean8: ParsedBarcode, upce: ParsedBarcode)
    case empty
    case invalid
}

struct BarcodeSymbologyChoice: Equatable, Identifiable {
    var ean8: ParsedBarcode
    var upce: ParsedBarcode
    var id: String { "\(ean8.normalizedCode)|\(upce.normalizedCode)" }
}

enum BarcodeCheckDigit {
    static func compute(_ body: String) -> Int {
        var sum = 0
        for (index, character) in body.reversed().enumerated() {
            guard let digit = character.wholeNumberValue else { return -1 }
            sum += digit * (index % 2 == 0 ? 3 : 1)
        }
        return (10 - (sum % 10)) % 10
    }

    static func isValidGTIN(_ digits: String) -> Bool {
        guard [8, 12, 13, 14].contains(digits.count) else { return false }
        guard digits.allSatisfy(\.isNumber) else { return false }
        guard let provided = digits.last?.wholeNumberValue else { return false }
        return compute(String(digits.dropLast())) == provided
    }
}

/// GTIN parsing for bottle barcodes. Matching stays on device; unknown codes are not looked up online.
enum BarcodeParser {
    static func interpretManualEntry(_ raw: String) -> BarcodeManualEntryResult {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if let conflict = conflictingEightDigit(raw) {
            return .ambiguous(ean8: conflict.ean8, upce: conflict.upce)
        }
        guard let parsed = parse(payload: raw) else { return .invalid }
        return .parsed(parsed)
    }

    /// Eight printed digits that pass both an EAN-8 check and a UPC-E expansion.
    /// Manual entry has no symbology hint, so guessing would store a different product
    /// than a camera scan of the same EAN-8.
    private static func conflictingEightDigit(_ raw: String) -> (ean8: ParsedBarcode, upce: ParsedBarcode)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let compact = compactDigits(from: trimmed), compact.count == 8 else { return nil }
        guard BarcodeCheckDigit.isValidGTIN(compact) else { return nil }
        guard let expanded = expandUPCE(compact, allowBareSixDigits: false),
              let upce = makeUPCA(raw: trimmed, upca: expanded, symbology: .upce),
              upce.normalizedCode != compact else { return nil }
        let ean8 = make(raw: trimmed, normalized: compact, symbology: .ean8, extraKeys: [])
        return (ean8, upce)
    }

    static func sameProductCode(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs, let left = parse(payload: lhs)?.normalizedCode else { return false }
        guard let right = parse(payload: rhs)?.normalizedCode else { return false }
        return left == right
    }

    static func parse(payload: String, metadataType: String? = nil) -> ParsedBarcode? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let compact = compactDigits(from: trimmed) else { return nil }
        let hint = symbologyHint(metadataType)

        if hint == .upce {
            if let expanded = expandUPCE(compact) {
                return makeUPCA(raw: trimmed, upca: expanded, symbology: .upce)
            }
            if compact.count == 12 || compact.count == 13 {
                return parseFixedLength(compact, raw: trimmed, preferred: .upca)
            }
            return nil
        }

        // Unlabeled 6-digit codes expand to UPC-A. Unlabeled 8-digit codes expand only
        // when they are not also a valid EAN-8; otherwise the printed digits stay an EAN-8.
        // Manual entry asks which type was printed. A camera EAN-8 hint never reaches this branch.
        if hint != .ean8,
           compact.count == 6 || compact.count == 8,
           let expanded = expandUPCE(compact, allowBareSixDigits: hint == nil) {
            let ambiguousEAN8 = hint == nil && compact.count == 8 && BarcodeCheckDigit.isValidGTIN(compact)
            if !ambiguousEAN8, let parsed = makeUPCA(raw: trimmed, upca: expanded, symbology: .upce) {
                return parsed
            }
        }

        if compact.count == 16, compact.hasPrefix("01") {
            let gtin14 = String(compact.dropFirst(2))
            if BarcodeCheckDigit.isValidGTIN(gtin14) {
                return makeGTIN14(raw: trimmed, gtin14: gtin14, symbology: .code128)
            }
        }

        return parseFixedLength(compact, raw: trimmed, preferred: hint)
    }

    private static func parseFixedLength(_ compact: String, raw: String, preferred: BarcodeSymbology?) -> ParsedBarcode? {
        switch compact.count {
        case 8:
            guard BarcodeCheckDigit.isValidGTIN(compact) else { return nil }
            return make(raw: raw, normalized: compact, symbology: .ean8, extraKeys: [])
        case 12:
            guard BarcodeCheckDigit.isValidGTIN(compact) else { return nil }
            return makeUPCA(raw: raw, upca: compact, symbology: preferred == .code128 ? .code128 : .upca)
        case 13:
            guard BarcodeCheckDigit.isValidGTIN(compact) else { return nil }
            let symbology: BarcodeSymbology = compact.hasPrefix("0") ? .upca : .ean13
            var extras = [compact]
            if compact.hasPrefix("0") {
                extras.append(String(compact.dropFirst()))
            }
            return make(raw: raw, normalized: compact, symbology: symbology, extraKeys: extras)
        case 14:
            guard BarcodeCheckDigit.isValidGTIN(compact) else { return nil }
            let symbology: BarcodeSymbology = preferred == .code128 ? .code128 : .itf14
            return makeGTIN14(raw: raw, gtin14: compact, symbology: symbology)
        default:
            return nil
        }
    }

    private static func makeUPCA(raw: String, upca: String, symbology: BarcodeSymbology) -> ParsedBarcode? {
        guard upca.count == 12, BarcodeCheckDigit.isValidGTIN(upca) else { return nil }
        let gtin13 = "0" + upca
        return make(raw: raw, normalized: gtin13, symbology: symbology, extraKeys: [upca, gtin13])
    }

    /// ITF-14 / GTIN-14 stores a packaging indicator and its own check digit.
    /// The consumer GTIN-13 is the middle 12 digits plus a recalculated check digit.
    private static func makeGTIN14(raw: String, gtin14: String, symbology: BarcodeSymbology) -> ParsedBarcode? {
        guard gtin14.count == 14 else { return nil }
        let data12 = String(gtin14.dropFirst().dropLast())
        guard data12.count == 12 else { return nil }
        let gtin13 = data12 + String(BarcodeCheckDigit.compute(data12))
        guard BarcodeCheckDigit.isValidGTIN(gtin13) else { return nil }
        var extras = [gtin13, gtin14]
        if gtin13.hasPrefix("0") {
            extras.append(String(gtin13.dropFirst()))
        }
        return make(raw: raw, normalized: gtin13, symbology: symbology, extraKeys: extras)
    }

    private static func make(raw: String, normalized: String, symbology: BarcodeSymbology, extraKeys: [String]) -> ParsedBarcode {
        var keys: [String] = []
        for key in [normalized] + extraKeys where !key.isEmpty && !keys.contains(key) {
            keys.append(key)
        }
        return ParsedBarcode(rawPayload: raw, normalizedCode: normalized, symbology: symbology, lookupKeys: keys)
    }

    /// UPC-E number-system + 6 digits + optional check, expanded to UPC-A.
    /// `allowBareSixDigits` accepts a 6-digit body and assumes number system 0.
    private static func expandUPCE(_ digits: String, allowBareSixDigits: Bool = true) -> String? {
        let numberSystem: Character
        let body: String
        let providedCheck: Character?
        switch digits.count {
        case 6 where allowBareSixDigits:
            numberSystem = "0"
            body = digits
            providedCheck = nil
        case 8:
            guard let first = digits.first, first == "0" || first == "1" else { return nil }
            numberSystem = first
            body = String(digits.dropFirst().dropLast())
            providedCheck = digits.last
        default:
            return nil
        }
        guard body.count == 6 else { return nil }
        let digitsInBody = Array(body)
        let expandedBody: String
        switch digitsInBody[5] {
        case "0", "1", "2":
            expandedBody = "\(numberSystem)\(digitsInBody[0])\(digitsInBody[1])\(digitsInBody[5])0000\(digitsInBody[2])\(digitsInBody[3])\(digitsInBody[4])"
        case "3":
            expandedBody = "\(numberSystem)\(digitsInBody[0])\(digitsInBody[1])\(digitsInBody[2])00000\(digitsInBody[3])\(digitsInBody[4])"
        case "4":
            expandedBody = "\(numberSystem)\(digitsInBody[0])\(digitsInBody[1])\(digitsInBody[2])\(digitsInBody[3])00000\(digitsInBody[4])"
        default:
            expandedBody = "\(numberSystem)\(digitsInBody[0])\(digitsInBody[1])\(digitsInBody[2])\(digitsInBody[3])\(digitsInBody[4])0000\(digitsInBody[5])"
        }
        guard expandedBody.count == 11 else { return nil }
        let check = BarcodeCheckDigit.compute(expandedBody)
        if let providedCheck, String(providedCheck) != String(check) { return nil }
        let upca = expandedBody + String(check)
        guard BarcodeCheckDigit.isValidGTIN(upca) else { return nil }
        return upca
    }

    private static func compactDigits(from trimmed: String) -> String? {
        let withoutParens = trimmed.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        let allowed = CharacterSet.decimalDigits
            .union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "-"))
        guard withoutParens.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let digits = withoutParens.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return String(digits)
    }

    private static func symbologyHint(_ metadataType: String?) -> BarcodeSymbology? {
        switch metadataType {
        case "org.gs1.EAN-13": return .ean13
        case "org.gs1.EAN-8": return .ean8
        case "org.gs1.UPC-E": return .upce
        case "org.gs1.ITF14", "org.iso.Interleaved2of5": return .itf14
        case "org.iso.Code128", "org.iso.Code39": return .code128
        default: return nil
        }
    }
}

enum BarcodeFormatting {
    /// Groups a GTIN the way a UPC-A is printed: `0 12345 67890 5`.
    static func grouped(_ code: String) -> String {
        let digits = String(code.filter(\.isNumber))
        let upc: String
        if digits.count == 13, digits.first == "0" {
            upc = String(digits.dropFirst())
        } else if digits.count == 12 {
            upc = digits
        } else {
            return digits
        }
        guard upc.count == 12 else { return digits }
        let chars = Array(upc)
        return "\(chars[0]) \(String(chars[1...5])) \(String(chars[6...10])) \(chars[11])"
    }
}

struct BarcodeCatalogEntry: Equatable {
    var gtin: String
    var displayName: String
}

/// Retail UPC-A codes for common back-bar bottles, stored as GTIN-13.
/// Other sizes and unknown brands stay on the manual add path. Nothing is fetched.
enum BarcodeCatalog {
    static let entries: [BarcodeCatalogEntry] = [
        BarcodeCatalogEntry(gtin: "0075496000407", displayName: "Angostura Bitters"),
        BarcodeCatalogEntry(gtin: "0721059047500", displayName: "Campari"),
        BarcodeCatalogEntry(gtin: "0087236565107", displayName: "Cointreau"),
        BarcodeCatalogEntry(gtin: "0721059001311", displayName: "Aperol"),
        BarcodeCatalogEntry(gtin: "0086891026237", displayName: "Luxardo Maraschino"),
        BarcodeCatalogEntry(gtin: "0898804001008", displayName: "St-Germain"),
        BarcodeCatalogEntry(gtin: "0088004190187", displayName: "Peychaud's Bitters"),
        BarcodeCatalogEntry(gtin: "0089540122717", displayName: "Kahlúa"),
        BarcodeCatalogEntry(gtin: "0898195001175", displayName: "Fever-Tree Tonic"),
        BarcodeCatalogEntry(gtin: "0086767210067", displayName: "Baileys"),
        BarcodeCatalogEntry(gtin: "0088110110307", displayName: "Tanqueray"),
        BarcodeCatalogEntry(gtin: "0619947000020", displayName: "Tito's"),
    ]

    private static let byGTIN: [String: String] = {
        var map: [String: String] = [:]
        for entry in entries { map[entry.gtin] = entry.displayName }
        return map
    }()

    static func displayName(matching parsed: ParsedBarcode) -> String? {
        for key in parsed.lookupKeys {
            if let name = byGTIN[key] { return name }
        }
        return nil
    }
}

struct BarcodeProductDraft: Equatable, Identifiable {
    var displayName: String
    var barcode: String
    var isRecognized: Bool
    var id: String { barcode }
}

struct BarcodeConfirmedItem: Equatable {
    var name: String
    var category: InventoryCategory
    var barcode: String
    var canonicalName: String
    var isInStock: Bool

    static func make(name: String, barcode: String) -> BarcodeConfirmedItem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !IngredientNormalizer.normalize(trimmed).isEmpty else { return nil }
        guard let parsed = BarcodeParser.parse(payload: barcode) else { return nil }
        return BarcodeConfirmedItem(
            name: trimmed,
            category: IngredientNormalizer.category(for: trimmed),
            barcode: parsed.normalizedCode,
            canonicalName: IngredientNormalizer.canonicalName(for: trimmed),
            isInStock: true
        )
    }
}

struct BarcodeStockSnapshot: Equatable {
    var name: String
    var barcode: String?
    var isInStock: Bool
    var isLowStock: Bool = false
    /// Persistent identity of the inventory row. Nil only for callers that have a single row per name.
    var rowID: String? = nil
}

extension BarcodeStockSnapshot {
    init(item: InventoryItem) {
        self.init(
            name: item.name,
            barcode: item.barcode,
            isInStock: item.isInStock,
            isLowStock: item.isLowStock,
            rowID: item.barcodeRowID
        )
    }
}

struct ExistingBarcodeMatch: Equatable, Identifiable {
    var name: String
    var isInStock: Bool
    var scannedCode: String
    var canAttachBarcode: Bool
    var rowID: String? = nil
    /// True when the matched row already stores this scanned code.
    var holdsScannedCode: Bool = false
    var id: String {
        let row = rowID ?? name
        return "\(row)|\(scannedCode)|\(canAttachBarcode)|\(holdsScannedCode)"
    }
}

struct BarcodeRowMutation: Equatable {
    var isInStock: Bool
    var barcode: String?
    var isLowStock: Bool
    var didChange: Bool
}

enum BarcodeStockWrite: Equatable {
    /// Already-in-bar sheet. The button is the confirmation to restock or save the code.
    case confirmedSheet
    /// Unknown-code editor. `isInStock` is the In stock toggle.
    case editor(isInStock: Bool, isLowStock: Bool)
}

enum UnknownBarcodeSave: Equatable {
    case insert(BarcodeConfirmedItem)
    case update(ExistingBarcodeMatch, BarcodeRowMutation)
    case offerExisting(ExistingBarcodeMatch)
    case rejected
}

enum BarcodeExistingAction: Equatable {
    case markInStockAndSaveBarcode
    case markInStock
    case saveBarcode
    case none

    var buttonTitle: String {
        switch self {
        case .markInStockAndSaveBarcode: return "Mark in stock and save barcode"
        case .markInStock: return "Mark in stock"
        case .saveBarcode: return "Save barcode"
        case .none: return "Done"
        }
    }
}

enum BarcodeScanPlan: Equatable {
    case add(BarcodeProductDraft)
    case alreadyInBar(ExistingBarcodeMatch)
    case needsName(barcode: String)
}

enum BarcodeCommit: Equatable {
    case insert(BarcodeConfirmedItem)
    case alreadyInBar(ExistingBarcodeMatch)
}

enum BarcodeResolver {
    static func existingAction(isInStock: Bool, canAttachBarcode: Bool) -> BarcodeExistingAction {
        switch (isInStock, canAttachBarcode) {
        case (false, true): return .markInStockAndSaveBarcode
        case (false, false): return .markInStock
        case (true, true): return .saveBarcode
        case (true, false): return .none
        }
    }

    static func plan(parsed: ParsedBarcode, stock: [BarcodeStockSnapshot]) -> BarcodeScanPlan {
        let code = parsed.normalizedCode
        if let displayName = BarcodeCatalog.displayName(matching: parsed) {
            switch commit(name: displayName, barcode: code, stock: stock) {
            case .insert(let item):
                return .add(BarcodeProductDraft(displayName: item.name, barcode: item.barcode, isRecognized: true))
            case .alreadyInBar(let match):
                return .alreadyInBar(match)
            case nil:
                return .needsName(barcode: code)
            }
        }
        if let hit = stock.first(where: { BarcodeParser.sameProductCode($0.barcode, code) }) {
            return .alreadyInBar(match(for: hit, scannedCode: code, holdsScannedCode: true))
        }
        return .needsName(barcode: code)
    }

    static func commit(name: String, barcode: String, stock: [BarcodeStockSnapshot]) -> BarcodeCommit? {
        guard let confirmed = BarcodeConfirmedItem.make(name: name, barcode: barcode) else { return nil }
        if let hit = stock.first(where: { BarcodeParser.sameProductCode($0.barcode, confirmed.barcode) }) {
            return .alreadyInBar(match(for: hit, scannedCode: confirmed.barcode, holdsScannedCode: true))
        }
        let normalized = IngredientNormalizer.normalize(confirmed.name)
        if let hit = stock.first(where: { IngredientNormalizer.normalize($0.name) == normalized }) {
            let holdsScannedCode = BarcodeParser.sameProductCode(hit.barcode, confirmed.barcode)
            return .alreadyInBar(match(for: hit, scannedCode: confirmed.barcode, holdsScannedCode: holdsScannedCode))
        }
        return .insert(confirmed)
    }

    /// The row whose stock status produced `match`, even when another row shares its name.
    static func locate(_ match: ExistingBarcodeMatch, stock: [BarcodeStockSnapshot]) -> Int? {
        if let rowID = match.rowID,
           let index = stock.firstIndex(where: { $0.rowID == rowID }) {
            return index
        }
        if let index = stock.firstIndex(where: { BarcodeParser.sameProductCode($0.barcode, match.scannedCode) }) {
            return index
        }
        let normalized = IngredientNormalizer.normalize(match.name)
        guard !normalized.isEmpty else { return nil }
        return stock.firstIndex(where: { IngredientNormalizer.normalize($0.name) == normalized })
    }

    static func mutation(
        match: ExistingBarcodeMatch,
        row: BarcodeStockSnapshot,
        update: BarcodeStockWrite
    ) -> BarcodeRowMutation {
        switch update {
        case .confirmedSheet:
            let canAttach = match.canAttachBarcode && (row.barcode?.isEmpty != false)
            let action = existingAction(isInStock: row.isInStock, canAttachBarcode: canAttach)
            switch action {
            case .markInStockAndSaveBarcode:
                return BarcodeRowMutation(isInStock: true, barcode: match.scannedCode, isLowStock: row.isLowStock, didChange: true)
            case .markInStock:
                return BarcodeRowMutation(isInStock: true, barcode: row.barcode, isLowStock: row.isLowStock, didChange: true)
            case .saveBarcode:
                return BarcodeRowMutation(isInStock: row.isInStock, barcode: match.scannedCode, isLowStock: row.isLowStock, didChange: true)
            case .none:
                return BarcodeRowMutation(isInStock: row.isInStock, barcode: row.barcode, isLowStock: row.isLowStock, didChange: false)
            }
        case .editor(let isInStock, let isLowStock):
            let canAttach = match.canAttachBarcode && (row.barcode?.isEmpty != false)
            let barcode = canAttach ? match.scannedCode : row.barcode
            let changed = isInStock != row.isInStock
                || isLowStock != row.isLowStock
                || barcodeChanged(from: row.barcode, to: barcode)
            return BarcodeRowMutation(isInStock: isInStock, barcode: barcode, isLowStock: isLowStock, didChange: changed)
        }
    }

    /// Unknown-code save. A duplicate that would not change the matched row is offered
    /// back to the bartender instead of being discarded. The In stock toggle is the
    /// stock value written when the row does change.
    static func saveUnknownCode(
        name: String,
        barcode: String,
        isInStock: Bool,
        isLowStock: Bool,
        stock: [BarcodeStockSnapshot]
    ) -> UnknownBarcodeSave {
        guard let decision = commit(name: name, barcode: barcode, stock: stock) else { return .rejected }
        switch decision {
        case .insert(let item):
            var item = item
            item.isInStock = isInStock
            return .insert(item)
        case .alreadyInBar(let match):
            guard let index = locate(match, stock: stock) else { return .offerExisting(match) }
            let row = stock[index]
            let typedName = IngredientNormalizer.normalize(name)
            guard typedName == IngredientNormalizer.normalize(row.name) else {
                return .offerExisting(match)
            }
            // A different code is already on this bottle. Explain that instead of
            // closing the scanner and dropping the code the bartender just entered.
            if !match.holdsScannedCode && !match.canAttachBarcode {
                return .offerExisting(match)
            }
            let change = mutation(
                match: match,
                row: row,
                update: .editor(isInStock: isInStock, isLowStock: isLowStock)
            )
            if change.didChange {
                return .update(match, change)
            }
            return .offerExisting(match)
        }
    }

    /// Pick a symbology when eight digits are both EAN-8 and UPC-E.
    /// An inventory or catalog hit for exactly one reading wins; otherwise the bartender chooses.
    static func resolveManualEntry(_ raw: String, stock: [BarcodeStockSnapshot]) -> BarcodeManualEntryResult {
        let entered = BarcodeParser.interpretManualEntry(raw)
        switch entered {
        case .empty, .invalid, .parsed:
            return entered
        case .ambiguous(let ean8, let upce):
            let eanKnown = isKnown(ean8, stock: stock)
            let upcKnown = isKnown(upce, stock: stock)
            switch (eanKnown, upcKnown) {
            case (true, false): return .parsed(ean8)
            case (false, true): return .parsed(upce)
            default: return .ambiguous(ean8: ean8, upce: upce)
            }
        }
    }

    private static func match(
        for hit: BarcodeStockSnapshot,
        scannedCode: String,
        holdsScannedCode: Bool
    ) -> ExistingBarcodeMatch {
        let canAttach = !holdsScannedCode && (hit.barcode?.isEmpty != false)
        return ExistingBarcodeMatch(
            name: hit.name,
            isInStock: hit.isInStock,
            scannedCode: scannedCode,
            canAttachBarcode: canAttach,
            rowID: hit.rowID,
            holdsScannedCode: holdsScannedCode
        )
    }

    private static func isKnown(_ parsed: ParsedBarcode, stock: [BarcodeStockSnapshot]) -> Bool {
        if BarcodeCatalog.displayName(matching: parsed) != nil { return true }
        return stock.contains { BarcodeParser.sameProductCode($0.barcode, parsed.normalizedCode) }
    }

    private static func barcodeChanged(from existing: String?, to updated: String?) -> Bool {
        let left = existing?.isEmpty == false ? existing : nil
        let right = updated?.isEmpty == false ? updated : nil
        switch (left, right) {
        case (nil, nil):
            return false
        case (nil, _), (_, nil):
            return true
        case (let lhs?, let rhs?):
            if lhs == rhs { return false }
            return !BarcodeParser.sameProductCode(lhs, rhs)
        }
    }
}

struct BarcodeSymbol: Equatable {
    var payload: String
    var type: String
}

enum BarcodeCaptureSelection {
    /// A product code wins over a marketing QR listed first in the same frame.
    static func preferred(_ symbols: [BarcodeSymbol]) -> BarcodeSymbol? {
        let visible = symbols.filter { !$0.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let product = visible.first(where: { BarcodeParser.parse(payload: $0.payload, metadataType: $0.type) != nil }) {
            return product
        }
        return visible.first
    }
}

/// Stops one barcode from reopening its sheet while it is still in the viewfinder.
struct BarcodeScanLatch: Equatable {
    static let quietInterval: TimeInterval = 2

    private(set) var heldPayload: String?
    private(set) var lastSeen: Date?
    private(set) var holdingDismissal = false
    private(set) var seenSinceDismissal = false

    /// Returns true when this payload should open a sheet.
    mutating func receive(payload: String, now: Date) -> Bool {
        if payload == heldPayload {
            if holdingDismissal {
                if !seenSinceDismissal {
                    seenSinceDismissal = true
                    lastSeen = now
                    return false
                }
                let gap = lastSeen.map { now.timeIntervalSince($0) } ?? 0
                lastSeen = now
                if gap < Self.quietInterval {
                    return false
                }
                holdingDismissal = false
                seenSinceDismissal = false
                return true
            }
            let gap = lastSeen.map { now.timeIntervalSince($0) } ?? 0
            lastSeen = now
            return gap >= Self.quietInterval
        }
        heldPayload = payload
        lastSeen = now
        holdingDismissal = false
        seenSinceDismissal = false
        return true
    }

    /// Keep the payload that was on screen. The next frame of that same code must not reopen the sheet.
    mutating func noteSheetDismissed(now: Date) {
        guard heldPayload != nil else { return }
        holdingDismissal = true
        seenSinceDismissal = false
        lastSeen = now
    }
}
