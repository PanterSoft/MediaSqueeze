import Foundation
import Observation
import SqueezeCore
import SwiftUI

/// Persists `CompressionSettings` in UserDefaults.
@MainActor
@Observable
final class SettingsStore {
    private(set) var compression: CompressionSettings

    private let defaults: UserDefaults
    private static let key = "compressionSettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(CompressionSettings.self, from: data) {
            compression = stored
        } else {
            compression = .default
        }
    }

    func update(_ change: (inout CompressionSettings) -> Void) {
        change(&compression)
        if let data = try? JSONEncoder().encode(compression) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func resetToDefaults() {
        update { $0 = .default }
    }

    /// Binding for an encoding parameter; editing it may switch the preset to `.custom`.
    func encodingBinding<Value>(_ keyPath: WritableKeyPath<EncodingParameters, Value>) -> Binding<Value> {
        Binding(
            get: { self.compression.encoding[keyPath: keyPath] },
            set: { newValue in self.update { $0.setEncoding(keyPath, to: newValue) } }
        )
    }

    /// Binding for a setting that isn't part of a preset.
    func binding<Value>(_ keyPath: WritableKeyPath<CompressionSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.compression[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    var presetBinding: Binding<CompressionPreset> {
        Binding(
            get: { self.compression.preset },
            set: { preset in self.update { $0.apply(preset) } }
        )
    }
}
