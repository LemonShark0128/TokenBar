import Foundation

/// Browser paste and embedded capture share validation → Keychain → source activation.
/// Never include the submitted value or arbitrary error details in user-facing errors.
enum ClaudeBrowserLogin {
    enum InputError: Error { case invalid }

    static func normalize(_ input: String) throws -> String {
        guard input.count <= 4096 else { throw InputError.invalid }
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’"))
        var value = input.trimmingCharacters(in: trim)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: trim)
        }
        if value.contains("=") {
            let pairs = value.split(separator: ";")
            guard let pair = pairs.first(where: {
                $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) == ClaudeWebUsage.cookieName
            }), let separator = pair.firstIndex(of: "=") else { throw InputError.invalid }
            value = String(pair[pair.index(after: separator)...]).trimmingCharacters(in: trim)
        }
        if let decoded = value.removingPercentEncoding, decoded.hasPrefix(ClaudeWebUsage.cookiePrefix) {
            value = decoded
        }
        guard value.hasPrefix(ClaudeWebUsage.cookiePrefix),
              value.count > ClaudeWebUsage.cookiePrefix.count,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                      || ";\"'".unicodeScalars.contains($0)
              }) else { throw InputError.invalid }
        return value
    }

    @MainActor
    static func connect(_ input: String,
                        isCurrent: () -> Bool = { true },
                        validate: (String) async -> ProviderError?,
                        save: (String) async throws -> Void,
                        activate: () -> Void) async -> (ok: Bool, message: String) {
        guard isCurrent() else { return (false, "") }
        guard let key = try? normalize(input) else { return (false, L("ob.claude.webInvalid")) }
        let error = await validate(key)
        guard isCurrent() else { return (false, "") }
        if let error {
            // Only known messages; transport errors can contain arbitrary request information.
            let message: String
            switch error {
            case .auth: message = L("claudeWeb.expired")
            case .rateLimited: message = L("claudeWeb.throttled")
            case .unavailable(let detail) where detail == L("claudeWeb.cloudflare") || detail == L("claudeWeb.throttled"):
                message = detail
            case .schemaChanged(let detail) where detail == L("claudeWeb.noOrg"):
                message = detail
            default: message = L("claudeWeb.unrecognized")
            }
            return (false, message)
        }
        do { try await save(key) }
        catch { return (false, L("ob.claude.webSaveFailed")) }
        guard isCurrent() else { return (false, "") }
        activate()
        return (true, L("ob.claude.webGot"))
    }
}

/// Ownership spans validation, queued Keychain writes and completion callbacks.
/// The lock makes supersession and the actual synchronous Keychain write atomic.
final class ClaudeLoginAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var current = UUID()

    struct Ticket: Sendable {
        fileprivate let owner: ClaudeLoginAttempts
        fileprivate let id: UUID
        var isCurrent: Bool {
            owner.lock.lock()
            defer { owner.lock.unlock() }
            return owner.current == id
        }
        func commit(_ write: () throws -> Void) throws {
            owner.lock.lock()
            defer { owner.lock.unlock() }
            guard owner.current == id else { throw CancellationError() }
            try write()
        }
    }

    func begin() -> Ticket {
        lock.lock()
        defer { lock.unlock() }
        current = UUID()
        return Ticket(owner: self, id: current)
    }
}
