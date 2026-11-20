import CoreData
import Foundation
import Testing

@testable import Trio

// Tests for meal presets with portion sizes and fractional servings, written around the way the feature
// is used: saving presets like "Rice, 100 g, 28 g carbs", composing a meal from them (half a pizza,
// 150 g of rice, an apple), and applying it to the treatment — including reopening and correcting it.

// MARK: - Fixture

/// In-memory Core Data with a few presets as a user would have them.
@MainActor private final class MealFixture {
    let stack: CoreDataStack
    let context: NSManagedObjectContext

    init() async throws {
        stack = try await CoreDataStack.createForTests()
        context = stack.persistentContainer.viewContext
    }

    @discardableResult func preset(
        _ dish: String,
        carbs: Decimal,
        fat: Decimal = 0,
        protein: Decimal = 0,
        portion: (amount: Decimal?, unit: String?)? = nil
    ) throws -> MealPresetStored {
        let preset = MealPresetStored(context: context)
        preset.dish = dish
        preset.carbs = carbs as NSDecimalNumber
        preset.fat = fat as NSDecimalNumber
        preset.protein = protein as NSDecimalNumber
        preset.portionAmount = portion?.amount.map { $0 as NSDecimalNumber }
        preset.portionUnit = portion?.unit
        try context.save()
        return preset
    }

    /// A frozen pizza, saved before portion sizes existed: just "1 portion".
    func pizza() throws -> MealPresetStored {
        try preset("Pizza", carbs: 60, fat: 24, protein: 20)
    }

    /// Cooked rice per 100 g.
    func rice() throws -> MealPresetStored {
        try preset("Rice", carbs: 28, fat: 0, protein: 3, portion: (100, "g"))
    }

    /// One apple.
    func apple() throws -> MealPresetStored {
        try preset("Apple", carbs: 14, portion: (1, "piece"))
    }

    func presetCount() throws -> Int {
        let request: NSFetchRequest<MealPresetStored> = MealPresetStored.fetchRequest()
        return try context.count(for: request)
    }
}

private func makeState(fatAndProtein: Bool = false) -> Treatments.StateModel {
    let state = Treatments.StateModel()
    state.useFPUconversion = fatAndProtein
    return state
}

private func dec(_ string: String) -> Decimal {
    Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))!
}

// MARK: - Portion sizes on presets

@Suite("Meal presets: portion size of a saved preset", .serialized) @MainActor struct MealPresetPortionTests {
    @Test("A preset saved before portion sizes existed is shown as 1 portion") func legacyPresetIsOnePortion() async throws {
        let fixture = try await MealFixture()
        let pizza = try fixture.pizza()

        #expect(pizza.portionSize == nil)
        #expect(pizza.portionLabel == "1 portion")

        let item = MealItem(preset: pizza, quantity: 1)
        #expect(item.portionUnit == .portion)
        #expect(item.amount == nil, "Without a size there is no amount in grams to show")
    }

    @Test("Sized presets show their portion: grams, milliliters and pieces") func sizedPresetsShowPortion() async throws {
        let fixture = try await MealFixture()
        let rice = try fixture.rice()
        let milk = try fixture.preset("Milk", carbs: 12, portion: (250, "ml"))
        let crackers = try fixture.preset("Crackers", carbs: 10, portion: (2, "piece"))

        #expect(rice.portionSize?.amount == 100)
        #expect(rice.portionSize?.unit == .grams)
        #expect(rice.portionLabel == "100 g")
        #expect(milk.portionLabel == "250 ml")
        #expect(crackers.portionLabel == "2 pcs")
    }

    @Test(
        "Incomplete or unknown portion data falls back to 1 portion instead of showing nonsense",
        arguments: [
            ("", "g"), // size missing
            ("100", ""), // unit missing
            ("0", "g"), // size zero
            ("100", "portion"), // "portion" never has a size
            ("100", "cup") // unit this app version does not know
        ]
    ) func incompletePortionDataFallsBack(amount: String, unit: String) async throws {
        let fixture = try await MealFixture()
        let preset = try fixture.preset(
            "Soup",
            carbs: 20,
            portion: (amount.isEmpty ? nil : dec(amount), unit.isEmpty ? nil : unit)
        )

        #expect(preset.portionSize == nil)
        #expect(preset.portionLabel == "1 portion")
        #expect(MealItem(preset: preset, quantity: 2).amount == nil)
    }
}

