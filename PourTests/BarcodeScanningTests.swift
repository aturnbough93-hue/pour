import SwiftData
import XCTest
@testable import Pour

final class BarcodeScanningTests: XCTestCase {

    // MARK: - Parsing

    func testUPCAAndEAN13NormalizeToTheSameGTIN() {
        let upc = BarcodeParser.parse(payload: "075496000407")
        let ean = BarcodeParser.parse(payload: "0075496000407")
        let spaced = BarcodeParser.parse(payload: "0 75496 00040 7")
        XCTAssertEqual(upc?.normalizedCode, "0075496000407")
        XCTAssertEqual(upc?.symbology, .upca)
        XCTAssertEqual(ean?.normalizedCode, upc?.normalizedCode)
        XCTAssertEqual(spaced?.normalizedCode, upc?.normalizedCode)
        XCTAssertTrue(BarcodeParser.sameProductCode("075496000407", "0075496000407"))
    }

    func testRejectsEmptyPayloadsURLsAndBadCheckDigits() {
        XCTAssertNil(BarcodeParser.parse(payload: ""))
        XCTAssertNil(BarcodeParser.parse(payload: "   "))
        XCTAssertNil(BarcodeParser.parse(payload: "https://example.com/0075496000407"))
        XCTAssertNil(BarcodeParser.parse(payload: "075496000408"))
        XCTAssertEqual(BarcodeParser.interpretManualEntry("  "), .empty)
        XCTAssertEqual(BarcodeParser.interpretManualEntry("075496000408"), .invalid)
    }

    func testUPCEExpandsUsingPublishedExamples() {
        // Wikipedia / barcode references: UPC-E 654321 → UPC-A 065100004327.
        let eight = BarcodeParser.parse(payload: "06543217", metadataType: "org.gs1.UPC-E")
        let six = BarcodeParser.parse(payload: "654321")
        XCTAssertEqual(eight?.symbology, .upce)
        XCTAssertEqual(eight?.normalizedCode, "0065100004327")
        XCTAssertEqual(six?.normalizedCode, eight?.normalizedCode)

        // Barcode Press worked example: body 123456, number system 0 → UPC-A 012345000065.
        // These digits are also a valid EAN-8, so the UPC-E reading needs the camera's hint.
        let second = BarcodeParser.parse(payload: "01234565", metadataType: "org.gs1.UPC-E")
        XCTAssertEqual(second?.symbology, .upce)
        XCTAssertEqual(second?.normalizedCode, "0012345000065")

        // 06543217 is not a valid EAN-8, so an unlabeled entry still expands.
        XCTAssertEqual(BarcodeParser.parse(payload: "06543217")?.symbology, .upce)
        XCTAssertEqual(BarcodeParser.parse(payload: "06543217")?.normalizedCode, "0065100004327")
        // 01234565 is both. Without a hint the printed digits stay an EAN-8.
        XCTAssertEqual(BarcodeParser.parse(payload: "01234565")?.symbology, .ean8)
        XCTAssertEqual(BarcodeParser.parse(payload: "01234565")?.normalizedCode, "01234565")
    }

    func testEAN8IsNotRewrittenWhenTheCameraNamesIt() {
        let hinted = BarcodeParser.parse(payload: "06543217", metadataType: "org.gs1.EAN-8")
        XCTAssertNil(hinted)

        let ean8 = BarcodeParser.parse(payload: "55123457", metadataType: "org.gs1.EAN-8")
        XCTAssertEqual(ean8?.symbology, .ean8)
        XCTAssertEqual(ean8?.normalizedCode, "55123457")
    }

    func testITF14AndGS1ElementStringResolveToTheConsumerGTIN() {
        let itf = BarcodeParser.parse(payload: "10075496000404", metadataType: "org.gs1.ITF14")
        XCTAssertEqual(itf?.symbology, .itf14)
        XCTAssertEqual(itf?.normalizedCode, "0075496000407")

        let element = BarcodeParser.parse(payload: "(01)00075496000407")
        XCTAssertEqual(element?.normalizedCode, "0075496000407")
        XCTAssertEqual(element?.symbology, .code128)
    }

    func testGroupedUPCFormatting() {
        XCTAssertEqual(BarcodeFormatting.grouped("0075496000407"), "0 75496 00040 7")
    }

    // MARK: - Catalog and confirm

