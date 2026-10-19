import Foundation

/// What the speaker poller read of one Accessibility element: only the attributes the speaker rules use.
/// `children` is filled only for the subtree reads of a tile.
public struct AXNodeSnapshot: Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var value: String?
    public var description: String?
    public var identifier: String?
    /// `AXDOMIdentifier` (the HTML `id`) in web content.
    public var domIdentifier: String?
    /// `AXDOMClassList` (the HTML classes) in web content.
    public var domClasses: [String]
    public var children: [AXNodeSnapshot]

    public init(role: String? = nil, subrole: String? = nil, title: String? = nil, value: String? = nil,
                description: String? = nil, identifier: String? = nil, domIdentifier: String? = nil,
                domClasses: [String] = [], children: [AXNodeSnapshot] = []) {
        self.role = role; self.subrole = subrole; self.title = title; self.value = value; self.description = description
        self.identifier = identifier; self.domIdentifier = domIdentifier; self.domClasses = domClasses; self.children = children
    }

    /// Breadth-first, within `maxDepth` levels below this node and `maxNodes` nodes.
    public func breadthFirst(maxDepth: Int, maxNodes: Int) -> [AXNodeSnapshot] {
        var out: [AXNodeSnapshot] = []
        var queue: [(AXNodeSnapshot, Int)] = [(self, 0)]
        var i = 0
        while i < queue.count, out.count < maxNodes {
            let (node, depth) = queue[i]
            i += 1
            out.append(node)
            if depth < maxDepth { queue += node.children.map { ($0, depth + 1) } }
        }
        return out
    }
}

/// One participant tile as the meeting app shows it.
public struct SpeakerTile: Equatable, Sendable {
    public var name: String
    public var isSelf: Bool
    public var isMuted: Bool
    /// The app shows this person speaking.
    public var isLit: Bool

    public init(name: String, isSelf: Bool = false, isMuted: Bool = false, isLit: Bool = false) {
        self.name = name; self.isSelf = isSelf; self.isMuted = isMuted; self.isLit = isLit
    }
}

/// How the web apps' tiles are found and read (Meet, Teams, Slack); Zoom's boxes are read from their description.
public enum SpeakerTileRules {
    /// A tile's speaking marker is looked for this deep and this far (Wispr Flow's class union).
    public static let markerDepth = 6, markerNodes = 80
    /// A tile's name is looked for this deep and this far.
    public static let nameDepth = 8, nameNodes = 120

    /// Whether `node` (its own attributes) is a participant tile.
    public static func isTileRoot(_ node: AXNodeSnapshot, platform: SpeakerPlatform, classes: SpeakerClassNames) -> Bool {
        switch platform {
        case .zoom:
            return node.description.map(ZoomSpeakerText.isBox(description:)) ?? false
        case .teams:
            guard let kind = TeamsSpeakerText.tileKind(classes: node.domClasses, video: classes.teamsVideoTiles,
                                                       primitive: classes.teamsPrimitiveTiles),
                  let d = node.description else { return false }
            return TeamsSpeakerText.tileName(description: d, kind: kind) != nil
        case .meet, .slack:
            let roots = classes.tileRoots(platform)
            return node.domClasses.contains(where: roots.contains)
        }
    }

    /// Whether any node near the top of the tile carries one of the speaking markers.
    public static func isLit(_ tile: AXNodeSnapshot, markers: [String]) -> Bool {
        tile.breadthFirst(maxDepth: markerDepth, maxNodes: markerNodes).contains { $0.domClasses.contains(where: markers.contains) }
    }