// MARK: - Formatting

@Suite("Meal presets: how amounts and nutrients are shown") struct MealFormatTests {
    @Test(
        "Common servings are shown as fractions",
        arguments: [
            ("0.25", "¼"), ("0.5", "½"), ("0.75", "¾"), ("1", "1"),
            ("1.5", "1½"), ("2.25", "2¼"), ("3", "3"), ("0", "0")
        ]
    ) func commonServingsAsFractions(value: String, expected: String) {
        #expect(MealFormat.quantity(dec(value)) == expected)
    }

    @Test("Every quick-choice button shows a clean fraction, never a long decimal") func quickChoicesAreClean() {
        for value in MealFormat.quickQuantities {
            let label = MealFormat.quantity(value)
            #expect(!label.contains("."), "Quick choice \(value) is shown as \(label)")
            #expect(!label.contains(","), "Quick choice \(value) is shown as \(label)")
        }
        #expect(MealFormat.quickQuantities == MealFormat.quickQuantities.sorted(), "Quick choices are in increasing order")
        #expect(MealFormat.quickQuantities.contains(dec("0.5")))
        #expect(MealFormat.quickQuantities.contains(1))
    }

    @Test("A typed weight that is not a neat fraction is shown with at most two decimals") func oddQuantitiesAsDecimals() {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2

        // 150 g of a 90 g portion
        let quantity = Decimal(150) / Decimal(90)
        #expect(MealFormat.quantity(quantity) == formatter.string(from: dec("1.67") as NSNumber))
        #expect(MealFormat.quantity(dec("1.3")) == formatter.string(from: dec("1.3") as NSNumber))
    }

    @Test("Nutrients only mention fat and protein when they are in use, and skip zero values") func nutrientsText() {
        #expect(MealFormat.nutrients(carbs: 42, fat: 10, protein: 5, showFatAndProtein: false) == "42 g carbs")
        #expect(
            MealFormat.nutrients(carbs: 42, fat: 10, protein: 5, showFatAndProtein: true) ==
                "42 g carbs · 10 g fat · 5 g protein"
        )
        #expect(MealFormat.nutrients(carbs: 42, fat: 0, protein: 5, showFatAndProtein: true) == "42 g carbs · 5 g protein")
        #expect(MealFormat.nutrients(carbs: dec("12.5"), fat: 0, protein: 0, showFatAndProtein: false) == "12.5 g carbs")
    }

    @Test("Portion labels") func portionLabels() {
        #expect(MealFormat.portionLabel(amount: 100, unit: .grams) == "100 g")
        #expect(MealFormat.portionLabel(amount: dec("37.5"), unit: .grams) == "37.5 g")
        #expect(MealFormat.portionLabel(amount: nil, unit: .grams) == "1 portion")
        #expect(MealFormat.portionLabel(amount: 100, unit: .portion) == "1 portion", "A 'portion' unit never shows a size")
    }
}

// MARK: - Composing a meal

@Suite("Meal composer: putting a meal together", .serialized) @MainActor struct MealComposerTests {
    @Test("Tapping a preset adds a whole portion each time") func tappingAddsPortions() async throws {
        let fixture = try await MealFixture()
        let pizza = try fixture.pizza()
        let state = makeState()

        state.addPortion(of: pizza)
        #expect(state.mealQuantity(for: pizza.objectID) == 1)
        #expect(state.mealTotals.carbs == 60)

        state.addPortion(of: pizza)
        #expect(state.mealItems.count == 1, "The same preset is counted up, not listed twice")
        #expect(state.mealQuantity(for: pizza.objectID) == 2)
        #expect(state.mealTotals.carbs == 120)
    }

    @Test("Half a pizza chosen in the popup before it was in the meal") func halfPizzaFromQuickChoice() async throws {
        let fixture = try await MealFixture()
        let pizza = try fixture.pizza()
        let state = makeState()

        // The popup opened from the preset list passes the preset along, because it is not in the meal yet.
        state.setMealQuantity(dec("0.5"), for: pizza.objectID, preset: pizza)

        #expect(state.mealItems.count == 1)
        #expect(state.mealQuantity(for: pizza.objectID) == dec("0.5"))
        #expect(state.mealTotals.carbs == 30)
        #expect(MealFormat.quantity(state.mealItems[0].quantity) == "½")
    }

