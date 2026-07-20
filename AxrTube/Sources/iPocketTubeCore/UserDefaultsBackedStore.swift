import Foundation
import os

private let storeLog = Logger(subsystem: appSubsystem, category: "UserDefaultsBackedStore")

// MARK: - UserDefaultsBackedStore
//
// Protocol shared by all actor-based stores that persist a single Codable value
// to UserDefaults as JSON.
//
// Conforming types provide:
//   - defaultsKey  — the UserDefaults key
//   - defaults     — the UserDefaults instance (standard or test-suite-isolated)
//   - encodedValue() — the current in-memory value to encode
//   - decodeValue(_:) — assigns a decoded value back to internal storage
//
// In return they receive default implementations of persist() and load().

protocol UserDefaultsBackedStore: Actor {
    /// The type stored in UserDefaults. Must be Codable and Sendable.
    associatedtype Value: Codable & Sendable

    /// The UserDefaults key for this store's data.
    static var defaultsKey: String { get }

    /// The UserDefaults instance this store reads from and writes to.
    /// Use `.standard` in production and a suite-isolated instance in tests.
    var defaults: UserDefaults { get }

    /// Returns the current in-memory value to encode and persist.
    func encodedValue() -> Value

    /// Assigns a decoded value loaded from UserDefaults to internal storage.
    func decodeValue(_ decoded: Value)

    /// Called immediately after a successful persist to UserDefaults.
    /// Conformers may override this to push the new value to iCloud sync.
    /// Default implementation is a no-op.
    func afterPersist()
}

extension UserDefaultsBackedStore {
    func afterPersist() {}

    /// Decodes the stored value from `defaults`. Nonisolated — safe to call
    /// from actor `init` before isolation is established.
    static func loadFrom(_ defaults: UserDefaults) -> Value? {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(Value.self, from: data)
        else { return nil }
        return decoded
    }

    /// Encodes the current in-memory value as JSON, writes it to UserDefaults,
    /// then calls `afterPersist()` for optional side effects (e.g. iCloud push).
    /// Call after any mutation that should be durable.
    func persist() {
        do {
            let data = try JSONEncoder().encode(encodedValue())
            defaults.set(data, forKey: Self.defaultsKey)
            afterPersist()
        } catch {
            storeLog.error("[\(Self.defaultsKey, privacy: .public)] persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
