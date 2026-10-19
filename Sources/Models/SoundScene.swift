import Foundation

/// The level of one generator inside a mix.
struct ChannelSetting: Codable, Hashable {
    var kind: GeneratorKind
    var enabled: Bool
    var volume: Float
}

/// A named, saved mix of generators plus master volume. Built-in scenes have ids prefixed with `builtin.`.
struct SoundScene: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var master: Float
    var channels: [ChannelSetting]

    var isBuiltIn: Bool { id.hasPrefix("builtin.") }

    init(id: String, name: String, master: Float, channels: [ChannelSetting]) {
        self.id = id
        self.name = name
        self.master = master
        self.channels = channels
    }

    /// Builds a scene where every listed generator is enabled at the given level.
    init(id: String, name: String, master: Float = 0.7, levels: [GeneratorKind: Float]) {
        let channels = GeneratorKind.allCases.map {
            ChannelSetting(kind: $0, enabled: levels[$0] != nil, volume: levels[$0] ?? 0.5)
        }
        self.init(id: id, name: name, master: master, channels: channels)
    }

    static let builtIns: [SoundScene] = [
        SoundScene(id: "builtin.focus", name: "Focus", levels: [.pink: 0.6, .brown: 0.35]),
        SoundScene(id: "builtin.sleep", name: "Sleep", master: 0.55, levels: [.brown: 0.75, .wind: 0.35]),
        SoundScene(id: "builtin.rain", name: "Rain", levels: [.rain: 0.75, .brown: 0.3, .wind: 0.15]),
    ]

    static let fallbackID = "builtin.focus"
}
