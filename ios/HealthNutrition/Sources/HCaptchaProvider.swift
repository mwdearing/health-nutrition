#if os(iOS)
import Foundation
import NutritionProviders
import UIKit
#if canImport(HCaptcha)
import HCaptcha

/// The human check behind the sign-in requests, shown with the hCaptcha SDK. The site key comes from the app's
/// bundle (`HCAPTCHA_SITE_KEY`), so the repository holds none. Only the app target links the SDK.
final class HCaptchaProvider: CommunityCaptcha {
    /// The bundle key. Its build setting is empty in the repository and is filled in by the signed-beta workflow.
    static let infoKey = "HCAPTCHA_SITE_KEY"

    private let siteKey: String

    init(siteKey: String) {
        self.siteKey = siteKey
    }

    /// The provider for the bundle's site key, or nil when the build has none. An empty value and a value
    /// the build did not expand (still `$(HCAPTCHA_SITE_KEY)`) both count as no key.
    static func make(infoDictionary: [String: Any]?) -> HCaptchaProvider? {
        guard let raw = infoDictionary?[infoKey] as? String else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.hasPrefix("$(") else { return nil }
        return HCaptchaProvider(siteKey: key)
    }

    func token() async throws -> String {
        let siteKey = self.siteKey
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { @MainActor in
                HCaptchaProvider.present(siteKey: siteKey, once: once)
            }
        }
    }

    /// Shows the challenge over the top view controller. The SDK object is kept alive by the completion
    /// closure until the challenge ends, so the widget is not released while it is on screen.
    @MainActor
    private static func present(siteKey: String, once: ResumeOnce) {
        guard let top = topViewController() else {
            once.finish(.failure(CommunityError.captcha))
            return
        }
        let hcaptcha: HCaptcha
        do {
            hcaptcha = try HCaptcha(apiKey: siteKey, baseURL: URL(string: "http://localhost")!)
        } catch {
            once.finish(.failure(CommunityError.captcha))
            return
        }
        hcaptcha.validate(on: top.view, resetOnError: false) { result in
            withExtendedLifetime(hcaptcha) {
                do {
                    once.finish(.success(try result.dematerialize()))
                } catch {
                    // The person closed the check or it failed. The text of the SDK error is not kept.
                    once.finish(.failure(CommunityError.captcha))
                }
            }
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        var top = windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

/// Resumes a continuation once. The SDK reports through a completion, so a second report is ignored.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<String, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<String, Error>? in
            let current = continuation
            continuation = nil
            return current
        }
        pending?.resume(with: result)
    }
}
#endif
#endif
