import NutritionDomain
import NutritionJournal
import NutritionProviders
import XCTest
@testable import NutritionUI

/// A Supplement Facts panel on a small bottle is printed in two columns, so one frame shows the left
/// column and the next shows the right one plus the other ingredients. These tests cover what happens
/// when a panel is read across two photos: the halves merge into one draft, a row the two photos read
/// differently waits for the user, and one photo behaves exactly as it did before.
///
/// The panels below are synthetic: they were written for these tests and name no real product or brand.
@MainActor
final class LabelCaptureMultiPhotoTests: XCTestCase {
    /// The left column of a synthetic Supplement Facts panel, with the serving size above it and one
    /// compound the panel prints under its own name.
    private var leftHalf: [String] {
        [
            "Supplement Facts",
            "Synthetic Rise Gummies, invented for tests",
            "Serving Size: 2 Gummies",
            "Amount per serving",
            "Calories 40",
            "Total Fat 1g 2%",
            "Sodium 180mg 8%",
            "Zinc 11mg",
        ]
    }

    /// The right column of the same panel: minerals the left frame did not hold, and the
    /// other-ingredients print, which states no amount at all.
    private var rightHalf: [String] {
        [
            "Calcium 120mg 6%",
            "Iron 8mg 4%",
            "Other Ingredients: Synthetic Pectin, Synthetic Colour",
        ]
    }

    /// The right column as a second photo of a panel that prints its zinc differently: 15 mg where the
    /// first photo read 11 mg.
    private var rightHalfWithOtherZinc: [String] {
        ["Calcium 120mg 6%", "Iron 8mg 4%", "Zinc 15mg"]
    }

    private func makeModel() -> LabelCaptureViewModel {
        LabelCaptureViewModel()
    }

    // MARK: Two photos of one panel

    /// Two halves of one panel become one draft: every row of each half is present exactly once, and
    /// each row remembers which photo read it.
    func testTwoPhotosOfOnePanelMergeIntoOneDraftWithEveryRowOnce() throws {
        let model = makeModel()
        model.load(lines: leftHalf)
        XCTAssertEqual(model.frameCount, 1)

        model.addPhoto(lines: rightHalf)

        XCTAssertEqual(model.frameCount, 2, "both photos contributed rows to this draft")
        XCTAssertEqual(model.photoHeader, "From 2 photos")

        // Every row the left half read is still there, exactly once, with its own value.
        XCTAssertEqual(model.rows.filter { $0.key == .calories }.count, 1)
        XCTAssertEqual(model.row(for: .calories)?.value, .known(Decimal(40), .kcal))
        XCTAssertEqual(model.row(for: .fat)?.value, .known(Decimal(1), .g))
        XCTAssertEqual(model.row(for: .sodium)?.value, .known(Decimal(180), .mg))
        // Every row the right half read is there too, and is attributed to the photo that read it.
        XCTAssertEqual(model.rows.filter { $0.key == .iron }.count, 1)
        XCTAssertEqual(model.row(for: .iron)?.value, .known(Decimal(8), .mg))
        XCTAssertEqual(model.row(for: .iron)?.frameIndex, 2)
        XCTAssertEqual(model.row(for: .calcium)?.value, .known(Decimal(120), .mg))
        XCTAssertEqual(model.row(for: .calcium)?.frameIndex, 2)
        XCTAssertEqual(model.row(for: .calories)?.frameIndex, 1)

        // The compound the panel prints under its own name merged by slug rather than becoming a second
        // row: it was in the left photo only, and the other-ingredients print states no amount.
        XCTAssertEqual(model.additionalRows.count, 1)
        XCTAssertEqual(model.additionalRows.filter { $0.key == "zinc" }.count, 1)
        XCTAssertEqual(model.additionalNutrient(for: "zinc")?.value, .known(Decimal(11), .mg))
        XCTAssertEqual(model.additionalNutrient(for: "zinc")?.frameIndex, 1)

        // A nutrient neither half stated stays unknown rather than becoming a zero, and the two photos
        // disagreed about nothing, so the draft is ready to be used.
        XCTAssertEqual(model.row(for: .potassium)?.value, .unknown)
        XCTAssertEqual(model.conflictCount, 0)
        XCTAssertTrue(model.canApply)

        let product = try XCTUnwrap(model.makeProduct())
        XCTAssertEqual(product.value(for: "energyKcal"), .known(Decimal(40), .kcal))
        XCTAssertEqual(product.value(for: "iron"), .known(Decimal(8), .mg))
        XCTAssertEqual(product.value(for: "calcium"), .known(Decimal(120), .mg))
        XCTAssertEqual(product.value(for: "zinc"), .known(Decimal(11), .mg))
        XCTAssertNil(product.nutrients["potassium"])
    }