    @Test("Typing the eaten weight: 150 g of rice is 1½ portions of 100 g") func typedWeight() async throws {
        let fixture = try await MealFixture()
        let rice = try fixture.rice()
        let state = makeState()
        state.addPortion(of: rice)

        let item = try #require(state.mealItems.first)
        state.setMealQuantity(item.quantity(forAmount: 150), for: item.id)

        let updated = try #require(state.mealItems.first)
        #expect(updated.quantity == dec("1.5"))
        #expect(updated.amount == 150, "The row shows the eaten weight")
        #expect(updated.totalCarbs == 42)
        #expect(state.mealTotals.carbs == 42)
    }

    @Test("For a preset without size, the typed amount is a number of portions") func typedPortionsWithoutSize() async throws {
        let fixture = try await MealFixture()
        let pizza = try fixture.pizza()
        let item = MealItem(preset: pizza, quantity: 1)

        #expect(item.quantity(forAmount: dec("0.75")) == dec("0.75"))
        #expect(item.quantity(forAmount: 2) == 2)
    }

    @Test("A typed weight that is not a round number gives totals in whole grams") func oddWeightRoundsTotals() async throws {
        let fixture = try await MealFixture()
        let pasta = try fixture.preset("Pasta", carbs: 75, portion: (100, "g"))
        let state = makeState()
        let item = MealItem(preset: pasta, quantity: 1)

        // 33 g of pasta = 24.75 g carbs
        state.setMealQuantity(item.quantity(forAmount: 33), for: pasta.objectID, preset: pasta)

        #expect(state.mealItems[0].totalCarbs == dec("24.75"))
        #expect(state.mealTotals.carbs == 25)
    }

    @Test("Half of a 25 g portion rounds to 13 g, like the carbs field would") func halfPortionRounding() async throws {
        let fixture = try await MealFixture()
        let bread = try fixture.preset("Bread", carbs: 25, portion: (1, "piece"))
        let state = makeState()

        state.setMealQuantity(dec("0.5"), for: bread.objectID, preset: bread)

        #expect(state.mealTotals.carbs == 13)
    }

    @Test("A mixed plate: 150 g rice, half a pizza and an apple") func mixedPlate() async throws {
        let fixture = try await MealFixture()
        let rice = try fixture.rice()
        let pizza = try fixture.pizza()
        let apple = try fixture.apple()
        let state = makeState()

        state.addPortion(of: rice)
        state.setMealQuantity(dec("1.5"), for: rice.objectID)
        state.setMealQuantity(dec("0.5"), for: pizza.objectID, preset: pizza)
        state.addPortion(of: apple)

        #expect(state.mealItems.map(\.dish) == ["Rice", "Pizza", "Apple"], "Items stay in the order they were added")
        #expect(state.mealTotals.carbs == 86) // 42 (rice) + 30 (half pizza) + 14 (apple)
        #expect(state.mealTotals.fat == 0, "Fat and protein are not counted while their entry is off")
        #expect(state.mealTotals.protein == 0)
    }

    @Test("Fat and protein are added up when fat/protein entry is on") func fatAndProteinTotals() async throws {
        let fixture = try await MealFixture()
        let rice = try fixture.rice()
        let pizza = try fixture.pizza()
        let state = makeState(fatAndProtein: true)

        state.setMealQuantity(dec("1.5"), for: rice.objectID, preset: rice)
        state.setMealQuantity(dec("0.5"), for: pizza.objectID, preset: pizza)

        #expect(state.mealTotals == MealTotals(carbs: 72, fat: 12, protein: 15)) // protein: 4.5 + 10 = 14.5 → 15
    }

    @Test(
        "+ goes up to the next whole portion",
        arguments: [("0.5", "1"), ("1", "2"), ("1.5", "2"), ("2.25", "3")]
    ) func plusRoundsUp(from: String, to: String) async throws {
        let fixture = try await MealFixture()
        let pizza = try fixture.pizza()
        let state = makeState()
        state.setMealQuantity(dec(from), for: pizza.objectID, preset: pizza)

        state.addPortion(to: pizza.objectID)

        #expect(state.mealQuantity(for: pizza.objectID) == dec(to))
    }

