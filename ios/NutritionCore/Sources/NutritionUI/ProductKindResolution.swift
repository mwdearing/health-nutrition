import NutritionDomain

/// The one rule for what kind of product an entry or favorite is (#416, #364). A stored product's kind is its
/// snapshot's; an entry or favorite with no snapshot takes its stored category, so a typed supplement is a
/// supplement and a typed food is food.
public enum ProductKindResolution {
    /// The category a typed supplement is stored under.
    public static let supplementCategory = "supplement"

    /// The kind that totals and logged-day counts use for an entry: a snapshot's own kind, food when there is
    /// none. A typed entry therefore stays in food totals and counts as logged, as it always has (#364, #416).
    public static func totalsKind(snapshotKind: ProductKind?) -> ProductKind { snapshotKind ?? .food }

    /// The snapshot's own kind when it can be read; otherwise the entry's category decides, whether there is no
    /// snapshot or its kind cannot be read, so a supplement is never shown as food on a failed read (#775).
    public static func kind(snapshotID: String?, snapshotKind: (String) -> ProductKind?, category: String) -> ProductKind {
        let byCategory: ProductKind = category == supplementCategory ? .supplement : .food
        guard let snapshotID else { return byCategory }
        return snapshotKind(snapshotID) ?? byCategory
    }
}
