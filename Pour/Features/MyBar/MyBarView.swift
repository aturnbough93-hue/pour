import SwiftUI
import SwiftData

struct MyBarView: View {
    @Query(sort: \InventoryItem.name) private var items: [InventoryItem]
    @Environment(\.modelContext) private var modelContext

    @State private var showSaveError = false
    @State private var searchText = ""
    @State private var filter: StockFilter = .all
    @State private var showAdd = false
    @State private var showScanner = false
    @State private var editingItem: InventoryItem? = nil

    enum StockFilter: String, CaseIterable {
        case all = "All", inStock = "In stock", out = "Out", low = "Low"
    }

    private var filtered: [InventoryItem] {
        let q = IngredientNormalizer.normalize(searchText)
        return items.filter { item in
            let matchesQuery = q.isEmpty
                || IngredientNormalizer.normalize(item.name).contains(q)
                || item.canonicalName.contains(q)
            let matchesFilter: Bool = {
                switch filter {
                case .all: return true
                case .inStock: return item.isInStock
                case .out: return !item.isInStock
                case .low: return item.isLowStock
                }
            }()
            return matchesQuery && matchesFilter
        }
    }

    private var grouped: [(InventoryCategory, [InventoryItem])] {
        var groups: [InventoryCategory: [InventoryItem]] = [:]
        for item in filtered { groups[item.inventoryCategory, default: []].append(item) }
        return InventoryCategory.allCases
            .filter { !(groups[$0] ?? []).isEmpty }
            .map { ($0, groups[$0]!.sorted { $0.name < $1.name }) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    EmptyStateView(
                        symbol: "square.stack.3d.up",
                        title: "Your bar is empty",
                        message: "Add bottles and staples so Pour can tell you what you can make.",
                        actionTitle: "Add your first item"
                    ) {
                        showAdd = true
                    }
                } else if filtered.isEmpty {
                    EmptyStateView(symbol: "magnifyingglass", title: "No ingredients found", message: "Try another name or stock filter.", actionTitle: "Clear filters") {
                        searchText = ""
                        filter = .all
                    }
                } else {
                    List {
                        ForEach(grouped, id: \.0) { category, categoryItems in
                            Section {
                                ForEach(categoryItems) { item in
                                    inventoryRow(item)
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                modelContext.delete(item)
                                                saveChanges()
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                }
                            } header: {
                                Label("\(category.displayName) (\(categoryItems.count))", systemImage: category.symbol)
                                    .foregroundStyle(PourColor.textSecondary)
                                    .accessibilityLabel("\(category.displayName), \(categoryItems.count) ingredients")
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(PourColor.background)
            .navigationTitle("My Bar")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search ingredients")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showScanner = true
                    } label: {
                        Image(systemName: "barcode.viewfinder")
                            .foregroundStyle(PourColor.textSecondary)
                    }
                    .accessibilityLabel("Scan barcode to add ingredient")
                    .accessibilityAddTraits(.isButton)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingItem = nil
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(PourColor.accent)
                    }
                    .accessibilityLabel("Add inventory item")
                    .accessibilityAddTraits(.isButton)
                }
            }
            .safeAreaInset(edge: .top) { filterChips }
            .sheet(isPresented: $showAdd) { InventoryEditSheet(item: nil) }
            .sheet(item: $editingItem) { item in InventoryEditSheet(item: item) }
            .sheet(isPresented: $showScanner) { BarcodeScannerView() }
            .alert("Bar wasn’t updated", isPresented: $showSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check available device storage and try again.")
            }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(StockFilter.allCases, id: \.self) { option in
                    let selected = filter == option
                    Button {
                        filter = option
                        Haptics.selection()
                    } label: {
                        Text(option.rawValue)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(selected ? .black : PourColor.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selected ? PourColor.accentFill : PourColor.surface, in: Capsule())
                    }
                    .accessibilityLabel("\(option.rawValue), \(selected ? "selected" : "not selected")")
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(PourColor.background)
    }

    private func inventoryRow(_ item: InventoryItem) -> some View {
        HStack(spacing: 12) {
            Button {
                item.isInStock.toggle()
                saveChanges()
                item.isInStock ? Haptics.mediumTap() : Haptics.lightTick()
            } label: {
                Image(systemName: item.isInStock ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.isInStock ? PourColor.canMake : PourColor.textTertiary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("\(item.name), \(item.isInStock ? "in stock" : "not in stock")")
            .accessibilityAddTraits(item.isInStock ? [.isButton, .isSelected] : .isButton)

            Button {
                editingItem = item
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.body)
                        .foregroundStyle(item.isInStock ? PourColor.textPrimary : PourColor.textSecondary)
                    HStack(spacing: 6) {
                        Text(item.inventoryCategory.displayName)
                        if item.canonicalName != IngredientNormalizer.normalize(item.name) {
                            Text("·")
                            Text(item.canonicalName)
                                .foregroundStyle(PourColor.textTertiary)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(PourColor.textTertiary)
                }
            }
            .accessibilityLabel("Edit \(item.name)")
            .accessibilityAddTraits(.isButton)

            Spacer()

            if item.isLowStock {
                Button {
                    item.isLowStock = false
                    saveChanges()
                } label: {
                    StatusPill(kind: .lowStock)
                }
                .accessibilityLabel("\(item.name), low stock")
                .accessibilityAddTraits(.isButton)
            }
        }
        .frame(minHeight: 52)
        .buttonStyle(.borderless)
        .listRowBackground(PourColor.card)
    }

    private func saveChanges() {
        do { try modelContext.save() }
        catch {
            modelContext.rollback()
            showSaveError = true
        }
    }
}

/// Prefill for the existing add sheet when a scan needs a name, or when the
/// bartender already knows which bottle a code belongs to.
struct InventorySeed: Equatable {
    var name: String = ""
    var barcode: String?
    var scanNote: String?
}

enum InventoryEditResult: Equatable {
    case saved
    case alreadyInBar(ExistingBarcodeMatch)
}

// MARK: - Add / edit item sheet

struct InventoryEditSheet: View {
    let item: InventoryItem?
    var seed: InventorySeed?
    var onFinished: ((InventoryEditResult) -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var recipes: [Recipe]
    @Query private var inventory: [InventoryItem]

    @State private var showSaveError = false
    @State private var duplicateOffer: ExistingBarcodeMatch?
    @State private var name = ""
    @State private var category: InventoryCategory = .other
    @State private var isInStock = true
    @State private var isLowStock = false
    @State private var canonicalOverride = ""
    @State private var barcode = ""

    /// Canonical ingredients required by recipes but not in inventory — one-tap add.
    private var suggestedMissing: [String] {
        var missing: [String] = []
        var seen = Set<String>()
        for match in RecipeEngine.rankedMatches(recipes: recipes, inventory: inventory) {
            for line in match.missing {
                if seen.insert(line.canonicalName).inserted {
                    missing.append(line.name)
                }
            }
            if missing.count >= 6 { break }
        }
        return missing
    }

    init(item: InventoryItem?, seed: InventorySeed? = nil, onFinished: ((InventoryEditResult) -> Void)? = nil) {
        self.item = item
        self.seed = seed
        self.onFinished = onFinished
        _name = State(initialValue: item?.name ?? seed?.name ?? "")
        _category = State(initialValue: item?.inventoryCategory ?? IngredientNormalizer.category(for: seed?.name ?? ""))
        _isInStock = State(initialValue: item?.isInStock ?? true)
        _isLowStock = State(initialValue: item?.isLowStock ?? false)
        _canonicalOverride = State(initialValue: item?.canonicalOverride ?? "")
        _barcode = State(initialValue: item?.barcode ?? seed?.barcode ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let note = seed?.scanNote {
                    Section {
                        Label(note, systemImage: "barcode.viewfinder")
                            .font(.subheadline)
                            .foregroundStyle(PourColor.textSecondary)
                            .accessibilityLabel(note)
                    }
                }
                Section("Item") {
                    TextField("Name (e.g. London Dry Gin)", text: $name)
                        .onChange(of: name) { _, new in
                            if item == nil {
                                category = IngredientNormalizer.category(for: new)
                            }
                        }
                    Picker("Category", selection: $category) {
                        ForEach(InventoryCategory.allCases, id: \.self) {
                            Label($0.displayName, systemImage: $0.symbol).tag($0)
                        }
                    }
                    .accessibilityLabel("Category")
                    Toggle("In stock", isOn: $isInStock)
                        .accessibilityLabel("In stock, \(isInStock ? "on" : "off")")
                    Toggle("Low stock", isOn: $isLowStock)
                        .accessibilityLabel("Low stock, \(isLowStock ? "on" : "off")")
                }
                Section {
                    TextField("Canonical ingredient (optional)", text: $canonicalOverride)
                        .autocorrectionDisabled()
                } header: {
                    Text("Matching")
                } footer: {
                    Text("Maps to “\(canonicalOverride.isEmpty ? IngredientNormalizer.canonicalName(for: name) : IngredientNormalizer.normalize(canonicalOverride))” for matching. Leave blank to use the auto-detected canonical name.")
                }
                if !barcode.isEmpty {
                    Section("Barcode") {
                        Text(BarcodeFormatting.grouped(barcode))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(PourColor.textPrimary)
                            .accessibilityLabel("Barcode \(barcode)")
                    }
                }
                if !suggestedMissing.isEmpty && item == nil {
                    Section("Missing from recipes") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(suggestedMissing, id: \.self) { suggestion in
                                    Button {
                                        name = suggestion
                                        category = IngredientNormalizer.category(for: suggestion)
                                        Haptics.selection()
                                    } label: {
                                        Text(suggestion)
                                            .font(.subheadline)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .background(PourColor.surface, in: Capsule())
                                    }
                                    .accessibilityLabel("Add \(suggestion)")
                                    .accessibilityAddTraits(.isButton)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PourColor.background)
            .alert("Item wasn’t saved", isPresented: $showSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your edits are still here. Check available device storage and try again.")
            }
            .sheet(item: $duplicateOffer) { match in
                BarcodeExistingSheet(match: match) {
                    applyDuplicateOffer(match)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityLabel("Cancel")
                        .accessibilityAddTraits(.isButton)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(item == nil && seed?.barcode != nil ? "Add to My Bar" : "Save") { save() }
                        .disabled(IngredientNormalizer.normalize(name).isEmpty)
                        .accessibilityLabel(saveAccessibilityLabel)
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    private var navigationTitle: String {
        if item != nil { return "Edit item" }
        if seed?.barcode != nil { return "Confirm item" }
        return "Add item"
    }

    private var saveAccessibilityLabel: String {
        if item != nil { return "Save item" }
        if seed?.barcode != nil { return "Add to My Bar" }
        return "Add inventory item"
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let override = IngredientNormalizer.normalize(canonicalOverride)
        let cleanedBarcode = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = inventory.map { row in
            (row, BarcodeStockSnapshot(item: row))
        }
        let stock = rows.map { $0.1 }
        if let item {
            item.name = trimmed
            item.category = category.rawValue
            item.isInStock = isInStock
            item.isLowStock = isLowStock
            item.canonicalOverride = override.isEmpty ? nil : override
            if !cleanedBarcode.isEmpty {
                item.barcode = cleanedBarcode
            }
        } else if !cleanedBarcode.isEmpty {
            switch BarcodeResolver.saveUnknownCode(
                name: trimmed,
                barcode: cleanedBarcode,
                isInStock: isInStock,
                isLowStock: isLowStock,
                stock: stock
            ) {
            case .insert(let confirmed):
                let new = InventoryItem(name: confirmed.name, category: category, isInStock: confirmed.isInStock)
                new.isLowStock = isLowStock
                new.canonicalOverride = override.isEmpty ? nil : override
                new.barcode = confirmed.barcode
                modelContext.insert(new)
            case .update(let match, let mutation):
                guard let index = BarcodeResolver.locate(match, stock: stock) else {
                    offerExisting(match)
                    return
                }
                let existing = rows[index].0
                existing.name = trimmed
                existing.category = category.rawValue
                existing.canonicalOverride = override.isEmpty ? nil : override
                existing.isInStock = mutation.isInStock
                existing.isLowStock = mutation.isLowStock
                existing.barcode = mutation.barcode
            case .offerExisting(let match):
                offerExisting(match)
                return
            case .rejected:
                return
            }
        } else {
            let new = InventoryItem(name: trimmed, category: category, isInStock: isInStock)
            new.isLowStock = isLowStock
            new.canonicalOverride = override.isEmpty ? nil : override
            modelContext.insert(new)
        }
        do {
            try modelContext.save()
            Haptics.success()
            finish(.saved)
        } catch {
            modelContext.rollback()
            showSaveError = true
        }
    }

    private func offerExisting(_ match: ExistingBarcodeMatch) {
        Haptics.warning()
        if onFinished != nil {
            finish(.alreadyInBar(match))
        } else {
            duplicateOffer = match
        }
    }

    private func applyDuplicateOffer(_ match: ExistingBarcodeMatch) {
        let rows = inventory.map { row in
            (row, BarcodeStockSnapshot(item: row))
        }
        let stock = rows.map { $0.1 }
        guard let index = BarcodeResolver.locate(match, stock: stock) else { return }
        let mutation = BarcodeResolver.mutation(match: match, row: stock[index], update: .confirmedSheet)
        guard mutation.didChange else {
            duplicateOffer = nil
            return
        }
        let existing = rows[index].0
        existing.isInStock = mutation.isInStock
        existing.barcode = mutation.barcode
        do {
            try modelContext.save()
            Haptics.success()
            duplicateOffer = nil
            dismiss()
        } catch {
            modelContext.rollback()
            duplicateOffer = nil
            showSaveError = true
        }
    }

    private func finish(_ result: InventoryEditResult) {
        if let onFinished {
            onFinished(result)
        } else {
            dismiss()
        }
    }
}