    /// The tile's name, whether it is the user's own and whether it shows a muted badge. nil when no name.
    public static func identity(of tile: AXNodeSnapshot, platform: SpeakerPlatform, classes: SpeakerClassNames)
        -> (name: String, isSelf: Bool, isMuted: Bool)? {
        let nodes = tile.breadthFirst(maxDepth: nameDepth, maxNodes: nameNodes)
        let texts = nodes.flatMap { [$0.description, $0.value, $0.title].compactMap { $0 } }
        let raw: String?
        switch platform {
        case .zoom:
            // The same reading as the poller's (a "(Me)" or "(You)" label is the user).
            guard let box = tile.description.flatMap(ZoomSpeakerText.tile(description:)) else { return nil }
            return (box.name, box.isSelf, box.isMuted)
        case .slack:
            raw = nodes.lazy.compactMap { $0.description.flatMap(SlackSpeakerText.profileName) }.first
        case .teams:
            guard let kind = TeamsSpeakerText.tileKind(classes: tile.domClasses, video: classes.teamsVideoTiles,
                                                       primitive: classes.teamsPrimitiveTiles) else { return nil }
            raw = tile.description.flatMap { TeamsSpeakerText.tileName(description: $0, kind: kind) }
        case .meet:
            // Headings first (the name plate), then any static text.
            let candidates = nodes.filter { $0.role == "AXHeading" } + nodes.filter { $0.role == "AXStaticText" }
            raw = candidates.lazy.compactMap { n -> String? in
                guard let v = n.value.flatMap(SpeakerNames.clean) else { return nil }
                return SpeakerNames.isPlausible(v) || SpeakerNames.selfName(fromLabel: v) != nil ? v : nil
            }.first
        }
        guard let raw, let name = SpeakerNames.clean(raw) else { return nil }
        let own = SpeakerNames.selfName(fromLabel: name)
        // The name's own text is no badge (compared cleaned, as the name is).
        let muted = platform != .slack && texts.contains { SpeakerNames.clean($0) != name && TeamsSpeakerText.isMuted($0) }
        return (own ?? name, own != nil, muted)
    }

    /// A tile read in full: name, self, mute and the speaking marker.
    public static func tile(from root: AXNodeSnapshot, platform: SpeakerPlatform, classes: SpeakerClassNames) -> SpeakerTile? {
        guard let id = identity(of: root, platform: platform, classes: classes) else { return nil }
        let lit = platform == .zoom ? (root.description.flatMap(ZoomSpeakerText.box(description:))?.isSpeaking ?? false)
                                    : isLit(root, markers: classes.markers(platform))
        return SpeakerTile(name: id.name, isSelf: id.isSelf, isMuted: id.isMuted, isLit: lit)
    }
}

// MARK: - Readings and changes

/// Who the attribution can name: one person, several at once, or nobody (silence or nothing readable).
public enum SpeakerAttributionState: String, Sendable, Codable {
    case matched, ambiguous, unknown
}

/// One poll of the meeting window.
public struct SpeakerReading: Equatable, Sendable {
    public enum Signal: Equatable, Sendable {
        /// The lit tiles are the speakers.
        case tiles
        /// A label names the one speaker (Zoom's "Talking: …", Teams' call monitor).
        case remote(String)
        /// The app says only the user is talking (Teams' "You are speaking").
        case selfOnly
    }

    public var source: SpeakerSource
    /// Every tile read; nil when the window couldn't be read.
    public var tiles: [SpeakerTile]?
    public var signal: Signal
    public var reason: SpeakerReadReason?

    public init(source: SpeakerSource, tiles: [SpeakerTile]?, signal: Signal = .tiles, reason: SpeakerReadReason? = nil) {
        self.source = source; self.tiles = tiles; self.signal = signal; self.reason = reason
    }

    public static func unreadable(_ source: SpeakerSource, _ reason: SpeakerReadReason) -> SpeakerReading {
        SpeakerReading(source: source, tiles: nil, reason: reason)
    }
}

/// What the speaker poller emits whenever the reading changes (and again now and then while it holds, to show
/// it is still current). Names are the app's display names.
public struct SpeakerChange: Equatable, Sendable {
    /// `MeetingClock` seconds (the host clock both audio tracks are aligned to).
    public var timestamp: Double
    public var platform: SpeakerPlatform
    /// Remote people shown speaking; empty is silence, nil is "couldn't read".
    public var speakingNames: [String]?
    public var mutedNames: [String]?
    /// The user's own tile, when the app marks it.
    public var selfName: String?
    /// The one speaker, only when `attributionState` is `matched`.
    public var speakerName: String?
    public var attributionState: SpeakerAttributionState
    public var source: SpeakerSource
    public var reason: SpeakerReadReason?