    /// The serving size is printed once, above the columns, so it comes from the photo that read it and
    /// the other photo never replaces it — least of all once the user has stated one themselves.
    func testTheServingSizeFromTheFirstOfTwoPhotosSurvivesTheSecond() {
        let model = makeModel()
        model.load(lines: leftHalf)
        XCTAssertEqual(model.servingText, "2 Gummies")
        XCTAssertEqual(model.servingQuantity, Quantity(value: Decimal(2), unit: .gummy))

        model.addPhoto(lines: rightHalf)

        XCTAssertEqual(model.servingText, "2 Gummies")
        XCTAssertEqual(model.servingQuantity, Quantity(value: Decimal(2), unit: .gummy))
        XCTAssertFalse(model.servingIsMissing)

        // A second photo that does read a serving size does not take the one already on screen either:
        // the first photo had the whole panel in frame and this one did not.
        let other = makeModel()
        other.load(lines: leftHalf)
        other.addPhoto(lines: rightHalf + ["Serving Size: 4 Gummies"])
        XCTAssertEqual(other.servingQuantity, Quantity(value: Decimal(2), unit: .gummy))

        // And a serving the user has stated themselves is not overwritten at all.
        XCTAssertTrue(other.correctServingSize(text: "3 gummies"))
        XCTAssertTrue(other.isServingConfirmed)
        other.addPhoto(lines: rightHalf + ["Serving Size: 4 Gummies"])
        XCTAssertEqual(other.servingQuantity, Quantity(value: Decimal(3), unit: .gummy))
        XCTAssertTrue(other.isServingConfirmed)
    }

    // MARK: A row two photos read differently

    /// Zinc reads 11 mg in the first photo and 15 mg in the second. Nothing is chosen silently: both
    /// candidates are kept and Save stays blocked until the user says which one the label states.
    func testAConflictingValueInTheSecondPhotoBlocksSaveUntilItIsResolved() throws {
        let model = makeModel()
        model.load(lines: leftHalf)
        XCTAssertTrue(model.canApply, "one photo with nothing flagged is ready to use")

        model.addPhoto(lines: rightHalfWithOtherZinc)

        let zinc = try XCTUnwrap(model.additionalNutrient(for: "zinc"))
        XCTAssertEqual(zinc.value, .known(Decimal(11), .mg), "the value already on screen is kept")
        XCTAssertEqual(
            zinc.candidates.first?.value, .known(Decimal(15), .mg), "the other reading is kept too")
        XCTAssertEqual(zinc.candidates.first?.frameIndex, 2)
        XCTAssertTrue(zinc.hasConflict)
        XCTAssertEqual(zinc.conflictSummary, "Photo 2 reads 15 mg")
        XCTAssertEqual(model.conflictCount, 1)
        XCTAssertTrue(zinc.isPending)
        XCTAssertFalse(model.canApply, "a value two photos disagree about cannot be saved on either one")
        XCTAssertNil(model.makeProduct())
        XCTAssertTrue(
            (model.statusMessage ?? "").contains("another photo"),
            "the user is told a second photo read it differently: \(model.statusMessage ?? "")")

        // Confirming keeps the value on screen and answers the conflict.
        XCTAssertTrue(model.confirmAdditional(key: "zinc"))
        XCTAssertFalse(model.additionalNutrient(for: "zinc")?.hasConflict == true)
        XCTAssertEqual(model.additionalNutrient(for: "zinc")?.value, .known(Decimal(11), .mg))
        XCTAssertEqual(model.conflictCount, 0)
        XCTAssertTrue(model.canApply)

        // Taking the other photo's value resolves it the other way round.
        let other = makeModel()
        other.load(lines: leftHalf)
        other.addPhoto(lines: rightHalfWithOtherZinc)
        XCTAssertTrue(other.chooseConflict(additionalKey: "zinc", taking: 2))
        XCTAssertEqual(other.additionalNutrient(for: "zinc")?.value, .known(Decimal(15), .mg))
        XCTAssertEqual(other.additionalNutrient(for: "zinc")?.frameIndex, 2)
        XCTAssertEqual(other.additionalNutrient(for: "zinc")?.status, .corrected)
        XCTAssertTrue(other.canApply)

        // A row with only one value has nothing to choose, so asking for a photo it did not come from
        // changes nothing.
        XCTAssertFalse(other.chooseConflict(additionalKey: "zinc", taking: 3))
    }