    @Test(
        "− goes down to the previous whole portion",
        arguments: [("3", "2"), ("2", "1"), ("1.5", "1"), ("2.25", "2")]
    ) func minusRoundsDown(from: String, to: String) async throws {
        let fixture = try await MealFixture()
        let pizza = try fixture.pizza()
        let state = makeState()
        state.setMealQuantity(dec(from), for: pizza.objectID, preset: pizza)

        state.removePortion(of: pizza.objectID)

        #expect(state.mealQuantity(for: pizza.objectID) == dec(to))
    }

    @Test("− on the last (part of a) portion takes the item off the plate", arguments: ["1", "0.5", "0.25"])
    func minusRemovesLastPortion(from: String) async throws {
        let fixture = try await MealFixture()
        let pizza = try fixture.pizza()
        let apple = try fixture.apple()
        let state = makeState()
        state.setMealQuantity(dec(from), for: pizza.objectID, preset: pizza)
        state.addPortion(of: apple)

        state.removePortion(of: pizza.objectID)

        #expect(state.mealItems.map(\.dish) == ["Apple"])
        #expect(state.mealQuantity(for: pizza.objectID) == 0)
    }

    @Test("Entering 0 or clearing the amount in the popup removes the item") func zeroRemoves() async throws {
        let fixture = try await MealFixture()
        let rice = try fixture.rice()
        let state = makeState()
        state.addPortion(of: rice)

        state.setMealQuantity(0, for: rice.objectID)

        #expect(state.mealItems.isEmpty)
        #expect(state.mealTotals == .zero)
    }

    @Test("Swiping one item away keeps the rest of the meal") func removeSingleItem() async throws {
        let fixture = try await MealFixture()
        let rice = try fixture.rice()
        let pizza = try fixture.pizza()
        let state = makeState()
        state.addPortion(of: rice)
        state.addPortion(of: pizza)

        state.removeMealItem(rice.objectID)

        #expect(state.mealItems.map(\.dish) == ["Pizza"])
        #expect(state.mealTotals.carbs == 60)
    }

    @Test("Clearing the meal removes everything") func clearMeal() async throws {
        let fixture = try await MealFixture()
        let state = makeState()
        state.addPortion(of: try fixture.rice())
        state.addPortion(of: try fixture.pizza())

        state.clearMeal()

        #expect(state.mealItems.isEmpty)
        #expect(state.mealTotals == .zero)
    }

    @Test("Changing the amount of something that is not on the plate does nothing") func unknownItemIsIgnored() async throws {
        let fixture = try await MealFixture()
        let rice = try fixture.rice()
        let pizza = try fixture.pizza()
        let state = makeState()
        state.addPortion(of: rice)

        state.setMealQuantity(2, for: pizza.objectID)
        state.addPortion(to: pizza.objectID)
        state.removePortion(of: pizza.objectID)

        #expect(state.mealItems.map(\.dish) == ["Rice"])
        #expect(state.mealQuantity(for: rice.objectID) == 1)
    }

    @Test("Two presets with the same name are separate items") func sameNameDifferentPresets() async throws {
        let fixture = try await MealFixture()
        let small = try fixture.preset("Pizza", carbs: 40)
        let large = try fixture.preset("Pizza", carbs: 80)
        let state = makeState()

        state.addPortion(of: small)
        state.addPortion(of: large)
        state.removePortion(of: small.objectID)

        #expect(state.mealItems.count == 1)
        #expect(state.mealQuantity(for: large.objectID) == 1)
        #expect(state.mealTotals.carbs == 80)
    }

    @Test("Editing a preset that is on the plate updates its nutrients but keeps the amount") func editPresetInMeal() async throws {
        let fixture = try await MealFixture()
        let rice = try fixture.rice()
        let state = makeState()
        state.setMealQuantity(dec("1.5"), for: rice.objectID, preset: rice)

        // The user corrects the label value: 30 g carbs per 100 g
        rice.carbs = 30
        try fixture.context.save()
        state.refreshMealItem(from: rice)

        #expect(state.mealQuantity(for: rice.objectID) == dec("1.5"))
        #expect(state.mealTotals.carbs == 45)
    }