    func testEveryCatalogEntryIsAValidKnownIngredient() {
        var seen = Set<String>()
        for entry in BarcodeCatalog.entries {
            XCTAssertEqual(entry.gtin.count, 13, entry.displayName)
            XCTAssertTrue(BarcodeCheckDigit.isValidGTIN(entry.gtin), entry.displayName)
            XCTAssertTrue(seen.insert(entry.gtin).inserted, "duplicate \(entry.gtin)")
            let parsed = BarcodeParser.parse(payload: entry.gtin)
            XCTAssertEqual(parsed?.normalizedCode, entry.gtin)
            let canonical = IngredientNormalizer.canonicalName(for: entry.displayName)
            XCTAssertNotEqual(
                IngredientNormalizer.category(for: entry.displayName),
                .other,
                "\(entry.displayName) should map onto a known category (\(canonical))"
            )
        }
    }

    func testKnownCodesConfirmAsCanonicalIngredients() {
        let expectations: [(String, String, String, InventoryCategory)] = [
            ("075496000407", "Angostura Bitters", "angostura bitters", .bitters),
            ("721059047500", "Campari", "campari", .liqueurs),
            ("087236565107", "Cointreau", "orange liqueur", .liqueurs),
            ("898804001008", "St-Germain", "elderflower liqueur", .liqueurs),
            ("088004190187", "Peychaud's Bitters", "peychauds bitters", .bitters),
            ("089540122717", "Kahlúa", "coffee liqueur", .liqueurs),
            ("898195001175", "Fever-Tree Tonic", "tonic water", .mixers),
            ("088110110307", "Tanqueray", "gin", .spirits),
            ("619947000020", "Tito's", "vodka", .spirits),
            ("086767210067", "Baileys", "irish cream", .liqueurs),
        ]
        for (code, display, canonical, category) in expectations {
            guard let parsed = BarcodeParser.parse(payload: code) else {
                XCTFail("\(code) did not parse")
                continue
            }
            guard case .add(let draft) = BarcodeResolver.plan(parsed: parsed, stock: []) else {
                XCTFail("\(display) should be a new confirm")
                continue
            }
            XCTAssertEqual(draft.displayName, display)
            XCTAssertTrue(draft.isRecognized)
            let confirmed = BarcodeConfirmedItem.make(name: draft.displayName, barcode: draft.barcode)
            XCTAssertEqual(confirmed?.canonicalName, canonical)
            XCTAssertEqual(confirmed?.category, category)
            XCTAssertEqual(confirmed?.isInStock, true)
            XCTAssertEqual(confirmed?.barcode, parsed.normalizedCode)
        }
    }

    func testUnknownCodeNeedsAManualNameAndStillNormalizes() {
        let parsed = BarcodeParser.parse(payload: "012345678905")
        XCTAssertEqual(parsed?.normalizedCode, "0012345678905")
        guard let parsed else {
            XCTFail("expected a valid unused GTIN")
            return
        }
        XCTAssertEqual(BarcodeResolver.plan(parsed: parsed, stock: []), .needsName(barcode: "0012345678905"))

        let confirmed = BarcodeConfirmedItem.make(name: "Maker's Mark", barcode: "012345678905")
        XCTAssertEqual(confirmed?.name, "Maker's Mark")
        XCTAssertEqual(confirmed?.canonicalName, "bourbon")
        XCTAssertEqual(confirmed?.category, .spirits)
        XCTAssertEqual(confirmed?.barcode, "0012345678905")
        XCTAssertNil(BarcodeConfirmedItem.make(name: "   ", barcode: "012345678905"))
        XCTAssertNil(BarcodeResolver.commit(name: " ", barcode: "012345678905", stock: []))
    }

    func testEditedNameReplacesTheCatalogGuess() {
        guard case .insert(let item) = BarcodeResolver.commit(
            name: "Lime Juice",
            barcode: "088110110307",
            stock: []
        ) else {
            XCTFail("an edited name should still add")
            return
        }
        XCTAssertEqual(item.name, "Lime Juice")
        XCTAssertEqual(item.canonicalName, "lime juice")
        XCTAssertEqual(item.category, .juices)
        XCTAssertEqual(item.barcode, "0088110110307")
    }

