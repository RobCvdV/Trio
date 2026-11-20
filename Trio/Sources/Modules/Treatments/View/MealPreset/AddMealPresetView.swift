import CoreData
import Foundation
import SwiftUI

/// Creates a new meal preset, or edits `preset` when given.
/// Carbs, fat and protein are entered per portion; the portion can have a size (e.g. 100 g) or just be "1 portion".
struct AddMealPresetView: View {
    let preset: MealPresetStored?
    let displayFatAndProtein: Bool
    var onSaved: (MealPresetStored) -> Void
    var onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.managedObjectContext) private var moc
    @Environment(AppState.self) var appState

    @State private var draft: MealPresetDraft

    init(
        preset: MealPresetStored?,
        displayFatAndProtein: Bool,
        onSaved: @escaping (MealPresetStored) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.preset = preset
        self.displayFatAndProtein = displayFatAndProtein
        self.onSaved = onSaved
        self.onCancel = onCancel
        _draft = State(initialValue: preset.map(MealPresetDraft.init(preset:)) ?? .new)
    }

    private var isEditing: Bool { preset != nil }

    private var mealFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumIntegerDigits = 3
        formatter.maximumFractionDigits = 1
        return formatter
    }

    private var portionFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumIntegerDigits = 4
        formatter.maximumFractionDigits = 1
        return formatter
    }

    private var hasPortionSize: Bool { draft.hasPortionSize }

    private var isFormValid: Bool { draft.isValid(includeFatAndProtein: displayFatAndProtein) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextFieldWithToolBarString(
                        text: $draft.dish,
                        placeholder: String(localized: "Name Of Dish"),
                        maxLength: 25
                    )
                } header: {
                    Text(isEditing ? "Preset" : "New Preset")
                }
                .listRowBackground(Color.chart)

                Section {
                    Picker("Unit", selection: $draft.portionUnit) {
                        ForEach(MealPortionUnit.allCases) { unit in
                            Text(unit.pickerLabel).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)

                    if hasPortionSize {
                        HStack {
                            Text("Portion Size").fontWeight(.semibold)
                            Spacer()
                            TextFieldWithToolBar(
                                text: $draft.portionAmount,
                                placeholder: "0",
                                keyboardType: .decimalPad,
                                numberFormatter: portionFormatter,
                                unitsText: draft.portionUnit.symbol
                            )
                        }
                    }
                } header: {
                    Text("Portion")
                } footer: {
                    Text(
                        "The nutrients below are per portion of \(MealFormat.portionLabel(amount: hasPortionSize ? draft.portionAmount : nil, unit: draft.portionUnit)). When using the preset you can pick a fraction or enter the eaten amount."
                    )
                }
                .listRowBackground(Color.chart)

                Section {
                    nutrientField("Carbs", value: $draft.carbs, color: .primary)
                    if displayFatAndProtein {
                        nutrientField("Fat", value: $draft.fat, color: .orange)
                        nutrientField("Protein", value: $draft.protein, color: .red)
                    }
                } header: {
                    Text("Per Portion")
                }
                .listRowBackground(Color.chart)

                saveButton
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(isEditing ? "Edit Meal Preset" : "Add Meal Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }

    private func nutrientField(_ title: LocalizedStringKey, value: Binding<Decimal>, color: Color) -> some View {
        HStack {
            Text(title)
                .fontWeight(color == .primary ? .semibold : .regular)
                .foregroundStyle(color)
            Spacer()
            TextFieldWithToolBar(
                text: value,
                placeholder: "0",
                keyboardType: .decimalPad,
                numberFormatter: mealFormatter,
                unitsText: String(localized: "g", comment: "Units for carbs")
            )
        }
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            Text("Save")
                .font(.headline)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .listRowBackground(isFormValid ? Color(.systemBlue) : Color(.systemGray))
        .shadow(radius: 3)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .disabled(!isFormValid)
    }

    private func save() {
        guard isFormValid else { return }
        let target = preset ?? MealPresetStored(context: moc)
        draft.write(to: target, includeFatAndProtein: displayFatAndProtein)

        do {
            if moc.hasChanges {
                try moc.save()
            }
            onSaved(target)
        } catch let error as NSError {
            debugPrint("\(DebuggingIdentifiers.failed) Failed to save Meal Preset with error: \(error.userInfo)")
        }
    }
}

/// The editable values of a meal preset, kept apart from Core Data so validation and saving are testable.
struct MealPresetDraft: Equatable {
    var dish: String
    var portionUnit: MealPortionUnit
    /// Size of one portion in `portionUnit`; ignored when the unit is `.portion`.
    var portionAmount: Decimal
    /// Nutrients per portion.
    var carbs: Decimal
    var fat: Decimal
    var protein: Decimal

    /// A new preset starts as "per 100 g".
    static let new = MealPresetDraft(dish: "", portionUnit: .grams, portionAmount: 100, carbs: 0, fat: 0, protein: 0)

    var hasPortionSize: Bool { portionUnit != .portion }

    var trimmedDish: String { dish.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A preset needs a name, some nutrients that are shown, and a size when the unit is not "portion".
    func isValid(includeFatAndProtein: Bool) -> Bool {
        let hasNutrients = carbs > 0 || (includeFatAndProtein && (fat > 0 || protein > 0))
        return !trimmedDish.isEmpty && hasNutrients && (!hasPortionSize || portionAmount > 0)
    }

    /// Writes the draft into `preset`. Fat and protein are only written when they are shown,
    /// so editing a preset while fat/protein entry is off keeps its stored values.
    func write(to preset: MealPresetStored, includeFatAndProtein: Bool) {
        preset.dish = trimmedDish
        preset.carbs = carbs as NSDecimalNumber
        if includeFatAndProtein {
            preset.fat = fat as NSDecimalNumber
            preset.protein = protein as NSDecimalNumber
        }
        if hasPortionSize {
            preset.portionAmount = portionAmount as NSDecimalNumber
            preset.portionUnit = portionUnit.rawValue
        } else {
            preset.portionAmount = nil
            preset.portionUnit = nil
        }
    }
}

extension MealPresetDraft {
    /// Starts from an existing preset; one without a size stays "1 portion".
    init(preset: MealPresetStored) {
        self.init(
            dish: preset.dish ?? "",
            portionUnit: preset.portionSize?.unit ?? .portion,
            portionAmount: preset.portionSize?.amount ?? 0,
            carbs: preset.carbs?.decimalValue ?? 0,
            fat: preset.fat?.decimalValue ?? 0,
            protein: preset.protein?.decimalValue ?? 0
        )
    }
}