    @Test("Editing a preset that is not on the plate leaves the meal alone") func editPresetNotInMeal() async throws {
        let fixture = try await MealFixture()
        let rice = try fixture.rice()
        let pizza = try fixture.pizza()
        let state = makeState()
        state.addPortion(of: rice)

        pizza.carbs = 70
        state.refreshMealItem(from: pizza)

        #expect(state.mealItems.map(\.dish) == ["Rice"])
        #expect(state.mealTotals.carbs == 28)
    }

    @Test("Deleting a preset removes it from the list but not from the meal being eaten") func deletePresetKeepsMeal() async throws {
        let fixture = try await MealFixture()
        let pizza = try fixture.pizza()
        _ = try fixture.rice()
        let state = makeState()
        state.setMealQuantity(dec("0.5"), for: pizza.objectID, preset: pizza)

        state.deletePreset(pizza)

        #expect(try fixture.presetCount() == 1, "Only the rice preset is left")
        #expect(state.mealItems.map(\.dish) == ["Pizza"])
        #expect(state.mealTotals.carbs == 30)
    }
}

// MARK: - Applying to the treatment

@Suite("Meal composer: applying the meal to the treatment", .serialized) @MainActor struct MealApplyTests {
    @Test("Nothing to apply before a meal is put together") func initiallyNothingToApply() {
        let state = makeState()
        #expect(!state.hasUnappliedMealChanges)
        #expect(state.appliedMealTotals == .zero)
    }

    @Test("Applying fills the carbs of the treatment") func applyFillsCarbs() async throws {
        let fixture = try await MealFixture()
        let rice = try fixture.rice()
        let state = makeState()
        state.setMealQuantity(dec("1.5"), for: rice.objectID, preset: rice)
        #expect(state.hasUnappliedMealChanges)

        state.applyMeal()

        #expect(state.carbs == 42)
        #expect(!state.hasUnappliedMealChanges)
    }

    @Test("Carbs typed by hand are kept and the meal is added on top") func keepsManualCarbs() async throws {
        let fixture = try await MealFixture()
        let state = makeState()
        state.carbs = 10 // e.g. a drink entered by hand
        state.addPortion(of: try fixture.apple())

        state.applyMeal()

        #expect(state.carbs == 24)
    }

    @Test("Reopening and finishing the whole pizza only adds the second half") func reapplyAddsDifference() async throws {
        let fixture = try await MealFixture()
        let pizza = try fixture.pizza()
        let state = makeState()
        state.setMealQuantity(dec("0.5"), for: pizza.objectID, preset: pizza)
        state.applyMeal()
        #expect(state.carbs == 30)

        state.setMealQuantity(1, for: pizza.objectID)
        #expect(state.hasUnappliedMealChanges, "The treatment screen warns that the change is not applied yet")
        state.applyMeal()

        #expect(state.carbs == 60, "Not 90: the first half was already counted")
    }

    @Test("Going from 1 to ½ and back to 1 portion is not reported as an unapplied change") func backToAppliedAmount() async throws {
        let fixture = try await MealFixture()
        let pizza = try fixture.pizza()
        let rice = try fixture.rice()
        let state = makeState()
        state.setMealQuantity(1, for: pizza.objectID, preset: pizza) // quick choice "1×"
        state.setMealQuantity(rice.portionAmount!.decimalValue / 100, for: rice.objectID, preset: rice) // typed "100 g"
        state.applyMeal()

        state.setMealQuantity(dec("0.5"), for: pizza.objectID)
        state.addPortion(to: pizza.objectID) // "+" rounds ½ up to 1 again
        state.setMealQuantity(dec("1.50"), for: rice.objectID)
        state.setMealQuantity(MealItem(preset: rice, quantity: 1).quantity(forAmount: 100), for: rice.objectID)

        #expect(state.mealTotals == state.appliedMealTotals)
        #expect(!state.hasUnappliedMealChanges)
    }

    @Test("Applying again without changes does not count the meal twice") func applyIsIdempotent() async throws {
        let fixture = try await MealFixture()
        let state = makeState()
        state.addPortion(of: try fixture.pizza())

        state.applyMeal()
        state.applyMeal()

        #expect(state.carbs == 60)
    }