    func testExistingBarcodeIsNotAddedTwice() {
        let stock = [
            BarcodeStockSnapshot(name: "Angostura Bitters", barcode: "075496000407", isInStock: true),
        ]
        let parsed = BarcodeParser.parse(payload: "0075496000407")!
        guard case .alreadyInBar(let match) = BarcodeResolver.plan(parsed: parsed, stock: stock) else {
            XCTFail("expected the stocked bottle")
            return
        }
        XCTAssertEqual(match.name, "Angostura Bitters")
        XCTAssertFalse(match.canAttachBarcode)
        XCTAssertTrue(match.holdsScannedCode)
        XCTAssertEqual(
            BarcodeResolver.existingAction(isInStock: match.isInStock, canAttachBarcode: match.canAttachBarcode),
            .none
        )
    }

    func testOutOfStockBarcodeOffersMarkInStock() {
        let stock = [
            BarcodeStockSnapshot(name: "Campari", barcode: "0721059047500", isInStock: false),
        ]
        let parsed = BarcodeParser.parse(payload: "721059047500")!
        guard case .alreadyInBar(let match) = BarcodeResolver.plan(parsed: parsed, stock: stock) else {
            XCTFail("expected the stocked bottle")
            return
        }
        XCTAssertEqual(
            BarcodeResolver.existingAction(isInStock: match.isInStock, canAttachBarcode: match.canAttachBarcode),
            .markInStock
        )
        XCTAssertEqual(BarcodeExistingAction.markInStock.buttonTitle, "Mark in stock")
    }

    func testKnownBottleWithoutBarcodeSavesTheCode() {
        let stock = [
            BarcodeStockSnapshot(name: "Tanqueray", barcode: nil, isInStock: true),
        ]
        let parsed = BarcodeParser.parse(payload: "088110110307")!
        guard case .alreadyInBar(let match) = BarcodeResolver.plan(parsed: parsed, stock: stock) else {
            XCTFail("expected to attach the code")
            return
        }
        XCTAssertTrue(match.canAttachBarcode)
        XCTAssertEqual(match.scannedCode, "0088110110307")
        XCTAssertEqual(
            BarcodeResolver.existingAction(isInStock: true, canAttachBarcode: true),
            .saveBarcode
        )
    }

    func testOutOfStockKnownBottleMarksInStockAndSavesBarcode() {
        let stock = [
            BarcodeStockSnapshot(name: "Tanqueray", barcode: "", isInStock: false),
        ]
        guard case .alreadyInBar(let match) = BarcodeResolver.commit(
            name: "Tanqueray",
            barcode: "088110110307",
            stock: stock
        ) else {
            XCTFail("expected the existing row")
            return
        }
        XCTAssertEqual(
            BarcodeResolver.existingAction(isInStock: match.isInStock, canAttachBarcode: match.canAttachBarcode),
            .markInStockAndSaveBarcode
        )
        XCTAssertEqual(
            BarcodeExistingAction.markInStockAndSaveBarcode.buttonTitle,
            "Mark in stock and save barcode"
        )
    }

    func testDifferentBarcodeDoesNotOverwriteTheSavedCode() {
        let stock = [
            BarcodeStockSnapshot(name: "Tanqueray", barcode: "0012345678905", isInStock: true),
        ]
        guard case .alreadyInBar(let match) = BarcodeResolver.commit(
            name: "Tanqueray",
            barcode: "088110110307",
            stock: stock
        ) else {
            XCTFail("expected the existing name")
            return
        }
        XCTAssertFalse(match.canAttachBarcode)
        XCTAssertFalse(match.holdsScannedCode)
        XCTAssertEqual(
            BarcodeResolver.existingAction(isInStock: match.isInStock, canAttachBarcode: match.canAttachBarcode),
            .none
        )
    }

    func testPreviouslyEnteredUnknownCodeIsRecognizedFromTheBar() {
        let stock = [
            BarcodeStockSnapshot(name: "Well Gin", barcode: "0012345678905", isInStock: true),
        ]
        let parsed = BarcodeParser.parse(payload: "012345678905")!
        guard case .alreadyInBar(let match) = BarcodeResolver.plan(parsed: parsed, stock: stock) else {
            XCTFail("a saved barcode should match without the catalog")
            return
        }
        XCTAssertEqual(match.name, "Well Gin")
        XCTAssertFalse(match.canAttachBarcode)
    }

    // MARK: - Row identity, stock toggle, duplicates