    public init(timestamp: Double, platform: SpeakerPlatform, speakingNames: [String]?, mutedNames: [String]? = nil,
                selfName: String? = nil, speakerName: String? = nil, attributionState: SpeakerAttributionState,
                source: SpeakerSource, reason: SpeakerReadReason? = nil) {
        self.timestamp = timestamp; self.platform = platform; self.speakingNames = speakingNames; self.mutedNames = mutedNames
        self.selfName = selfName; self.speakerName = speakerName; self.attributionState = attributionState
        self.source = source; self.reason = reason
    }

    /// At most this many names per list.
    static let maxNames = 1000

    /// The change a reading makes. The user is never one of the speakers: their own tile, and any name whose key
    /// is one of `selfNames` (the user's name), are taken out before the state is decided, so a call where only
    /// the user talks is silence for the "Others" track. Wispr Flow keeps the user in; Shout's microphone track
    /// is already "You".
    public init(reading: SpeakerReading, platform: SpeakerPlatform, selfNames: [String], timestamp: Double) {
        self.timestamp = timestamp
        self.platform = platform
        source = reading.source
        reason = reading.reason
        guard let tiles = reading.tiles else {
            speakingNames = nil; mutedNames = nil; selfName = nil; speakerName = nil; attributionState = .unknown
            return
        }
        let own = tiles.first(where: \.isSelf)?.name
        selfName = own
        var selfKeys = Set(selfNames.compactMap(SpeakerNames.clean).map(SpeakerNames.key))
        if let own { selfKeys.insert(SpeakerNames.key(own)) }
        let speaking: [String]
        switch reading.signal {
        case .tiles: speaking = tiles.filter { $0.isLit && !$0.isSelf }.map(\.name)
        case .remote(let name): speaking = [name]
        case .selfOnly: speaking = []
        }
        let remote = Self.distinct(speaking).filter { !selfKeys.contains(SpeakerNames.key($0)) }
        speakingNames = remote
        mutedNames = Self.distinct(tiles.filter(\.isMuted).map(\.name))
        (attributionState, speakerName) = Self.state(speaking: remote)
    }

    /// One distinct speaker is matched, several are ambiguous, none is unknown.
    static func state(speaking: [String]) -> (SpeakerAttributionState, String?) {
        switch speaking.count {
        case 1: (.matched, speaking[0])
        case 0: (.unknown, nil)
        default: (.ambiguous, nil)
        }
    }

    /// Cleaned names in order, one per key.
    static func distinct(_ names: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for n in names {
            guard let c = SpeakerNames.clean(n), seen.insert(SpeakerNames.key(c)).inserted else { continue }
            out.append(c)
            if out.count == maxNames { break }
        }
        return out
    }

    /// Everything but the time: the same reading as `other`.
    public func sameReading(as other: SpeakerChange) -> Bool {
        var a = self; a.timestamp = 0
        var b = other; b.timestamp = 0
        return a == b
    }

    /// The change with names renamed by the user (`aliases`: name key → new name). A rename that merges two
    /// people makes a reading of both of them one speaker.
    public func renaming(_ aliases: [String: String]) -> SpeakerChange {
        guard !aliases.isEmpty else { return self }
        func map(_ n: String) -> String { aliases[SpeakerNames.key(n)] ?? n }
        var c = self
        c.speakingNames = speakingNames.map { Self.distinct($0.map(map)) }
        c.mutedNames = mutedNames.map { Self.distinct($0.map(map)) }
        c.selfName = selfName.map(map)
        if let speaking = c.speakingNames { (c.attributionState, c.speakerName) = Self.state(speaking: speaking) }
        else { c.speakerName = speakerName.map(map) }
        return c
    }
}