    @Test("Taking something off the plate after applying lowers the carbs again") func removeAfterApply() async throws {
        let fixture = try await MealFixture()
        let rice = try fixture.rice()
        let apple = try fixture.apple()
        let state = makeState()
        state.addPortion(of: rice)
        state.addPortion(of: apple)
        state.applyMeal()
        #expect(state.carbs == 42)

        state.removeMealItem(apple.objectID)
        state.applyMeal()

        #expect(state.carbs == 28)
    }

    @Test("Clearing an applied meal brings the carbs back to what was typed by hand") func clearAfterApply() async throws {
        let fixture = try await MealFixture()
        let state = makeState()
        state.carbs = 15
        state.addPortion(of: try fixture.pizza())
        state.applyMeal()
        #expect(state.carbs == 75)

        state.clearMeal()
        #expect(state.hasUnappliedMealChanges)
        state.applyMeal()

        #expect(state.carbs == 15)
        #expect(state.appliedMealTotals == .zero)
    }

    @Test("Carbs lowered by hand never go negative when the meal is taken off") func neverNegative() async throws {
        let fixture = try await MealFixture()
        let state = makeState()
        state.addPortion(of: try fixture.pizza())
        state.applyMeal()

        state.carbs = 20 // the user overrode the field by hand
        state.clearMeal()
        state.applyMeal()

        #expect(state.carbs == 0)
    }

    @Test("A manual change of the carbs field after applying is kept on the next apply") func manualEditAfterApply() async throws {
        let fixture = try await MealFixture()
        let pizza = try fixture.pizza()
        let state = makeState()
        state.addPortion(of: pizza)
        state.applyMeal()

        state.carbs += 5 // a sauce, typed by hand
        state.setMealQuantity(dec("0.5"), for: pizza.objectID)
        state.applyMeal()

        #expect(state.carbs == 35)
    }

    @Test("Fat and protein are applied too when their entry is on") func appliesFatAndProtein() async throws {
        let fixture = try await MealFixture()
        let pizza = try fixture.pizza()
        let state = makeState(fatAndProtein: true)
        state.fat = 2
        state.setMealQuantity(dec("0.5"), for: pizza.objectID, preset: pizza)

        state.applyMeal()

        #expect(state.carbs == 30)
        #expect(state.fat == 14)
        #expect(state.protein == 10)
    }

    @Test("Fat and protein of presets are not applied while their entry is off") func skipsFatAndProteinWhenOff() async throws {
        let fixture = try await MealFixture()
        let state = makeState(fatAndProtein: false)
        state.addPortion(of: try fixture.pizza())

        state.applyMeal()

        #expect(state.carbs == 60)
        #expect(state.fat == 0)
        #expect(state.protein == 0)
    }
}

// MARK: - Creating and editing presets

@Suite("Meal presets: creating and editing a preset", .serialized) @MainActor struct MealPresetDraftTests {
    @Test("A new preset starts as 'per 100 g' and needs a name and carbs") func newPresetDefaults() {
        var draft = MealPresetDraft.new
        #expect(draft.portionUnit == .grams)
        #expect(draft.portionAmount == 100)
        #expect(!draft.isValid(includeFatAndProtein: false))

        draft.dish = "Rice"
        #expect(!draft.isValid(includeFatAndProtein: false), "No nutrients yet")

        draft.carbs = 28
        #expect(draft.isValid(includeFatAndProtein: false))
    }

    @Test("A name of only spaces is not accepted") func blankNameInvalid() {
        var draft = MealPresetDraft.new
        draft.dish = "   "
        draft.carbs = 20
        #expect(!draft.isValid(includeFatAndProtein: false))
    }

    @Test("A size in g/ml/pieces must be filled in, '1 portion' needs none") func portionSizeRequired() {
        var draft = MealPresetDraft.new
        draft.dish = "Soup"
        draft.carbs = 20

        draft.portionAmount = 0
        #expect(!draft.isValid(includeFatAndProtein: false))

        draft.portionUnit = .portion
        #expect(draft.isValid(includeFatAndProtein: false))
    }

    @Test("A preset with only fat/protein can only be saved when those are shown") func fatOnlyPreset() {
        var draft = MealPresetDraft.new
        draft.dish = "Cheese"
        draft.portionAmount = 30
        draft.fat = 9
        draft.protein = 7

        #expect(draft.isValid(includeFatAndProtein: true))
        #expect(!draft.isValid(includeFatAndProtein: false), "The user cannot see fat/protein, so it would save as 0 g carbs")
    }

