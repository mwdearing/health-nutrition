#if os(iOS)
import Foundation
import NutritionDomain
import NutritionProviders
import NutritionUI
import XCTest

@testable import HealthNutrition

/// The capture session's transcript, and the way back to a draft the user had already reviewed.
///
/// A second photo of a panel is read by the same session that read the first, so the lines it holds
/// are the next photo's lines as soon as the camera recognises anything. Leaving them in place when
/// the user backs out of the camera is what lets a photo they cancelled be merged into the draft by
/// a Capture taken before the camera had read anything new.
///
/// The camera itself needs a device and is not involved here: these tests hand the session the lines
/// a frame recognised and then ask what the Capture button would do with them. The panels are
/// synthetic and name no real product or brand.
@MainActor
final class LabelCaptureSessionTests: XCTestCase {
    /// The left column of a synthetic Supplement Facts panel, with one compound under its own name.
    private var leftHalf: [String] {
        [
            "Supplement Facts",
            "Synthetic Rise Gummies, invented for tests",
            "Serving Size: 2 Gummies",
            "Calories 40",
            "Total Fat 1g 2%",
            "Sodium 180mg 8%",
            "Zinc 11mg",
        ]
    }

    /// The right column of the same panel, with the zinc read differently: 15 mg where the first
    /// photo read 11 mg.
    private var rightHalfWithOtherZinc: [String] {
        ["Calcium 120mg 6%", "Iron 8mg 4%", "Zinc 15mg"]
    }

    /// Backing out of the camera forgets what it read while the user was looking for the rest of the
    /// panel. A later "Add another photo" and a Capture taken before the camera recognised anything
    /// merges nothing at all, rather than merging the photo that was cancelled.
    func testCancellingTheSecondPhotoDiscardsWhatTheCameraHadRead() {
        let model = LabelCaptureViewModel()
        let session = LabelCaptureSession(model: model)
        model.load(lines: leftHalf)
        XCTAssertEqual(model.frameCount, 1)

        // The camera reads the rest of the panel, and the user decides they have had enough.
        model.beginAddingPhoto()
        session.update(withLines: rightHalfWithOtherZinc)
        session.cancelAddingPhoto()
        XCTAssertTrue(model.isReviewing)

        // Another photo, and a Capture before the camera has recognised anything at all.
        model.beginAddingPhoto()
        session.capture()

        XCTAssertEqual(model.frameCount, 1, "the cancelled photo did not contribute to the draft")
        XCTAssertEqual(model.row(for: .calcium)?.value, .unknown)
        XCTAssertEqual(model.row(for: .iron)?.value, .unknown)
        XCTAssertEqual(model.row(for: .calories)?.value, .known(Decimal(40), .kcal))
        XCTAssertEqual(model.additionalNutrient(for: "zinc")?.value, .known(Decimal(11), .mg))
        XCTAssertEqual(model.conflictCount, 0)
    }

    /// A second photo that is not cancelled is merged as it always was: the transcript is what makes
    /// the difference, not the session itself.
    func testACapturedSecondPhotoIsStillMergedIntoTheDraft() {
        let model = LabelCaptureViewModel()
        let session = LabelCaptureSession(model: model)
        model.load(lines: leftHalf)

        model.beginAddingPhoto()
        session.update(withLines: rightHalfWithOtherZinc)
        session.capture()

        XCTAssertEqual(model.frameCount, 2)
        XCTAssertEqual(model.row(for: .calcium)?.value, .known(Decimal(120), .mg))
        XCTAssertEqual(model.conflictCount, 1)
    }

    /// A camera that stops while another photo was being added leaves the reviewed draft on screen
    /// behind the failure, so the failure can offer the way back to it rather than only Close, which
    /// would throw away everything the user had already checked.
    func testAFailureWhileAddingAPhotoOffersTheWayBackToTheReviewedDraft() {
        let model = LabelCaptureViewModel()
        let session = LabelCaptureSession(model: model)
        let state = LabelCaptureSheetState(model: model, session: session)
        model.load(lines: leftHalf)
        XCTAssertFalse(state.canReturnToValues, "there is no failure to come back from")

        model.beginAddingPhoto()
        session.update(withLines: rightHalfWithOtherZinc)
        state.report("The camera stopped, so the panel was not read. Try again in a moment.")
        XCTAssertTrue(state.canReturnToValues, "a reviewed draft is on screen behind the failure")

        XCTAssertTrue(state.backToValues())

        XCTAssertNil(state.failureMessage)
        XCTAssertTrue(model.isReviewing)
        XCTAssertEqual(model.frameCount, 1, "the draft behind the failure is untouched")
        XCTAssertEqual(model.row(for: .calories)?.value, .known(Decimal(40), .kcal))
        XCTAssertEqual(model.additionalNutrient(for: "zinc")?.value, .known(Decimal(11), .mg))
        XCTAssertEqual(model.conflictCount, 0)
    }

    /// Coming back from a failure is the same as backing out of the camera: the transcript of the
    /// failed photo goes with it, so the next Capture merges nothing the camera read in vain.
    func testComingBackFromAFailureAlsoDiscardsWhatTheCameraHadRead() {
        let model = LabelCaptureViewModel()
        let session = LabelCaptureSession(model: model)
        let state = LabelCaptureSheetState(model: model, session: session)
        model.load(lines: leftHalf)

        model.beginAddingPhoto()
        session.update(withLines: rightHalfWithOtherZinc)
        state.report("The camera stopped, so the panel was not read. Try again in a moment.")
        state.backToValues()

        model.beginAddingPhoto()
        session.capture()

        XCTAssertEqual(model.frameCount, 1)
        XCTAssertEqual(model.row(for: .calcium)?.value, .unknown)
        XCTAssertEqual(model.conflictCount, 0)
    }

    /// A failure with no reviewed draft behind it has nothing to go back to, so the sheet only offers
    /// to close: before the first photo there is nothing on screen to lose.
    func testAFailureBeforeAnyDraftOffersNoWayBack() {
        let model = LabelCaptureViewModel()
        let session = LabelCaptureSession(model: model)
        let state = LabelCaptureSheetState(model: model, session: session)

        state.report("This device cannot read text with the camera. Type the values in instead.")

        XCTAssertFalse(state.canReturnToValues)
        XCTAssertFalse(state.backToValues(), "there is no draft to return to")
        XCTAssertEqual(state.failureMessage, "This device cannot read text with the camera. Type the values in instead.")
    }
}
#endif
