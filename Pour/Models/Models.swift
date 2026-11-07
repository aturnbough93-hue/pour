import Foundation
import SwiftData

// All stored properties are optional or carry defaults, and every relationship is
// optional — the schema stays CloudKit-compatible so Pro sync can be layered on later.

@Model
final class Recipe {
    var name: String = ""
    var glassType: String = ""
    var method: String = ""
    var instructions: String = ""
    var garnish: String? = nil
    var tags: [String] = []
    var isCustom: Bool = false
    var isFavorite: Bool = false
    var notes: String? = nil
    var remoteID: String? = nil
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \IngredientLine.recipe)
    var ingredients: [IngredientLine] = []

    var venue: Venue? = nil

    init(
        name: String = "",
        glassType: String = "",
        method: String = "",
        instructions: String = "",
        garnish: String? = nil,
        tags: [String] = [],
        isCustom: Bool = false
    ) {
        self.name = name
        self.glassType = glassType
        self.method = method
        self.instructions = instructions
        self.garnish = garnish
        self.tags = tags
        self.isCustom = isCustom
    }

    var sortedIngredients: [IngredientLine] {
        ingredients.sorted { $0.position < $1.position }
    }

    /// A detached personal recipe with independent ingredients. Inserting it is
    /// an explicit Save action; creating or cancelling a draft never changes the classic.
    func makeVariation(named variationName: String? = nil) -> Recipe {
        let variation = Recipe(
            name: variationName ?? "\(name) variation",
            glassType: glassType,
            method: method,
            instructions: instructions,
            garnish: garnish,
            tags: tags,
            isCustom: true
        )
        variation.notes = notes
        variation.ingredients = sortedIngredients.map { line in
            IngredientLine(name: line.name, amount: line.amount, unit: line.unit,
                           note: line.note, isOptional: line.isOptional, position: line.position)
        }
        return variation
    }
}

@Model
final class IngredientLine {
    var name: String = ""
    var amount: Double = 0
    var unit: String = "oz"
    var note: String? = nil
    var isOptional: Bool = false
    var position: Int = 0
    var recipe: Recipe? = nil

    init(name: String = "", amount: Double = 0, unit: String = "oz", note: String? = nil, isOptional: Bool = false, position: Int = 0) {
        self.name = name
        self.amount = amount
        self.unit = unit
        self.note = note
        self.isOptional = isOptional
        self.position = position
    }

    var canonicalName: String {
        IngredientNormalizer.canonicalName(for: name)
    }

    var measure: Measure {
        Measure(amount: amount, unit: BarUnit.parse(unit))
    }
}

@Model
final class InventoryItem {
    var name: String = ""
    var category: String = InventoryCategory.other.rawValue
    var isInStock: Bool = true
    var isLowStock: Bool = false
    var barcode: String? = nil
    var quantity: Double? = nil
    var bottleCost: Double? = nil        // Pro
    var lowStockThreshold: Double? = nil // Pro
    var canonicalOverride: String? = nil // user-mapped canonical ingredient
    var createdAt: Date = Date()

    init(name: String = "", category: InventoryCategory = .other, isInStock: Bool = true) {
        self.name = name
        self.category = category.rawValue
        self.isInStock = isInStock
    }

    var canonicalName: String {
        canonicalOverride ?? IngredientNormalizer.canonicalName(for: name)
    }

    var inventoryCategory: InventoryCategory {
        InventoryCategory(rawValue: category) ?? .other
    }

    /// Stable identity for barcode matching. Two rows can share a display name;
    /// scans have to update the row that was actually matched.
    var barcodeRowID: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(persistentModelID),
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty {
            return text
        }
        return String(describing: persistentModelID)
    }
}

@Model
final class ShoppingListItem {
    var name: String = ""
    var canonicalName: String = ""
    var isPurchased: Bool = false
    var sourceRecipeName: String? = nil
    var createdAt: Date = Date()

    init(name: String = "", canonicalName: String? = nil, sourceRecipeName: String? = nil) {
        self.name = name
        self.canonicalName = canonicalName ?? IngredientNormalizer.canonicalName(for: name)
        self.sourceRecipeName = sourceRecipeName
    }
}

@Model
final class Venue {
    var name: String = ""
    var isCheckedIn: Bool = false
    var houseSpecNotes: String? = nil
    var createdAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \Recipe.venue)
    var recipes: [Recipe]? = []

    init(name: String = "") {
        self.name = name
    }
}