    @Test("Saving 'Rice, 100 g, 28 g carbs' stores the portion and trims the name") func saveSizedPreset() async throws {
        let fixture = try await MealFixture()
        var draft = MealPresetDraft.new
        draft.dish = "  Rice "
        draft.carbs = 28
        draft.protein = 3

        let preset = MealPresetStored(context: fixture.context)
        draft.write(to: preset, includeFatAndProtein: true)
        try fixture.context.save()

        #expect(preset.dish == "Rice")
        #expect(preset.portionLabel == "100 g")
        #expect(preset.carbs?.decimalValue == 28)
        #expect(preset.protein?.decimalValue == 3)
        #expect(MealPresetDraft(preset: preset) == MealPresetDraft(
            dish: "Rice", portionUnit: .grams, portionAmount: 100, carbs: 28, fat: 0, protein: 3
        ))
    }

    @Test("Opening a preset saved before portion sizes existed keeps it as 1 portion") func editLegacyPreset() async throws {
        let fixture = try await MealFixture()
        let pizza = try fixture.pizza()

        let draft = MealPresetDraft(preset: pizza)
        #expect(draft.portionUnit == .portion)
        #expect(draft.isValid(includeFatAndProtein: true), "Can be saved without adding a size")

        draft.write(to: pizza, includeFatAndProtein: true)
        #expect(pizza.portionAmount == nil)
        #expect(pizza.portionUnit == nil)
        #expect(pizza.portionLabel == "1 portion")
    }

    @Test("Adding a size to an old preset") func addSizeToLegacyPreset() async throws {
        let fixture = try await MealFixture()
        let pizza = try fixture.pizza()

        var draft = MealPresetDraft(preset: pizza)
        draft.portionUnit = .grams
        draft.portionAmount = 350
        draft.write(to: pizza, includeFatAndProtein: true)
        try fixture.context.save()

        #expect(pizza.portionLabel == "350 g")
        #expect(MealItem(preset: pizza, quantity: dec("0.5")).amount == 175)
    }

    @Test("Switching a preset back to '1 portion' removes the stored size") func removeSize() async throws {
        let fixture = try await MealFixture()
        let rice = try fixture.rice()

        var draft = MealPresetDraft(preset: rice)
        draft.portionUnit = .portion
        draft.write(to: rice, includeFatAndProtein: true)

        #expect(rice.portionAmount == nil)
        #expect(rice.portionUnit == nil)
        #expect(rice.portionSize == nil)
    }

    @Test("Editing while fat/protein entry is off keeps the stored fat and protein") func editKeepsHiddenFatAndProtein() async throws {
        let fixture = try await MealFixture()
        let pizza = try fixture.pizza()

        var draft = MealPresetDraft(preset: pizza)
        draft.carbs = 65
        draft.fat = 0 // not visible, must not be written
        draft.write(to: pizza, includeFatAndProtein: false)

        #expect(pizza.carbs?.decimalValue == 65)
        #expect(pizza.fat?.decimalValue == 24)
        #expect(pizza.protein?.decimalValue == 20)
    }

    @Test("Every unit survives a save and reopen", arguments: [MealPortionUnit.grams, .milliliters, .pieces])
    func unitRoundTrip(unit: MealPortionUnit) async throws {
        let fixture = try await MealFixture()
        let draft = MealPresetDraft(dish: "Item", portionUnit: unit, portionAmount: 2, carbs: 10, fat: 0, protein: 0)
        let preset = MealPresetStored(context: fixture.context)

        draft.write(to: preset, includeFatAndProtein: true)
        try fixture.context.save()

        #expect(MealPresetDraft(preset: preset) == draft)
        #expect(preset.portionSize?.unit == unit)
    }
}

// MARK: - Switching builds (TestFlight)

