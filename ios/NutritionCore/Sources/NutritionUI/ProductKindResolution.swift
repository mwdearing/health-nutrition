import NutritionDomain

/// The one rule for what kind of product an entry or favorite is (#416, #364). A stored product's kind is its
/// snapshot's; an entry or favorite with no snapshot takes its stored category, so a typed supplement is a
/// supplement and a typed food is food.
public enum ProductKindResolution {
    /// The category a typed supplement is stored under.
    public static let supplementCategory = "supplement"

    /// `snapshotID` nil means no product snapshot: the category decides. A snapshot whose kind cannot be read is food.
    public static func kind(snapshotID: String?, snapshotKind: (String) -> ProductKind?, category: String) -> ProductKind {
        guard let snapshotID else { return category == supplementCategory ? .supplement : .food }
        return snapshotKind(snapshotID) ?? .food
    }
}
