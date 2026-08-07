import Foundation
import SwiftUI

// MARK: - Carbs Input View

struct CarbsInputView: View {
    @Binding var navigationPath: NavigationPath

    // Needs to be Double due to .digitalCrownRotation() stride
    @State private var carbsAmount: Double = 0.0
    @State private var fatAmount: Double = 0.0
    @State private var proteinAmount: Double = 0.0

    @State private var showMealPresets = false

    private enum NutrientField: Hashable {
        case carbs, fat, protein
    }

    @FocusState private var focusedField: NutrientField? // Manage crown focus

    let state: WatchState
    let continueToBolus: Bool

    private var effectiveCarbsLimit: Double { Double(truncating: state.maxCarbs as NSNumber) }
    private var effectiveFatLimit: Double { Double(truncating: state.maxFat as NSNumber) }
    private var effectiveProteinLimit: Double { Double(truncating: state.maxProtein as NSNumber) }

    /// Whether any nutrient has been entered, i.e. there is something to log.
    private var hasInput: Bool {
        carbsAmount > 0 || fatAmount > 0 || proteinAmount > 0
    }

    private var isCarbsLimitReached: Bool {
        carbsAmount > 0 && carbsAmount >= effectiveCarbsLimit
    }

    var trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        let buttonLabel = continueToBolus ? String(localized: "Proceed", comment: "Button Label to Proceed to Bolus on Watch") :
            String(localized: "Log Carbs", comment: "Button Label to Log Carbs on Watch")

        ScrollView {
            VStack(spacing: 8) {
                if !state.mealPresets.isEmpty {
                    Button {
                        showMealPresets = true
                    } label: {
                        Label(
                            String(localized: "Meal Presets", comment: "Button to pick a predefined meal on Watch"),
                            systemImage: "list.bullet"
                        )
                        .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }

                nutrientStepper(
                    title: String(localized: "Carbohydrates", comment: "Carbs label on Watch"),
                    unitLabel: String(localized: "g", comment: "gram of carbs"),
                    value: $carbsAmount,
                    limit: effectiveCarbsLimit,
                    color: .orange,
                    field: .carbs
                )

                // Fat & protein are only offered when FPU conversion is enabled on the phone
                if state.displayFatAndProtein {
                    nutrientStepper(
                        title: String(localized: "Fat", comment: "Fat label on Watch"),
                        unitLabel: String(localized: "g", comment: "gram of fat"),
                        value: $fatAmount,
                        limit: effectiveFatLimit,
                        color: .yellow,
                        field: .fat
                    )

                    nutrientStepper(
                        title: String(localized: "Protein", comment: "Protein label on Watch"),
                        unitLabel: String(localized: "g", comment: "gram of protein"),
                        value: $proteinAmount,
                        limit: effectiveProteinLimit,
                        color: .red,
                        field: .protein
                    )
                }

                if isCarbsLimitReached {
                    Text("Carbs Limit Reached!")
                        .font(.footnote)
                        .foregroundColor(.loopRed)
                }

                Button(buttonLabel) {
                    let carbs = Int(min(carbsAmount, effectiveCarbsLimit))
                    let fat = Int(min(fatAmount, effectiveFatLimit))
                    let protein = Int(min(proteinAmount, effectiveProteinLimit))

                    if continueToBolus {
                        state.carbsAmount = carbs
                        state.fatAmount = fat
                        state.proteinAmount = protein
                        navigationPath.append(NavigationDestinations.bolusInput)
                    } else {
                        state.sendCarbsRequest(carbs, fat: fat, protein: protein)
                        navigationPath.append(NavigationDestinations.acknowledgmentPending)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(!hasInput || carbsAmount > effectiveCarbsLimit)
            }
            .padding(.vertical, 4)
        }
        .background(trioBackgroundColor)
        .onAppear {
            // Focus carbs by default so the Digital Crown adjusts it immediately
            focusedField = .carbs
        }
        .sheet(isPresented: $showMealPresets) {
            MealPresetPickerView(presets: state.mealPresets) { preset in
                applyPreset(preset)
                showMealPresets = false
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: "fork.knife")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .padding()
                    .background(Color.orange)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
        }
    }

    /// Adds a selected meal preset on top of the current values, clamped to the configured limits.
    private func applyPreset(_ preset: MealPresetWatch) {
        carbsAmount = min(effectiveCarbsLimit, carbsAmount + preset.carbs.rounded())
        if state.displayFatAndProtein {
            fatAmount = min(effectiveFatLimit, fatAmount + preset.fat.rounded())
            proteinAmount = min(effectiveProteinLimit, proteinAmount + preset.protein.rounded())
        }
    }

    /// A nutrient stepper with "-"/"+" buttons and Digital Crown support while focused.
    @ViewBuilder private func nutrientStepper(
        title: String,
        unitLabel: String,
        value: Binding<Double>,
        limit: Double,
        color: Color,
        field: NutrientField
    ) -> some View {
        VStack(spacing: 2) {
            HStack {
                Button(action: {
                    value.wrappedValue = value.wrappedValue < 5 ? 0 : value.wrappedValue - 5
                }) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .tint(color)
                }
                .buttonStyle(.borderless)
                .disabled(value.wrappedValue <= 0)

                Spacer()

                Text(String(format: "%.0f \(unitLabel)", value.wrappedValue))
                    .fontWeight(.bold)
                    .font(.system(.title3, design: .rounded))
                    .foregroundColor(value.wrappedValue > 0 && value.wrappedValue >= limit ? .loopRed : .primary)
                    .focusable(true)
                    .focused($focusedField, equals: field)
                    .digitalCrownRotation(
                        value,
                        from: 0,
                        through: limit,
                        by: 1,
                        sensitivity: .medium,
                        isContinuous: false,
                        isHapticFeedbackEnabled: true
                    )

                Spacer()

                Button(action: {
                    value.wrappedValue = min(limit, value.wrappedValue + 5)
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .tint(color)
                }
                .buttonStyle(.borderless)
                .disabled(value.wrappedValue >= limit)
            }
            .padding(.horizontal)

            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Meal Preset Picker

/// A simple list that lets the user pick one of the meal presets defined on the phone.
struct MealPresetPickerView: View {
    @Environment(\.dismiss) var dismiss
    let presets: [MealPresetWatch]
    var onSelect: (MealPresetWatch) -> Void

    var body: some View {
        NavigationView {
            List {
                if presets.isEmpty {
                    Text("No Meal Presets")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(presets) { preset in
                        Button(action: { onSelect(preset) }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.dish)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                Text(macroSummary(for: preset))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Meal Presets")
        }
    }

    private func macroSummary(for preset: MealPresetWatch) -> String {
        var parts: [String] = ["\(Int(preset.carbs)) \(String(localized: "g", comment: "gram of carbs")) C"]
        if preset.fat > 0 {
            parts.append("\(Int(preset.fat)) \(String(localized: "g", comment: "gram of fat")) F")
        }
        if preset.protein > 0 {
            parts.append("\(Int(preset.protein)) \(String(localized: "g", comment: "gram of protein")) P")
        }
        return parts.joined(separator: " · ")
    }
}