/// Installing this build, going back to the main build and returning must not break the database.
/// The main build's model is this model without the two portion fields, which is exactly what this branch adds.
@Suite("Database: switching between this build and the main build", .serialized) @MainActor
struct MealPresetStoreCompatibilityTests {
    /// A copy of the app's model. Entity classes are set to NSManagedObject so this copy can be loaded next to the
    /// app's own model in the test process; class names are not part of the version hashes Core Data migrates on.
    private static func model(isMainBuild: Bool) -> NSManagedObjectModel {
        let model = CoreDataStack.managedObjectModel.copy() as! NSManagedObjectModel
        for entity in model.entities {
            entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        }
        if isMainBuild, let preset = model.entitiesByName["MealPresetStored"] {
            preset.properties = preset.properties.filter { !["portionAmount", "portionUnit"].contains($0.name) }
        }
        return model
    }

    /// Opens the store the way the app does (lightweight migration inferred automatically, history tracking on).
    private func open(_ url: URL, with model: NSManagedObjectModel) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "TrioCoreDataPersistentContainer", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        return container
    }

    private func close(_ container: NSPersistentContainer) throws {
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }

    private func insertPreset(
        _ dish: String,
        carbs: Decimal,
        portion: (Decimal, String)? = nil,
        into context: NSManagedObjectContext
    ) {
        let preset = NSEntityDescription.insertNewObject(forEntityName: "MealPresetStored", into: context)
        preset.setValue(dish, forKey: "dish")
        preset.setValue(carbs as NSDecimalNumber, forKey: "carbs")
        if let portion {
            preset.setValue(portion.0 as NSDecimalNumber, forKey: "portionAmount")
            preset.setValue(portion.1, forKey: "portionUnit")
        }
    }

    private func presets(in context: NSManagedObjectContext) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "MealPresetStored")
        request.sortDescriptors = [NSSortDescriptor(key: "dish", ascending: true)]
        return try context.fetch(request)
    }

    @Test("The test models match the app's model") func modelsMatchApp() {
        #expect(Self.model(isMainBuild: false).entityVersionHashesByName == CoreDataStack.managedObjectModel.entityVersionHashesByName)
        #expect(
            Self.model(isMainBuild: true).entitiesByName["MealPresetStored"]?.attributesByName.keys.sorted() ==
                ["carbs", "dish", "fat", "protein"],
            "The main build's preset has only these fields"
        )
    }

    @Test("Going back to the main build and returning keeps presets and opens without errors")
    func downgradeAndUpgrade() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("TrioCoreDataPersistentContainer.sqlite")

        // 1. This build: presets with and without a portion size.
        let thisBuild = try open(url, with: Self.model(isMainBuild: false))
        insertPreset("Rice", carbs: 28, portion: (100, "g"), into: thisBuild.viewContext)
        insertPreset("Pizza", carbs: 60, into: thisBuild.viewContext)
        try thisBuild.viewContext.save()
        try close(thisBuild)

        // 2. Back to the main build: the store opens, presets and their carbs are intact.
        let mainBuild = try open(url, with: Self.model(isMainBuild: true))
        let onMain = try presets(in: mainBuild.viewContext)
        #expect(onMain.map { $0.value(forKey: "dish") as? String } == ["Pizza", "Rice"])
        #expect(onMain.map { ($0.value(forKey: "carbs") as? NSDecimalNumber)?.decimalValue } == [60, 28])
        // A preset added while on the main build
        insertPreset("Soup", carbs: 20, into: mainBuild.viewContext)
        try mainBuild.viewContext.save()
        try close(mainBuild)

        // 3. This build again: opens without errors and has all presets. Portion sizes saved before the downgrade are
        //    gone (the main build cannot keep fields it does not know), so those presets show as "1 portion".
        let backAgain = try open(url, with: Self.model(isMainBuild: false))
        let returned = try presets(in: backAgain.viewContext)
        #expect(returned.map { $0.value(forKey: "dish") as? String } == ["Pizza", "Rice", "Soup"])
        #expect(returned.map { ($0.value(forKey: "carbs") as? NSDecimalNumber)?.decimalValue } == [60, 28, 20])
        #expect(returned.allSatisfy { $0.value(forKey: "portionAmount") == nil && $0.value(forKey: "portionUnit") == nil })

        // Portion sizes can be set again after returning.
        returned[1].setValue(NSDecimalNumber(value: 100), forKey: "portionAmount")
        returned[1].setValue("g", forKey: "portionUnit")
        try backAgain.viewContext.save()
        try close(backAgain)
    }
}
