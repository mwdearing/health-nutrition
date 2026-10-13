import Foundation

struct JournalImportReadToken: Equatable, Sendable {
    let id: UUID
    let eraseGeneration: Int
}

/// Allows only the latest file read from the current, unerased journal generation to publish an outcome.
struct JournalImportReadGate {
    private(set) var activeToken: JournalImportReadToken?

    mutating func begin(eraseGeneration: Int) -> JournalImportReadToken {
        let token = JournalImportReadToken(id: UUID(), eraseGeneration: eraseGeneration)
        activeToken = token
        return token
    }

    mutating func cancel(_ token: JournalImportReadToken) {
        guard activeToken == token else { return }
        activeToken = nil
    }

    mutating func finish(
        _ token: JournalImportReadToken,
        currentEraseGeneration: Int,
        isErasing: Bool
    ) -> Bool {
        guard activeToken == token else { return false }
        activeToken = nil
        return !isErasing && token.eraseGeneration == currentEraseGeneration
    }
}