    /// The same rule on a named nutrient row: both readings are kept, and a typed value resolves it.
    func testAConflictingNutrientRowKeepsBothValuesUntilItIsCorrected() {
        let model = makeModel()
        model.load(lines: ["Serving Size: 2 Gummies", "Calcium 120mg 6%"])
        model.addPhoto(lines: ["Calcium 130mg 6%"])

        XCTAssertEqual(model.row(for: .calcium)?.value, .known(Decimal(120), .mg))
        XCTAssertEqual(model.row(for: .calcium)?.candidates.first?.value, .known(Decimal(130), .mg))
        XCTAssertEqual(model.row(for: .calcium)?.candidates.first?.frameIndex, 2)
        XCTAssertFalse(model.canApply)

        XCTAssertTrue(model.correct(key: .calcium, text: "130 mg"))
        XCTAssertEqual(model.row(for: .calcium)?.value, .known(Decimal(130), .mg))
        XCTAssertFalse(model.row(for: .calcium)?.hasConflict == true)
        XCTAssertTrue(model.canApply)

        // Taking the other photo's reading resolves it without typing anything.
        let other = makeModel()
        other.load(lines: ["Serving Size: 2 Gummies", "Calcium 120mg 6%"])
        other.addPhoto(lines: ["Calcium 130mg 6%"])
        XCTAssertTrue(other.chooseConflict(key: .calcium, taking: 2))
        XCTAssertEqual(other.row(for: .calcium)?.value, .known(Decimal(130), .mg))
        XCTAssertEqual(other.row(for: .calcium)?.frameIndex, 2)
        XCTAssertTrue(other.canApply)
    }

    /// A flag the parser raised on the strength of one photo is answered when another photo reads the
    /// row the same way, which is the other half of what a second reading is worth.
    func testASecondPhotoThatAgreesAnswersTheFirstPhotosFlag() {
        let model = makeModel()
        model.load(lines: ["Serving Size: 2 Gummies", "Sodium 18O mg 8%"])
        XCTAssertTrue(model.row(for: .sodium)?.needsConfirmation == true)
        XCTAssertFalse(model.canApply)

        model.addPhoto(lines: ["Sodium 180mg 8%"])

        XCTAssertEqual(model.row(for: .sodium)?.value, .known(Decimal(180), .mg))
        XCTAssertEqual(model.row(for: .sodium)?.status, .read)
        // Nothing is left of the first photo's doubt: the reasons of the reading that stands are the
        // ones the row keeps, so the screen no longer asks about a letter O it can no longer explain.
        XCTAssertFalse(model.row(for: .sodium)?.isFlagged == true)
        XCTAssertTrue(model.canApply)
    }

    /// A doubt the second photo raises is as real as one the first raised, even when both read the same
    /// value: what stands is the reading that is kept, so the row is asked about.
    func testASecondPhotoThatReadsADoubtfullyBlocksSaveUntilItIsAnswered() {
        let model = makeModel()
        model.load(lines: ["Serving Size: 2 Gummies", "Sodium 180mg 8%"])
        XCTAssertTrue(model.canApply)

        model.addPhoto(lines: ["Sodium 18O mg 8%"])

        XCTAssertEqual(model.row(for: .sodium)?.value, .known(Decimal(180), .mg))
        XCTAssertTrue(model.row(for: .sodium)?.needsConfirmation == true)
        XCTAssertTrue(model.row(for: .sodium)?.isFlagged == true)
        XCTAssertFalse(model.canApply)

        model.confirm(.sodium)
        XCTAssertTrue(model.canApply)
    }