    func testRestockFollowsTheScannedRowWhenNamesCollide() {
        let stock = [
            BarcodeStockSnapshot(name: "Tanqueray", barcode: nil, isInStock: false, rowID: "plain"),
            BarcodeStockSnapshot(name: "Tanqueray", barcode: "0088110110307", isInStock: false, rowID: "coded"),
        ]
        guard let parsed = BarcodeParser.parse(payload: "088110110307") else {
            XCTFail("expected the Tanqueray code to parse")
            return
        }
        guard case .alreadyInBar(let match) = BarcodeResolver.plan(parsed: parsed, stock: stock) else {
            XCTFail("expected the coded bottle")
            return
        }
        XCTAssertEqual(match.rowID, "coded")
        XCTAssertFalse(match.isInStock)
        XCTAssertTrue(match.holdsScannedCode)

        var stale = stock
        stale[0].barcode = nil
        stale[1].barcode = nil
        XCTAssertEqual(BarcodeResolver.locate(match, stock: stale), 1)

        let mutation = BarcodeResolver.mutation(match: match, row: stock[1], update: .confirmedSheet)
        XCTAssertTrue(mutation.didChange)
        XCTAssertTrue(mutation.isInStock)
        XCTAssertEqual(mutation.barcode, "0088110110307")
    }

    func testLocatePrefersBarcodeWhenTheMatchHasNoRowIdentity() {
        let stock = [
            BarcodeStockSnapshot(name: "Tanqueray", barcode: nil, isInStock: false),
            BarcodeStockSnapshot(name: "Tanqueray", barcode: "0088110110307", isInStock: false),
        ]
        let parsed = BarcodeParser.parse(payload: "088110110307")!
        guard case .alreadyInBar(let match) = BarcodeResolver.plan(parsed: parsed, stock: stock) else {
            XCTFail("expected the coded bottle")
            return
        }
        var stripped = match
        stripped.rowID = nil
        XCTAssertEqual(BarcodeResolver.locate(stripped, stock: stock), 1)
        let mutation = BarcodeResolver.mutation(match: stripped, row: stock[1], update: .confirmedSheet)
        XCTAssertTrue(mutation.isInStock)
        XCTAssertFalse(stock[0].isInStock)
    }

