import CoreData
import Foundation
import SwiftUI

// MARK: - Model

/// Unit of a meal preset's portion. `.portion` means the preset has no size ("1 portion").
enum MealPortionUnit: String, CaseIterable, Identifiable {
    case portion
    case grams = "g"
    case milliliters = "ml"
    case pieces = "piece"

    var id: String { rawValue }

    /// Short unit shown after an amount, e.g. "100 g".
    var symbol: String {
        switch self {
        case .portion: String(localized: "portion", comment: "A meal preset portion without a size, e.g. '1 portion'")
        case .grams: String(localized: "g", comment: "Units for carbs")
        case .milliliters: String(localized: "ml", comment: "Milliliters, unit of a meal portion")
        case .pieces: String(localized: "pcs", comment: "Pieces, unit of a meal portion")
        }
    }

    /// Label in the unit picker of the preset editor.
    var pickerLabel: String {
        switch self {
        case .portion: String(localized: "Portion", comment: "Meal portion unit picker: no size")
        case .grams: String(localized: "g", comment: "Units for carbs")
        case .milliliters: String(localized: "ml", comment: "Milliliters, unit of a meal portion")
        case .pieces: String(localized: "Pieces", comment: "Meal portion unit picker: pieces")
        }
    }
}

/// One preset in the meal being composed, with a (fractional) number of portions.
/// Nutrient values are per portion and copied from the preset, so the meal stays intact if the preset is deleted.
struct MealItem: Identifiable, Equatable {
    let id: NSManagedObjectID
    let dish: String
    let carbs: Decimal
    let fat: Decimal
    let protein: Decimal
    /// Size of one portion in `portionUnit`, `nil` when the preset has no portion size.
    let portionAmount: Decimal?
    let portionUnit: MealPortionUnit
    /// Number of portions, e.g. 0.5 or 1.5.
    var quantity: Decimal

    init(preset: MealPresetStored, quantity: Decimal) {
        id = preset.objectID
        dish = preset.dish ?? ""
        carbs = preset.carbs?.decimalValue ?? 0
        fat = preset.fat?.decimalValue ?? 0
        protein = preset.protein?.decimalValue ?? 0
        portionAmount = preset.portionSize?.amount
        portionUnit = preset.portionSize?.unit ?? .portion
        self.quantity = quantity
    }

    var totalCarbs: Decimal { carbs * quantity }
    var totalFat: Decimal { fat * quantity }
    var totalProtein: Decimal { protein * quantity }

    /// Eaten amount in the portion's unit (e.g. 150 g), `nil` for presets without a portion size.
    var amount: Decimal? { portionAmount.map { $0 * quantity } }
}

struct MealTotals: Equatable {
    var carbs: Decimal
    var fat: Decimal
    var protein: Decimal

    static let zero = MealTotals(carbs: 0, fat: 0, protein: 0)
}

extension MealPresetStored {
    /// The portion size, or `nil` when the preset is just "1 portion".
    var portionSize: (amount: Decimal, unit: MealPortionUnit)? {
        guard let unit = MealPortionUnit(rawValue: portionUnit ?? ""), unit != .portion,
              let amount = portionAmount?.decimalValue, amount > 0
        else { return nil }
        return (amount, unit)
    }

    /// e.g. "100 g", "2 pcs" or "1 portion".
    var portionLabel: String {
        guard let size = portionSize else { return MealFormat.portionLabel(amount: nil, unit: .portion) }
        return MealFormat.portionLabel(amount: size.amount, unit: size.unit)
    }
}

enum MealFormat {
    static let quickQuantities: [Decimal] = [
        Decimal(1) / 4, Decimal(1) / 2, Decimal(3) / 4, 1,
        Decimal(3) / 2, 2, Decimal(5) / 2, 3
    ]

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private static let quantityFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    static func number(_ value: Decimal) -> String {
        numberFormatter.string(from: value as NSNumber) ?? "\(value)"
    }