    /// A row the user has answered is not asked about again: their answer outranks what a later photo
    /// of the same panel reads, so a disagreement is dropped rather than put back in front of them.
    func testARowTheUserAnsweredIsNotTurnedBackIntoAConflictByAnotherPhoto() {
        let model = makeModel()
        model.load(lines: ["Serving Size: 2 Gummies", "Calcium 120mg 6%"])
        XCTAssertTrue(model.correct(key: .calcium, text: "125 mg"))

        model.addPhoto(lines: ["Calcium 130mg 6%"])

        XCTAssertEqual(model.row(for: .calcium)?.value, .known(Decimal(125), .mg))
        XCTAssertFalse(model.row(for: .calcium)?.hasConflict == true)
        XCTAssertTrue(model.conflictCount == 0)
        XCTAssertTrue(model.canApply)
    }

    // MARK: One photo behaves as it did

    /// One photo of the whole panel gives the same rows as reading that panel in two halves and merging
    /// them, and the screen says nothing about photos.
    func testOnePhotoIsUnchangedByTheMerge() throws {
        let one = makeModel()
        one.load(lines: leftHalf + rightHalf)

        XCTAssertEqual(one.frameCount, 1)
        XCTAssertNil(one.photoHeader, "one photo is just the panel, so the header says nothing")
        XCTAssertEqual(one.conflictCount, 0)
        XCTAssertTrue(one.canApply)
        XCTAssertEqual(one.row(for: .calories)?.value, .known(Decimal(40), .kcal))
        XCTAssertEqual(one.row(for: .iron)?.value, .known(Decimal(8), .mg))
        XCTAssertEqual(one.row(for: .iron)?.frameIndex, 1, "one photo is frame 1 throughout")
        XCTAssertEqual(one.additionalRows.count, 1)
        XCTAssertEqual(one.additionalNutrient(for: "zinc")?.value, .known(Decimal(11), .mg))
        XCTAssertEqual(one.row(for: .potassium)?.value, .unknown)

        // The same panel read in two halves says exactly the same thing.
        let two = makeModel()
        two.load(lines: leftHalf)
        two.addPhoto(lines: rightHalf)
        XCTAssertEqual(two.rows.map(\.value), one.rows.map(\.value))
        XCTAssertEqual(two.additionalRows.map(\.value), one.additionalRows.map(\.value))
        XCTAssertEqual(two.servingText, one.servingText)
        XCTAssertEqual(two.makeProduct()?.nutrients, one.makeProduct()?.nutrients)
    }

    /// The product a merged draft makes records the panel it came from once, however many photos read
    /// it: the basis is the serving size and the values, not the number of frames behind them.
    func testAMergedDraftMakesTheSameProductAsThePanelItRead() {
        let one = makeModel()
        one.load(lines: leftHalf + rightHalf)

        let two = makeModel()
        two.load(lines: leftHalf)
        two.addPhoto(lines: rightHalf)

        XCTAssertEqual(two.makeProduct()?.labelBasis, one.makeProduct()?.labelBasis)
        XCTAssertEqual(two.makeProduct()?.nutrients, one.makeProduct()?.nutrients)
        XCTAssertEqual(two.makeProduct()?.snapshotID, one.makeProduct()?.snapshotID)
    }

    // MARK: What the capture session hands over

    /// Every capture goes through one door on the model: the first photo of a panel is loaded, and a
    /// photo taken while the user asked for another one is merged. Both are read by the same session
    /// and the same recogniser.
    func testTheSecondCaptureGoesThroughTheSameSessionAndIsMerged() {
        let model = makeModel()
        XCTAssertFalse(model.canAddPhoto, "there is no panel to add a photo to yet")

        model.capture(lines: leftHalf)
        XCTAssertEqual(model.frameCount, 1)
        XCTAssertTrue(model.isReviewing)
        XCTAssertTrue(model.canAddPhoto)

        model.beginAddingPhoto()
        XCTAssertTrue(model.isAddingPhoto)
        XCTAssertFalse(model.isReviewing, "the camera is in front of the user, not the review screen")
        XCTAssertFalse(model.canAddPhoto, "the camera is already open for another photo")

        model.capture(lines: rightHalf)

        XCTAssertFalse(model.isAddingPhoto)
        XCTAssertEqual(model.frameCount, 2)
        XCTAssertEqual(model.row(for: .calories)?.value, .known(Decimal(40), .kcal))
        XCTAssertEqual(model.row(for: .calcium)?.value, .known(Decimal(120), .mg))
    }

