import SwiftUI
import SwiftData

/// Clean seams for out-of-scope Pro features. Each stub matches where the spec
/// places the entry point and shows an honest, styled placeholder.

struct AssistantPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "sparkles")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(PourColor.accent)
                    .accessibilityHidden(true)
                Text("AI Bartender Assistant")
                    .font(.pourTitle2)
                    .foregroundStyle(PourColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Coming soon: ask what you can make, explore substitutions, and refine drinks together. For now, use Home to find drinks from your bar.")
                    .font(.body)
                    .foregroundStyle(PourColor.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Not now") { dismiss() }
                    .buttonStyle(PourPrimaryButtonStyle())
                    .padding(.top, 12)
                    .accessibilityLabel("Not now")
                    .accessibilityAddTraits(.isButton)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PourColor.background)
            .navigationTitle("AI Assistant")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct VoiceSearchPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "mic")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(PourColor.accent)
                    .accessibilityHidden(true)
                Text("Voice search")
                    .font(.pourTitle2)
                    .foregroundStyle(PourColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Voice search is coming soon. For now, type a drink, ingredient, or brand into search on Home.")
                    .font(.body)
                    .foregroundStyle(PourColor.textSecondary)
                    .multilineTextAlignment(.center)
                Button("OK") { dismiss() }
                    .buttonStyle(PourPrimaryButtonStyle())
                    .padding(.top, 12)
                    .accessibilityLabel("OK")
                    .accessibilityAddTraits(.isButton)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PourColor.background)
            .navigationTitle("Voice Search")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ProUpsellView: View {
    @Environment(\.dismiss) private var dismiss

    private let features: [(String, String)] = [
        ("sparkles", "AI Bartender Assistant — substitutions and suggestions"),
        ("video", "AI video generation for technique demos"),
        ("square.stack.3d.up", "Bottle-level tracking, costing and export"),
        ("person.2", "Shared inventory and venue teams"),
        ("icloud", "CloudKit sync across devices"),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "crown")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(PourColor.gold)
                    .accessibilityHidden(true)
                Text("Pour Pro")
                    .font(.pourTitle)
                    .foregroundStyle(PourColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(features, id: \.0) { symbol, text in
                        Label(text, systemImage: symbol)
                            .font(.subheadline)
                            .foregroundStyle(PourColor.textSecondary)
                    }
                }
                Text("These features are planned. Everything available today is free and works offline.")
                    .font(.caption)
                    .foregroundStyle(PourColor.textTertiary)
                    .multilineTextAlignment(.center)
                Button("Maybe later") { dismiss() }
                    .buttonStyle(PourPrimaryButtonStyle())
                    .accessibilityLabel("Maybe later")
                    .accessibilityAddTraits(.isButton)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PourColor.background)
            .navigationTitle("Pour Pro")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Minimal local venue check-in (no cloud): create a venue, check in, check out.
/// House specs and team features are Pro seams.
struct VenueSheet: View {
    @Query private var venues: [Venue]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var newVenueName = ""
    @State private var showSaveError = false

    private var checkedIn: Venue? { venues.first { $0.isCheckedIn } }

    var body: some View {
        NavigationStack {
            List {
                if venues.isEmpty {
                    Section {
                        Text("No venues yet. Add your workplace to check in and surface its menu during a shift.")
                            .font(.subheadline)
                            .foregroundStyle(PourColor.textSecondary)
                            .listRowBackground(PourColor.card)
                    }
                } else {
                    Section("Venues") {
                        ForEach(venues) { venue in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(venue.name)
                                        .font(.body)
                                        .foregroundStyle(PourColor.textPrimary)
                                    if venue.isCheckedIn {
                                        Text("Checked in")
                                            .font(.caption)
                                            .foregroundStyle(PourColor.canMake)
                                    }
                                }
                                Spacer()
                                Button(venue.isCheckedIn ? "Check out" : "Check in") {
                                    toggleCheckIn(venue)
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PourColor.accent)
                                .accessibilityLabel(venue.isCheckedIn ? "Check out of \(venue.name)" : "Check in to \(venue.name)")
                                .accessibilityAddTraits(.isButton)
                            }
                            .frame(minHeight: 52)
                            .listRowBackground(PourColor.card)
                        }
                        .onDelete { offsets in
                            for index in offsets { modelContext.delete(venues[index]) }
                            saveChanges()
                        }
                    }
                }
                Section("Add a venue") {
                    HStack(spacing: 10) {
                        TextField("Venue name", text: $newVenueName)
                            .accessibilityLabel("Venue name")
                        Button("Add") {
                            let trimmed = newVenueName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            modelContext.insert(Venue(name: trimmed))
                            if saveChanges() {
                                newVenueName = ""
                                Haptics.success()
                            }
                        }
                        .disabled(IngredientNormalizer.normalize(newVenueName).isEmpty)
                        .foregroundStyle(PourColor.accent)
                        .accessibilityLabel("Add venue")
                        .accessibilityAddTraits(.isButton)
                    }
                    .listRowBackground(PourColor.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(PourColor.background)
            .alert("Venue wasn’t saved", isPresented: $showSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check available device storage and try again.")
            }
            .navigationTitle("Venue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Done")
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    @discardableResult
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

    private func toggleCheckIn(_ venue: Venue) {
        if venue.isCheckedIn {
            venue.isCheckedIn = false
            Haptics.lightTick()
        } else {
            for other in venues { other.isCheckedIn = false }
            venue.isCheckedIn = true
            Haptics.success()
        }
        saveChanges()
    }
}