    @MainActor
    func testPersistentRowIdentitySelectsTheScannedBottle() throws {
        let schema = Schema([Recipe.self, IngredientLine.self, InventoryItem.self, ShoppingListItem.self, Venue.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let plain = InventoryItem(name: "Tanqueray", category: .spirits, isInStock: false)
        let coded = InventoryItem(name: "Tanqueray", category: .spirits, isInStock: false)
        coded.barcode = "0088110110307"
        context.insert(plain)
        context.insert(coded)
        try context.save()
        let plainKey = plain.barcodeRowID
        let codedKey = coded.barcodeRowID
        XCTAssertNotEqual(plainKey, codedKey)

        let stock = [BarcodeStockSnapshot(item: plain), BarcodeStockSnapshot(item: coded)]
        XCTAssertEqual(stock[0].rowID, plainKey)
        XCTAssertEqual(stock[1].rowID, codedKey)
        let parsed = try XCTUnwrap(BarcodeParser.parse(payload: "088110110307"))
        guard case .alreadyInBar(let match) = BarcodeResolver.plan(parsed: parsed, stock: stock) else {
            XCTFail("expected the coded bottle")
            return
        }
        XCTAssertEqual(match.rowID, codedKey)

        var stale = stock
        stale[0].barcode = nil
        stale[1].barcode = nil
        let index = try XCTUnwrap(BarcodeResolver.locate(match, stock: stale))
        let mutation = BarcodeResolver.mutation(match: match, row: stock[index], update: .confirmedSheet)
        let target = index == 0 ? plain : coded
        let other = index == 0 ? coded : plain
        target.isInStock = mutation.isInStock
        target.barcode = mutation.barcode
        XCTAssertEqual(index, 1)
        XCTAssertFalse(other.isInStock)
        XCTAssertNil(plain.barcode)
        XCTAssertTrue(coded.isInStock)
        XCTAssertTrue(BarcodeParser.sameProductCode(coded.barcode, "088110110307"))
    }

    func testUnknownSaveHonorsAnOffStockToggle() {
        let stock = [
            BarcodeStockSnapshot(name: "Well Gin", barcode: nil, isInStock: false, rowID: "gin"),
        ]
        guard case .update(let match, let mutation) = BarcodeResolver.saveUnknownCode(
            name: "Well Gin",
            barcode: "012345678905",
            isInStock: false,
            isLowStock: false,
            stock: stock
        ) else {
            XCTFail("the named bottle should be updated")
            return
        }
        XCTAssertEqual(match.rowID, "gin")
        XCTAssertFalse(mutation.isInStock)
        XCTAssertEqual(mutation.barcode, "0012345678905")
        XCTAssertTrue(mutation.didChange)
    }

    func testUnknownSaveRestocksWhenTheToggleStaysOn() {
        let stock = [
            BarcodeStockSnapshot(name: "Well Gin", barcode: nil, isInStock: false, rowID: "gin"),
        ]
        guard case .update(_, let mutation) = BarcodeResolver.saveUnknownCode(
            name: "well gin",
            barcode: "012345678905",
            isInStock: true,
            isLowStock: false,
            stock: stock
        ) else {
            XCTFail("the named bottle should be updated")
            return
        }
        XCTAssertTrue(mutation.isInStock)
        XCTAssertEqual(mutation.barcode, "0012345678905")
    }

    func testUnknownSaveUpdatesTheCodedRowWhenNamesCollide() {
        let stock = [
            BarcodeStockSnapshot(name: "Well Gin", barcode: nil, isInStock: false, rowID: "plain"),
            BarcodeStockSnapshot(name: "Well Gin", barcode: "0012345678905", isInStock: false, rowID: "coded"),
        ]
        guard case .update(let match, let mutation) = BarcodeResolver.saveUnknownCode(
            name: "Well Gin",
            barcode: "012345678905",
            isInStock: true,
            isLowStock: false,
            stock: stock
        ) else {
            XCTFail("the coded row should be restocked")
            return
        }
        XCTAssertEqual(match.rowID, "coded")
        XCTAssertEqual(BarcodeResolver.locate(match, stock: stock), 1)
        XCTAssertTrue(mutation.isInStock)
        XCTAssertEqual(mutation.barcode, "0012345678905")
    }

    func testUnknownDuplicateOffersTheExistingBottle() {
        let stock = [
            BarcodeStockSnapshot(name: "Well Gin", barcode: "0012345678905", isInStock: true, rowID: "gin"),
        ]
        guard case .offerExisting(let match) = BarcodeResolver.saveUnknownCode(
            name: "Well Gin",
            barcode: "088110110307",
            isInStock: true,
            isLowStock: false,
            stock: stock
        ) else {
            XCTFail("a different barcode should be offered instead of discarded")
            return
        }
        XCTAssertEqual(match.name, "Well Gin")
        XCTAssertEqual(match.rowID, "gin")
        XCTAssertFalse(match.canAttachBarcode)
        XCTAssertFalse(match.holdsScannedCode)
        XCTAssertEqual(BarcodeResolver.locate(match, stock: stock), 0)
    }

    func testUnknownSaveOffersWhenTheCodeIsAlreadySaved() {
        let stock = [
            BarcodeStockSnapshot(name: "Well Gin", barcode: "0012345678905", isInStock: true, rowID: "gin"),
        ]
        guard case .offerExisting(let match) = BarcodeResolver.saveUnknownCode(
            name: "Well Gin",
            barcode: "012345678905",
            isInStock: true,
            isLowStock: false,
            stock: stock
        ) else {
            XCTFail("saving a code that is already on the bottle should offer it, not dismiss")
            return
        }
        XCTAssertTrue(match.holdsScannedCode)
        XCTAssertEqual(match.rowID, "gin")
    }

    func testUnknownSaveDoesNotForceRestockWhenTheToggleIsOff() {
        let stock = [
            BarcodeStockSnapshot(name: "Well Gin", barcode: "0012345678905", isInStock: false, rowID: "gin"),
        ]
        guard case .offerExisting(let match) = BarcodeResolver.saveUnknownCode(
            name: "Well Gin",
            barcode: "012345678905",
            isInStock: false,
            isLowStock: false,
            stock: stock
        ) else {
            XCTFail("an unchanged out-of-stock bottle should be offered, not marked in stock")
            return
        }
        XCTAssertFalse(match.isInStock)
        XCTAssertTrue(match.holdsScannedCode)
    }

    func testUnknownSaveDoesNotRewriteABottleWhoseNameWasNotTyped() {
        let stock = [
            BarcodeStockSnapshot(name: "Well Gin", barcode: "0012345678905", isInStock: false, rowID: "gin"),
        ]
        guard case .offerExisting(let match) = BarcodeResolver.saveUnknownCode(
            name: "Maker's Mark",
            barcode: "012345678905",
            isInStock: true,
            isLowStock: false,
            stock: stock
        ) else {
            XCTFail("the barcode already belongs to Well Gin")
            return
        }
        XCTAssertEqual(match.name, "Well Gin")
        XCTAssertEqual(match.rowID, "gin")
        XCTAssertFalse(match.isInStock)
    }

    func testNewUnknownBottleKeepsTheStockToggle() {
        guard case .insert(let item) = BarcodeResolver.saveUnknownCode(
            name: "Maker's Mark",
            barcode: "012345678905",
            isInStock: false,
            isLowStock: false,
            stock: []
        ) else {
            XCTFail("a new name should insert")
            return
        }
        XCTAssertEqual(item.name, "Maker's Mark")
        XCTAssertFalse(item.isInStock)
        XCTAssertEqual(item.barcode, "0012345678905")
    }

    // MARK: - Dismissed scan does not retrigger

    func testDismissedSheetDoesNotReopenWhileTheCodeStaysInFrame() {
        var latch = BarcodeScanLatch()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(latch.receive(payload: "075496000407", now: start))
        XCTAssertFalse(latch.receive(payload: "075496000407", now: start.addingTimeInterval(0.1)))

        latch.noteSheetDismissed(now: start.addingTimeInterval(4))
        XCTAssertFalse(latch.receive(payload: "075496000407", now: start.addingTimeInterval(8)))
        XCTAssertFalse(latch.receive(payload: "075496000407", now: start.addingTimeInterval(8.2)))
        XCTAssertFalse(latch.receive(payload: "075496000407", now: start.addingTimeInterval(9.5)))
    }

    func testSameBottleCanScanAgainAfterItLeavesTheFrame() {
        var latch = BarcodeScanLatch()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(latch.receive(payload: "075496000407", now: start))
        latch.noteSheetDismissed(now: start.addingTimeInterval(1))
        XCTAssertFalse(latch.receive(payload: "075496000407", now: start.addingTimeInterval(1.1)))
        let returned = start.addingTimeInterval(1.1 + BarcodeScanLatch.quietInterval + 0.05)
        XCTAssertTrue(latch.receive(payload: "075496000407", now: returned))
    }

    func testADifferentBottleClearsTheDismissalHold() {
        var latch = BarcodeScanLatch()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(latch.receive(payload: "075496000407", now: start))
        latch.noteSheetDismissed(now: start.addingTimeInterval(1))
        XCTAssertTrue(latch.receive(payload: "0721059047500", now: start.addingTimeInterval(1.2)))
    }

    // MARK: - Ambiguous manual entry and QR

    func testManualEightDigitsAreNotExpandedWhenTheyAreAlsoEAN8() {
        XCTAssertEqual(BarcodeParser.parse(payload: "01000009")?.symbology, .ean8)
        XCTAssertEqual(BarcodeParser.parse(payload: "01000009")?.normalizedCode, "01000009")
        XCTAssertEqual(
            BarcodeParser.parse(payload: "01000009", metadataType: "org.gs1.EAN-8")?.normalizedCode,
            "01000009"
        )
        XCTAssertEqual(BarcodeParser.parse(payload: "01000009", metadataType: "org.gs1.UPC-E")?.symbology, .upce)
        XCTAssertEqual(
            BarcodeParser.parse(payload: "01000009", metadataType: "org.gs1.UPC-E")?.normalizedCode,
            "0010000000009"
        )
        XCTAssertFalse(BarcodeParser.sameProductCode("01000009", "0010000000009"))
        XCTAssertTrue(BarcodeParser.sameProductCode("01000009", "0100 0009"))

        guard case .ambiguous(let ean8, let upce) = BarcodeParser.interpretManualEntry("01000009") else {
            XCTFail("manual entry should ask which symbology was printed")
            return
        }
        XCTAssertEqual(ean8.normalizedCode, "01000009")
        XCTAssertEqual(ean8.symbology, .ean8)
        XCTAssertEqual(upce.normalizedCode, "0010000000009")
        XCTAssertEqual(upce.symbology, .upce)

        guard case .ambiguous = BarcodeResolver.resolveManualEntry("01000009", stock: []) else {
            XCTFail("neither reading is already in the bar")
            return
        }
        let eanStock = [BarcodeStockSnapshot(name: "House Bitters", barcode: "01000009", isInStock: true)]
        guard case .parsed(let chosenEAN) = BarcodeResolver.resolveManualEntry("01000009", stock: eanStock) else {
            XCTFail("the saved EAN-8 should win")
            return
        }
        XCTAssertEqual(chosenEAN.symbology, .ean8)
        XCTAssertEqual(chosenEAN.normalizedCode, "01000009")

        let upcStock = [BarcodeStockSnapshot(name: "Other Bottle", barcode: "0010000000009", isInStock: true)]
        guard case .parsed(let chosenUPC) = BarcodeResolver.resolveManualEntry("01000009", stock: upcStock) else {
            XCTFail("the saved UPC-E should win")
            return
        }
        XCTAssertEqual(chosenUPC.symbology, .upce)
        XCTAssertEqual(chosenUPC.normalizedCode, "0010000000009")
    }

    func testProductBarcodeBeatsALeadingMarketingQR() {
        let chosen = BarcodeCaptureSelection.preferred([
            BarcodeSymbol(payload: "https://brand.example/bottle", type: "org.iso.QRCode"),
            BarcodeSymbol(payload: "075496000407", type: "org.gs1.EAN-13"),
        ])
        XCTAssertEqual(chosen?.payload, "075496000407")
        XCTAssertEqual(chosen?.type, "org.gs1.EAN-13")

        let onlyQR = BarcodeCaptureSelection.preferred([
            BarcodeSymbol(payload: "https://brand.example/bottle", type: "org.iso.QRCode"),
        ])
        XCTAssertEqual(onlyQR?.payload, "https://brand.example/bottle")
        XCTAssertNil(BarcodeParser.parse(payload: onlyQR?.payload ?? "", metadataType: onlyQR?.type))
    }

    // MARK: - Camera availability

    func testCameraReadinessMatrix() {
        let cases: [(Bool, CameraAuthorizationState, BarcodeCameraReadiness)] = [
            (false, .authorized, .unavailable),
            (false, .notDetermined, .unavailable),
            (false, .denied, .unavailable),
            (false, .restricted, .unavailable),
            (true, .authorized, .ready),
            (true, .notDetermined, .needsPermission),
            (true, .denied, .denied),
            (true, .restricted, .restricted),
        ]
        for (hardware, authorization, expected) in cases {
            XCTAssertEqual(
                BarcodeCameraPolicy.readiness(hardwarePresent: hardware, authorization: authorization),
                expected
            )
        }
    }

    func testFallbackCopyIsHonest() {
        XCTAssertNil(BarcodeCameraReadiness.ready.fallbackTitle)
        XCTAssertNil(BarcodeCameraReadiness.needsPermission.fallbackTitle)
        XCTAssertFalse(BarcodeCameraReadiness.ready.offersSettings)

        XCTAssertEqual(BarcodeCameraReadiness.unavailable.fallbackTitle, "No camera on this device")
        XCTAssertTrue(BarcodeCameraReadiness.unavailable.fallbackMessage?.contains("Enter the numbers") == true)
        XCTAssertTrue(BarcodeCameraReadiness.unavailable.fallbackMessage?.contains("add the bottle by name") == true)
        XCTAssertFalse(BarcodeCameraReadiness.unavailable.offersSettings)

        XCTAssertEqual(BarcodeCameraReadiness.denied.fallbackTitle, "Camera access is off")
        XCTAssertTrue(BarcodeCameraReadiness.denied.fallbackMessage?.contains("Settings") == true)
        XCTAssertTrue(BarcodeCameraReadiness.denied.offersSettings)

        XCTAssertEqual(BarcodeCameraReadiness.restricted.fallbackTitle, "Camera is restricted")
        XCTAssertFalse(BarcodeCameraReadiness.restricted.offersSettings)
        XCTAssertTrue(BarcodeCameraReadiness.restricted.fallbackMessage?.contains("add the bottle by name") == true)
    }
}