    /// A photo that read nothing the draft did not already have is left out entirely: a shot that
    /// missed the panel changes nothing and does not claim to be part of the review.
    func testAPhotoThatReadNothingNewContributesNothing() {
        let model = makeModel()
        model.load(lines: leftHalf)

        model.addPhoto(lines: ["Synthetic Rise Gummies, invented for tests", "Best before 2027"])

        XCTAssertEqual(model.frameCount, 1)
        XCTAssertNil(model.photoHeader)
        XCTAssertEqual(model.row(for: .calories)?.value, .known(Decimal(40), .kcal))
        XCTAssertEqual(model.additionalRows.count, 1)
        XCTAssertTrue(model.canApply)
    }

    /// A retake starts from nothing, not from the last photo: those rows may have been about a
    /// different product, and a draft holding two products would be neither.
    func testRetakeClearsEveryFrame() {
        let model = makeModel()
        model.load(lines: leftHalf)
        model.addPhoto(lines: rightHalf)
        XCTAssertEqual(model.frameCount, 2)

        model.retake()

        XCTAssertEqual(model.frameCount, 0)
        XCTAssertFalse(model.hasPanel)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.additionalRows.isEmpty)
        XCTAssertNil(model.servingText)
        XCTAssertFalse(model.canAddPhoto)
        XCTAssertNil(model.photoHeader)
    }

    // MARK: What a later photo says about a row already on screen

    /// A row only the second photo supplies keeps the name that photo printed with it. The first
    /// photo left it unknown, so there was no earlier spelling to keep, and dropping the incoming one
    /// is what turned a printed `Calcium Citrate 200mg` into a bare `Calcium` on screen and in the
    /// stored snapshot.
    func testASecondPhotoKeepsTheDisplayNameOfARowOnlyItReads() throws {
        let model = makeModel()
        model.load(lines: ["Serving Size: 2 Gummies", "Iron 8mg 4%"])
        XCTAssertNil(model.row(for: .calcium)?.displayName)
        XCTAssertEqual(model.row(for: .calcium)?.name, "Calcium")

        model.addPhoto(lines: ["Calcium Citrate 200mg 6%"])

        XCTAssertEqual(model.row(for: .calcium)?.displayName, "Calcium Citrate")
        XCTAssertEqual(model.row(for: .calcium)?.name, "Calcium Citrate")
        let product = try XCTUnwrap(model.makeProduct())
        XCTAssertEqual(product.nutrientDisplayNames["calcium"], "Calcium Citrate")
    }

    /// A third photo that reads a row differently does not overwrite what the first two said and is
    /// not dropped either: every distinct reading is kept as a candidate of its own, so the user
    /// chooses between three values rather than two, and the photo counts because it read the panel.
    func testAThirdPhotoOfAConflictedRowKeepsEveryReadingAsACandidate() throws {
        let model = makeModel()
        model.load(lines: ["Serving Size: 2 Gummies", "Calcium 120mg 6%"])
        model.addPhoto(lines: ["Calcium 130mg 6%"])
        XCTAssertEqual(model.frameCount, 2)

        model.addPhoto(lines: ["Calcium 140mg 6%"])

        let row = try XCTUnwrap(model.row(for: .calcium))
        XCTAssertEqual(row.value, .known(Decimal(120), .mg), "the value on screen is the first one")
        XCTAssertEqual(
            row.candidates.map(\.value), [.known(Decimal(130), .mg), .known(Decimal(140), .mg)],
            "each distinct reading is a candidate: the third photo is not dropped for disagreeing")
        XCTAssertEqual(row.candidates.map(\.frameIndex), [2, 3])
        XCTAssertEqual(row.candidates.map(\.support), [1, 1])
        XCTAssertTrue(row.hasConflict)
        XCTAssertEqual(model.conflictCount, 1)
        XCTAssertFalse(model.canApply)
        XCTAssertEqual(model.frameCount, 3, "the photo is counted: it read the panel")
    }

    /// A reading that agrees with a candidate already on the row raises that candidate's confidence
    /// instead of becoming a further candidate, and the agreeing photo counts too.
    func testAFurtherPhotoThatAgreesWithACandidateRaisesItsConfidence() throws {
        let model = makeModel()
        model.load(lines: ["Serving Size: 2 Gummies", "Calcium 120mg 6%"])
        model.addPhoto(lines: ["Calcium 130mg 6%"])
        model.addPhoto(lines: ["Calcium 140mg 6%"])

        model.addPhoto(lines: ["Calcium 130mg 6%"])

        let row = try XCTUnwrap(model.row(for: .calcium))
        XCTAssertEqual(row.candidates.count, 2, "an agreeing reading is not a new candidate")
        XCTAssertEqual(row.candidates.first?.support, 2, "two photos read 130 mg")
        XCTAssertEqual(row.candidates.first?.frameIndex, 2, "still the photo that read it first")
        XCTAssertEqual(row.candidates.last?.support, 1)
        XCTAssertEqual(model.frameCount, 4)

        // The user picks one of the readings, and the row is an answered row afterwards.
        XCTAssertTrue(model.chooseConflict(key: .calcium, taking: 3))
        XCTAssertEqual(model.row(for: .calcium)?.value, .known(Decimal(140), .mg))
        XCTAssertEqual(model.row(for: .calcium)?.frameIndex, 3)
        XCTAssertFalse(model.row(for: .calcium)?.hasConflict == true)
        XCTAssertTrue(model.canApply)
    }

    /// The same on a compound row: compounds merge by slug, so the readings have to meet on one row
    /// for the choice to be possible, and a third reading is kept beside the first two.
    func testAThirdPhotoOfACompoundKeepsEveryReadingAsACandidate() throws {
        let model = makeModel()
        model.load(lines: leftHalf)
        model.addPhoto(lines: rightHalfWithOtherZinc)
        model.addPhoto(lines: ["Zinc 20mg"])

        let zinc = try XCTUnwrap(model.additionalNutrient(for: "zinc"))
        XCTAssertEqual(zinc.value, .known(Decimal(11), .mg))
        XCTAssertEqual(
            zinc.candidates.map(\.value), [.known(Decimal(15), .mg), .known(Decimal(20), .mg)])
        XCTAssertEqual(model.frameCount, 3)
        XCTAssertEqual(model.conflictCount, 1)

        XCTAssertTrue(model.chooseConflict(additionalKey: "zinc", taking: 3))
        XCTAssertEqual(model.additionalNutrient(for: "zinc")?.value, .known(Decimal(20), .mg))
        XCTAssertEqual(model.conflictCount, 0)
    }

    // MARK: Opening the camera from the review screen

    /// Opening the camera ends whatever correction was open. The camera is a different screen, so an
    /// editor left standing behind it would come back with a field the user never filled in and no
    /// way to tell which row it belonged to.
    func testAddingAPhotoEndsAnOpenCorrection() {
        let model = makeModel()
        model.load(lines: leftHalf)
        model.beginCorrection(for: .sodium)
        XCTAssertEqual(model.editingKey, .sodium)

        model.beginAddingPhoto()

        XCTAssertTrue(model.isAddingPhoto)
        XCTAssertNil(model.editingKey, "the camera is open, so no editor is left behind it")
        XCTAssertNil(model.editingAdditionalKey)

        // And on the way back, whichever way the user left the camera.
        model.cancelAddingPhoto()
        XCTAssertTrue(model.isReviewing)
        XCTAssertNil(model.editingKey)
    }

    /// A compound editor is ended the same way: there is one editor at a time, and none of them are
    /// open while the camera is in front of the user.
    func testAddingAPhotoEndsAnOpenCompoundCorrection() {
        let model = makeModel()
        model.load(lines: leftHalf)
        model.beginCorrection(forAdditional: "zinc")
        XCTAssertEqual(model.editingAdditionalKey, "zinc")

        model.beginAddingPhoto()

        XCTAssertNil(model.editingAdditionalKey)
        XCTAssertNil(model.editingKey)
    }

    /// A serving size the user had already stated is not lost by opening the camera: the draft keeps
    /// what was entered, and only the edit is closed.
    func testAddingAPhotoLeavesAnEnteredServingSizeAlone() {
        let model = makeModel()
        model.load(lines: ["Supplement Facts", "Calories 40"])
        XCTAssertTrue(model.servingIsMissing)
        XCTAssertTrue(model.enterServingSize(text: "2 gummies"))

        model.beginAddingPhoto()

        XCTAssertEqual(model.servingText, "2 gummies")
        XCTAssertEqual(model.servingQuantity, Quantity(value: Decimal(2), unit: .gummy))
        XCTAssertTrue(model.isServingConfirmed)
    }
}