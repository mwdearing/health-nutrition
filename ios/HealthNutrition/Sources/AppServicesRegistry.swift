/// The running app's services, for the system entry points (App Intents) that start in the app's own
/// process and have no view tree to receive them from.
///
/// Set once by the app at launch. An entry point that runs before it is set, or in a build that failed to
/// open its stores, finds nil and says so rather than writing anywhere else: there is only ever one store.
@MainActor
enum AppServicesRegistry {
    private(set) static var current: AppServices?

    static func register(_ services: AppServices) {
        current = services
    }
}
