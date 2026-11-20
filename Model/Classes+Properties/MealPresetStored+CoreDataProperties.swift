import CoreData
import Foundation

public extension MealPresetStored {
    @nonobjc class func fetchRequest() -> NSFetchRequest<MealPresetStored> {
        NSFetchRequest<MealPresetStored>(entityName: "MealPresetStored")
    }

    @NSManaged var carbs: NSDecimalNumber?
    @NSManaged var dish: String?
    @NSManaged var fat: NSDecimalNumber?
    @NSManaged var protein: NSDecimalNumber?
    /// Size of one portion, e.g. `100` (with `portionUnit` "g"). `nil` means "1 portion" without a size.
    @NSManaged var portionAmount: NSDecimalNumber?
    /// Unit of `portionAmount`, one of `MealPortionUnit`'s raw values.
    @NSManaged var portionUnit: String?
}

extension MealPresetStored: Identifiable {}
