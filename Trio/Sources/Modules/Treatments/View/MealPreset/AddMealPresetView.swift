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

    @State private var dish: String
    @State private var portionUnit: MealPortionUnit
    @State private var portionAmount: Decimal
    @State private var carbs: Decimal
    @State private var fat: Decimal
    @State private var protein: Decimal

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
        _dish = State(initialValue: preset?.dish ?? "")
        // New presets default to "per 100 g"; existing presets without a size stay "1 portion".
        _portionUnit = State(initialValue: preset == nil ? .grams : (preset?.portionSize?.unit ?? .portion))
        _portionAmount = State(initialValue: preset == nil ? 100 : (preset?.portionSize?.amount ?? 0))
        _carbs = State(initialValue: preset?.carbs?.decimalValue ?? 0)
        _fat = State(initialValue: preset?.fat?.decimalValue ?? 0)
        _protein = State(initialValue: preset?.protein?.decimalValue ?? 0)
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

    private var hasPortionSize: Bool { portionUnit != .portion }

    private var isFormValid: Bool {
        !dish.trimmingCharacters(in: .whitespaces).isEmpty
            && (carbs > 0 || protein > 0 || fat > 0)
            && (!hasPortionSize || portionAmount > 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextFieldWithToolBarString(
                        text: $dish,
                        placeholder: String(localized: "Name Of Dish"),
                        maxLength: 25
                    )
                } header: {
                    Text(isEditing ? "Preset" : "New Preset")
                }
                .listRowBackground(Color.chart)

                Section {
                    Picker("Unit", selection: $portionUnit) {
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
                                text: $portionAmount,
                                placeholder: "0",
                                keyboardType: .decimalPad,
                                numberFormatter: portionFormatter,
                                unitsText: portionUnit.symbol
                            )
                        }
                    }
                } header: {
                    Text("Portion")
                } footer: {
                    Text(
                        "The nutrients below are per portion of \(MealFormat.portionLabel(amount: hasPortionSize ? portionAmount : nil, unit: portionUnit)). When using the preset you can pick a fraction or enter the eaten amount."
                    )
                }
                .listRowBackground(Color.chart)

                Section {
                    nutrientField("Carbs", value: $carbs, color: .primary)
                    if displayFatAndProtein {
                        nutrientField("Fat", value: $fat, color: .orange)
                        nutrientField("Protein", value: $protein, color: .red)
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
        target.dish = dish.trimmingCharacters(in: .whitespaces)
        target.carbs = carbs as NSDecimalNumber
        if displayFatAndProtein {
            target.fat = fat as NSDecimalNumber
            target.protein = protein as NSDecimalNumber
        }
        if hasPortionSize {
            target.portionAmount = portionAmount as NSDecimalNumber
            target.portionUnit = portionUnit.rawValue
        } else {
            target.portionAmount = nil
            target.portionUnit = nil
        }

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