    /// Number of portions, using fraction glyphs where possible: "½", "1½", "2¼". Other values as decimals.
    static func quantity(_ value: Decimal) -> String {
        let whole = value.rounded(scale: 0, roundingMode: .down)
        let fraction = value - whole
        let glyph: String? = switch fraction {
        case 0: ""
        case Decimal(1) / 4: "¼"
        case Decimal(1) / 2: "½"
        case Decimal(3) / 4: "¾"
        default: nil
        }
        guard let glyph else { return quantityFormatter.string(from: value as NSNumber) ?? "\(value)" }
        if whole == 0 { return glyph.isEmpty ? "0" : glyph }
        return (quantityFormatter.string(from: whole as NSNumber) ?? "\(whole)") + glyph
    }

    static func portionLabel(amount: Decimal?, unit: MealPortionUnit) -> String {
        guard let amount, unit != .portion else {
            return String(localized: "1 portion", comment: "Meal preset without a portion size")
        }
        return "\(number(amount)) \(unit.symbol)"
    }

    /// "28 g carbs", plus fat and protein when they are shown.
    static func nutrients(carbs: Decimal, fat: Decimal, protein: Decimal, showFatAndProtein: Bool) -> String {
        var parts = [String(localized: "\(number(carbs)) g carbs", comment: "Carbs of a meal preset or meal item")]
        if showFatAndProtein {
            if fat > 0 { parts.append(String(localized: "\(number(fat)) g fat", comment: "Fat of a meal preset or meal item")) }
            if protein > 0 {
                parts.append(String(localized: "\(number(protein)) g protein", comment: "Protein of a meal preset or meal item"))
            }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Meal composer

struct MealPresetView: View {
    @Bindable var state: Treatments.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    @Environment(AppState.self) var appState

    @State private var searchText = ""
    @State private var presetEditor: PresetEditorTarget?
    @State private var quantityEditor: QuantityEditorTarget?
    @State private var presetToDelete: MealPresetStored?
    @State private var showClearMealConfirmation = false

    @FetchRequest(
        entity: MealPresetStored.entity(),
        sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
    ) var presets: FetchedResults<MealPresetStored>

    private struct PresetEditorTarget: Identifiable {
        let id = UUID()
        let preset: MealPresetStored?
    }

    private struct QuantityEditorTarget: Identifiable {
        let item: MealItem
        /// Set when the preset is not in the meal yet.
        let preset: MealPresetStored?
        var id: NSManagedObjectID { item.id }
    }

    private var showFatAndProtein: Bool { state.useFPUconversion }

    private var filteredPresets: [MealPresetStored] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(presets) }
        return presets.filter { ($0.dish ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !state.mealItems.isEmpty {
                    currentMealSection
                }
                presetsSection
                if !state.mealItems.isEmpty || state.hasUnappliedMealChanges {
                    applyButton
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .searchable(text: $searchText, prompt: Text("Search presets"))
            .navigationTitle("Meal Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presetEditor = PresetEditorTarget(preset: nil)
                    } label: {
                        HStack {
                            Text("New Preset")
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(item: $presetEditor) { target in
                AddMealPresetView(
                    preset: target.preset,
                    displayFatAndProtein: showFatAndProtein,
                    onSaved: { preset in
                        state.refreshMealItem(from: preset)
                        presetEditor = nil
                    },
                    onCancel: { presetEditor = nil }
                )
            }
            .sheet(item: $quantityEditor) { target in
                MealQuantityEditor(
                    item: target.item,
                    isInMeal: target.preset == nil,
                    displayFatAndProtein: showFatAndProtein,
                    onCommit: { quantity in
                        state.setMealQuantity(quantity, for: target.item.id, preset: target.preset)
                        quantityEditor = nil
                    },
                    onCancel: { quantityEditor = nil }
                )
                .presentationDetents([.medium, .large])
            }
            .alert(
                "Delete preset '\(presetToDelete?.dish ?? "")'?",
                isPresented: Binding(
                    get: { presetToDelete != nil },
                    set: { if !$0 { presetToDelete = nil } }
                ),
                actions: {
                    Button("Cancel", role: .cancel) { presetToDelete = nil }
                    Button("Delete", role: .destructive) {
                        if let preset = presetToDelete {
                            state.deletePreset(preset)
                        }
                        presetToDelete = nil
                    }
                },
                message: { Text("The preset is removed from your list. Your current meal is not changed.") }
            )
            .confirmationDialog(
                "Clear the current meal?",
                isPresented: $showClearMealConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Meal", role: .destructive) { state.clearMeal() }
            }
        }
    }

    // MARK: Current meal

    private var currentMealSection: some View {
        Section {
            ForEach(state.mealItems) { item in
                mealItemRow(item)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            state.removeMealItem(item.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
            }

            let totals = state.mealTotals
            HStack {
                Text("Total").fontWeight(.semibold)
                Spacer()
                Text(MealFormat.nutrients(
                    carbs: totals.carbs,
                    fat: totals.fat,
                    protein: totals.protein,
                    showFatAndProtein: showFatAndProtein
                ))
                    .font(.subheadline)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            HStack {
                Text("Current Meal")
                Spacer()
                Button("Clear Meal") { showClearMealConfirmation = true }
                    .font(.caption)
                    .textCase(nil)
                    .tint(.orange)
            }
        }
        .listRowBackground(Color.chart)
    }

    private func mealItemRow(_ item: MealItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.dish)
                    .lineLimit(1)
                Text(mealItemDetail(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button {
                state.removePortion(of: item.id)
            } label: {
                Image(systemName: "minus.circle.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Remove one serving"))

            Button {
                quantityEditor = QuantityEditorTarget(item: item, preset: nil)
            } label: {
                Text(verbatim: "\(MealFormat.quantity(item.quantity))×")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 44)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(Color.blue.opacity(0.15)))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Change amount"))

            Button {
                state.addPortion(to: item.id)
            } label: {
                Image(systemName: "plus.circle.fill").font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Add one serving"))
        }
        .tint(.blue)
    }

    private func mealItemDetail(_ item: MealItem) -> String {
        let nutrients = MealFormat.nutrients(
            carbs: item.totalCarbs,
            fat: item.totalFat,
            protein: item.totalProtein,
            showFatAndProtein: showFatAndProtein
        )
        guard let amount = item.amount else { return nutrients }
        return "\(MealFormat.number(amount)) \(item.portionUnit.symbol) · \(nutrients)"
    }

    // MARK: Presets

    private var presetsSection: some View {
        Section {
            if presets.isEmpty {
                Text("No presets yet. Tap \"New Preset\" to create one.")
                    .foregroundStyle(.secondary)
            } else if filteredPresets.isEmpty {
                Text("No presets found.")
                    .foregroundStyle(.secondary)
            }

            ForEach(filteredPresets, id: \.objectID) { preset in
                presetRow(preset)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            presetToDelete = preset
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            presetEditor = PresetEditorTarget(preset: preset)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            openQuantityEditor(for: preset)
                        } label: {
                            Label("Amount", systemImage: "slider.horizontal.3")
                        }
                        .tint(.green)
                    }
                    .contextMenu {
                        Button {
                            openQuantityEditor(for: preset)
                        } label: {
                            Label("Choose Amount…", systemImage: "slider.horizontal.3")
                        }
                        Button {
                            presetEditor = PresetEditorTarget(preset: preset)
                        } label: {
                            Label("Edit Preset", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            presetToDelete = preset
                        } label: {
                            Label("Delete Preset", systemImage: "trash")
                        }
                    }
            }
        } header: {
            Text("Saved Food")
        } footer: {
            if !presets.isEmpty {
                Text("Tap to add a portion. Swipe right or long-press to choose an amount, swipe left to edit or delete.")
            }
        }
        .listRowBackground(Color.chart)
    }

    private func presetRow(_ preset: MealPresetStored) -> some View {
        let quantity = state.mealQuantity(for: preset.objectID)
        return Button {
            state.addPortion(of: preset)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.dish ?? "")
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(verbatim: "\(preset.portionLabel) · \(presetNutrients(preset))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if quantity > 0 {
                    Text(verbatim: "\(MealFormat.quantity(quantity))×")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.blue)
                } else {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.blue)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Adds one serving to the meal"))
    }

    private func presetNutrients(_ preset: MealPresetStored) -> String {
        MealFormat.nutrients(
            carbs: preset.carbs?.decimalValue ?? 0,
            fat: preset.fat?.decimalValue ?? 0,
            protein: preset.protein?.decimalValue ?? 0,
            showFatAndProtein: showFatAndProtein
        )
    }

    private func openQuantityEditor(for preset: MealPresetStored) {
        if let item = state.mealItems.first(where: { $0.id == preset.objectID }) {
            quantityEditor = QuantityEditorTarget(item: item, preset: nil)
        } else {
            quantityEditor = QuantityEditorTarget(item: MealItem(preset: preset, quantity: 1), preset: preset)
        }
    }

    // MARK: Apply

    private var applyButton: some View {
        let carbs = MealFormat.number(state.mealTotals.carbs)
        let canApply = state.hasUnappliedMealChanges
        return Button {
            state.applyMeal()
            dismiss()
        } label: {
            Text(canApply ? "Apply to Treatment (\(carbs) g)" : "Applied to Treatment")
                .font(.headline)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .disabled(!canApply)
        .listRowBackground(canApply ? Color(.systemBlue) : Color(.systemGray3))
        .shadow(radius: 3)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Quantity editor

/// Popup to set the amount of one meal item: quick fraction buttons, or a free amount
/// (in the portion's unit, e.g. grams, or in portions when the preset has no size).
struct MealQuantityEditor: View {
    let item: MealItem
    /// `false` when the preset is not part of the meal yet.
    let isInMeal: Bool
    let displayFatAndProtein: Bool
    /// Called with the new number of portions; zero removes the item.
    let onCommit: (Decimal) -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    @State private var quantity: Decimal
    @State private var amount: Decimal

    init(
        item: MealItem,
        isInMeal: Bool,
        displayFatAndProtein: Bool,
        onCommit: @escaping (Decimal) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.item = item
        self.isInMeal = isInMeal
        self.displayFatAndProtein = displayFatAndProtein
        self.onCommit = onCommit
        self.onCancel = onCancel
        _quantity = State(initialValue: item.quantity)
        _amount = State(initialValue: item.amount ?? 0)
    }

    private var amountFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumIntegerDigits = 4
        formatter.maximumFractionDigits = item.portionAmount == nil ? 2 : 1
        return formatter
    }

    private var hasPortionSize: Bool { item.portionAmount != nil }

    private var amountBinding: Binding<Decimal> {
        if let portionAmount = item.portionAmount {
            return Binding(
                get: { amount },
                set: { newValue in
                    amount = newValue
                    quantity = newValue / portionAmount
                }
            )
        }
        return $quantity
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(MealFormat.quickQuantities, id: \.self) { value in
                            Button {
                                onCommit(value)
                            } label: {
                                Text(verbatim: "\(MealFormat.quantity(value))×")
                                    .font(.body.monospacedDigit().weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.bordered)
                            .tint(value == item.quantity && isInMeal ? Color.blue : Color.gray)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Quick Choice")
                } footer: {
                    Text("Portions of \(MealFormat.portionLabel(amount: item.portionAmount, unit: item.portionUnit))")
                }
                .listRowBackground(Color.chart)

                Section {
                    HStack {
                        Text(hasPortionSize ? "Amount" : "Portions").fontWeight(.semibold)
                        Spacer()
                        TextFieldWithToolBar(
                            text: amountBinding,
                            placeholder: "0",
                            keyboardType: .decimalPad,
                            numberFormatter: amountFormatter,
                            unitsText: hasPortionSize ? item.portionUnit.symbol : "×"
                        )
                    }
                    if hasPortionSize {
                        Text(verbatim: "= \(MealFormat.quantity(quantity))× \(MealFormat.portionLabel(amount: item.portionAmount, unit: item.portionUnit))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Result")
                        Spacer()
                        Text(MealFormat.nutrients(
                            carbs: item.carbs * quantity,
                            fat: item.fat * quantity,
                            protein: item.protein * quantity,
                            showFatAndProtein: displayFatAndProtein
                        ))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Enter Amount")
                }
                .listRowBackground(Color.chart)

                if isInMeal {
                    Section {
                        Button("Remove from Meal", role: .destructive) {
                            onCommit(0)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .listRowBackground(Color.chart)
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(item.dish)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onCommit(quantity) }
                        .disabled(!isInMeal && quantity <= 0)
                }
            }
        }
    }
}
