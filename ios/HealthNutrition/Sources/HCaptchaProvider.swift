#if os(iOS)
import Foundation
import NutritionProviders
import UIKit
import WebKit
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

    /// Shows the challenge over the top view controller. The SDK object is held by `once` until the challenge
    /// reports, and the web view the SDK adds to the screen is removed when it ends.
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
        once.hold(hcaptcha)
        let anchor: UIView = top.view
        // The SDK sizes its web view with this hook when it is not sized yet, as its own example does.
        hcaptcha.configureWebView { [once] webView in
            webView.frame = anchor.bounds
            once.track(webView)
        }
        hcaptcha.validate(on: anchor, resetOnError: false) { [once] result in
            do {
                once.finish(.success(try result.dematerialize()))
            } catch {
                // The person closed the check or it failed. The text of the SDK error is not kept.
                once.finish(.failure(CommunityError.captcha))
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

/// Resumes a continuation once. The SDK reports through a completion, so a second report is ignored. It also holds
/// the SDK object and the web view until the challenge ends, then releases both.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var challenge: HCaptcha?
    private var webView: WKWebView?

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func hold(_ challenge: HCaptcha) {
        lock.withLock { self.challenge = challenge }
    }

    func track(_ webView: WKWebView) {
        lock.withLock { self.webView = webView }
    }

    func finish(_ result: Result<String, Error>) {
        let ended = lock.withLock { () -> (CheckedContinuation<String, Error>?, WKWebView?) in
            let pending = continuation
            let shown = webView
            continuation = nil
            challenge = nil
            webView = nil
            return (pending, shown)
        }
        ended.1?.removeFromSuperview()
        ended.0?.resume(with: result)
    }
}
#endif
#endif
