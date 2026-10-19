import Foundation

/// One stretch of the recording timeline during which the meeting app showed the same reading.
public struct SpeakerSpan: Hashable, Sendable {
    /// The leg it was read in (`resumed` marker seq, 0 for the first leg).
    public var leg: Int
    /// Timeline position (ms) of the first reading.
    public var startMs: Int
    /// The last time the poller saw this reading, or when the next one replaced it.
    public var endMs: Int
    public var platform: SpeakerPlatform
    public var state: SpeakerAttributionState
    public var speakerName: String?
    public var speakingNames: [String]?
    public var mutedNames: [String]?
    public var selfName: String?
    public var source: SpeakerSource?
    public var reason: SpeakerReadReason?

    public init(leg: Int = 0, startMs: Int, endMs: Int, platform: SpeakerPlatform, state: SpeakerAttributionState,
                speakerName: String? = nil, speakingNames: [String]? = nil, mutedNames: [String]? = nil,
                selfName: String? = nil, source: SpeakerSource? = nil, reason: SpeakerReadReason? = nil) {
        self.leg = leg; self.startMs = startMs; self.endMs = endMs; self.platform = platform; self.state = state
        self.speakerName = speakerName; self.speakingNames = speakingNames; self.mutedNames = mutedNames
        self.selfName = selfName; self.source = source; self.reason = reason
    }

    /// A span of `state` for one speaker (tests, demo data).
    public static func matched(_ name: String, _ startMs: Int, _ endMs: Int, leg: Int = 0,
                               platform: SpeakerPlatform = .zoom) -> SpeakerSpan {
        SpeakerSpan(leg: leg, startMs: startMs, endMs: endMs, platform: platform, state: .matched, speakerName: name,
                    speakingNames: [name])
    }

    init(_ change: SpeakerChange, leg: Int, atMs: Int) {
        self.init(leg: leg, startMs: atMs, endMs: atMs, platform: change.platform, state: change.attributionState,
                  speakerName: change.speakerName, speakingNames: change.speakingNames, mutedNames: change.mutedNames,
                  selfName: change.selfName, source: change.source, reason: change.reason)
    }

    func shows(_ change: SpeakerChange) -> Bool {
        platform == change.platform && state == change.attributionState && speakerName == change.speakerName
            && speakingNames == change.speakingNames && mutedNames == change.mutedNames && selfName == change.selfName
            && source == change.source && reason == change.reason
    }

    /// The span with every name whose key is `oldKey` replaced by `name`.
    public func renaming(key oldKey: String, to name: String) -> SpeakerSpan { renaming([oldKey: name]) }

    /// The span with names renamed by the user (`aliases`: name key → new name). A rename that merges two people
    /// makes a reading of both of them one speaker.
    public func renaming(_ aliases: [String: String]) -> SpeakerSpan {
        guard !aliases.isEmpty else { return self }
        func map(_ n: String) -> String { aliases[SpeakerNames.key(n)] ?? n }
        var s = self
        s.speakingNames = speakingNames.map { SpeakerChange.distinct($0.map(map)) }
        s.mutedNames = mutedNames.map { SpeakerChange.distinct($0.map(map)) }
        s.selfName = selfName.map(map)
        if let speaking = s.speakingNames { (s.state, s.speakerName) = SpeakerChange.state(speaking: speaking) }
        else { s.speakerName = speakerName.map(map) }
        return s
    }

    /// Whether a name with key `key` appears anywhere in the span.
    public func mentions(key: String) -> Bool {
        ([speakerName, selfName].compactMap { $0 } + (speakingNames ?? []) + (mutedNames ?? []))
            .contains { SpeakerNames.key($0) == key }
    }
}

/// The spans of one recording leg, built from the poller's changes as they arrive. A change that repeats the
/// current reading only confirms it (moves its end); any other change closes it.
public struct SpeakerTimeline: Sendable {
    public let leg: Int
    /// Closed spans, then the open one (while `isOpen`).
    public private(set) var spans: [SpeakerSpan] = []
    public private(set) var isOpen = false
    /// Spans handed out by `takeClosed` so far.
    private var taken = 0

    public init(leg: Int) { self.leg = leg }

    public mutating func record(_ change: SpeakerChange, atMs t: Int) {
        if isOpen, let last = spans.last {
            let at = max(t, last.endMs)
            if last.shows(change) {
                spans[spans.count - 1].endMs = at
                return
            }
            spans[spans.count - 1].endMs = at
            spans.append(SpeakerSpan(change, leg: leg, atMs: at))
        } else {
            spans.append(SpeakerSpan(change, leg: leg, atMs: max(t, spans.last?.endMs ?? t)))
            isOpen = true
        }
    }

    /// The poller stopped at `t`: the open span ends there.
    public mutating func close(atMs t: Int) {
        guard isOpen, let last = spans.last else { return }
        spans[spans.count - 1].endMs = max(t, last.startMs)
        isOpen = false
    }

    /// Closed spans not handed out before (to be stored).
    public mutating func takeClosed() -> [SpeakerSpan] {
        let end = isOpen ? spans.count - 1 : spans.count
        guard end > taken else { return [] }
        defer { taken = end }
        return Array(spans[taken..<end])
    }

    /// Spans not stored yet: the closed ones `takeClosed` hasn't handed out, and the open one.
    public var unstored: [SpeakerSpan] { Array(spans[min(taken, spans.count)...]) }

    public mutating func rename(key: String, to name: String) {
        spans = spans.map { $0.renaming(key: key, to: name) }
    }
}

/// Names the "Others" lines of a meeting from what the meeting app showed, with Wispr Flow's rules adapted from
/// its per-token speaker votes to Shout's per-line transcript.
///
/// Each system line is sampled like a stream of tokens: one vote every `voteIntervalMs` (at least
/// `minVotesPerLine`), each looking up the reading at that moment plus `indicatorLagMs` (the app lights a tile
/// a little after the voice starts). Only a fresh `matched` reading votes: the latest span at or before that
/// moment whose last confirmation is at most `freshnessMs` old. Within the line, as in Wispr Flow's identity map,
/// a name sticks after `promoteVotes` consecutive identical votes, and changes to another name only after
/// `switchVotes` consecutive votes for it and at least `switchCooldownMs` after the previous change.
///
/// A line keeps "Others" unless it is sure: a name stuck, it holds a strict majority of the line's votes and more
/// votes than the overlapping-speakers readings, and its votes cover at least `minCoverage` of the samples.
/// Microphone lines, markers, hidden lines and lines the user labelled are never touched.
public enum SpeakerAttribution {
    public struct Rules: Equatable, Sendable {
        public var freshnessMs = 1_500
        public var promoteVotes = 3
        public var switchVotes = 5
        public var switchCooldownMs = 30_000
        public var voteIntervalMs = 250
        public var minVotesPerLine = 3
        /// The app shows a speaker this long after the audio (U6 in the spec: tune in live calls).
        public var indicatorLagMs = 300
        public var minCoverage = 0.25

        public init() {}
        public static let `default` = Rules()
    }

    /// Spans sorted for lookups, and the positions where recording stopped (a reading never carries over a stop).
    public struct Index: Sendable {
        let spans: [SpeakerSpan]
        let stops: [Int]

        public init(spans: [SpeakerSpan], stopsMs: [Int] = []) {
            self.spans = spans.sorted { ($0.startMs, $0.endMs) < ($1.startMs, $1.endMs) }
            stops = stopsMs.sorted()
        }

        /// The latest span starting at or before `x` (binary search).
        func latest(atOrBefore x: Int) -> SpeakerSpan? {
            var lo = 0, hi = spans.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if spans[mid].startMs <= x { lo = mid + 1 } else { hi = mid }
            }
            return lo > 0 ? spans[lo - 1] : nil
        }

        /// The recording stops around `t`: the last one before it and the first one at or after it.
        func leg(around t: Int) -> (start: Int, end: Int) {
            let start = stops.last { $0 < t } ?? Int.min
            let end = stops.first { $0 >= t } ?? Int.max
            return (start, end)
        }
    }

    /// What one vote found.
    enum Evidence: Equatable { case name(String), overlap, none }

    /// `leg`: the stops around the line. The lookup stays before the stop that ends it, since a span starting
    /// there is the next leg's first reading.
    static func evidence(at t: Int, leg: (start: Int, end: Int), in index: Index, rules: Rules,
                         selfKeys: Set<String>) -> Evidence {
        let x = leg.end == Int.max ? t + rules.indicatorLagMs : min(t + rules.indicatorLagMs, leg.end - 1)
        guard let span = index.latest(atOrBefore: x), span.startMs >= leg.start,
              x - span.endMs <= rules.freshnessMs else { return .none }
        switch span.state {
        case .matched:
            guard let name = span.speakerName, !selfKeys.contains(SpeakerNames.key(name)) else { return .none }
            return .name(name)
        case .ambiguous: return .overlap
        case .unknown: return .none
        }
    }

    /// Vote times across a line: every `voteIntervalMs`, at least `minVotesPerLine`, first and last included.
    static func sampleTimes(startMs: Int, endMs: Int, rules: Rules) -> [Int] {
        let d = max(0, endMs - startMs)
        let n = max(rules.minVotesPerLine, d / max(1, rules.voteIntervalMs) + 1)
        guard n > 1 else { return [startMs] }
        return (0..<n).map { startMs + d * $0 / (n - 1) }
    }

    /// The name of one line (by name key; nil keeps "Others").
    static func verdict(startMs: Int, endMs: Int, index: Index, rules: Rules, selfKeys: Set<String>) -> String? {
        var candidate: String?, candidateCount = 0
        var canonical: String?
        var conflict: String?, conflictCount = 0
        var lastSwitch: Int?
        var votes: [String: Int] = [:], overlap = 0
        let times = sampleTimes(startMs: startMs, endMs: endMs, rules: rules)
        // The line's leg, from its middle: a line starting or ending at a stop is still on its own side of it.
        let leg = index.leg(around: startMs + max(0, endMs - startMs) / 2)
        for t in times {
            let key: String
            switch evidence(at: t, leg: leg, in: index, rules: rules, selfKeys: selfKeys) {
            case .none: continue
            case .overlap: overlap += 1; continue
            case .name(let name): key = SpeakerNames.key(name)
            }
            votes[key, default: 0] += 1
            guard let current = canonical else {
                if key == candidate { candidateCount += 1 } else { candidate = key; candidateCount = 1 }
                if candidateCount >= rules.promoteVotes { canonical = key }
                continue
            }
            if key == current { conflict = nil; conflictCount = 0; continue }
            // Wispr Flow's cooldown runs from the previous change of name, not from the first naming.
            if let last = lastSwitch, t - last < rules.switchCooldownMs { continue }
            if key == conflict { conflictCount += 1 } else { conflict = key; conflictCount = 1 }
            if conflictCount >= rules.switchVotes {
                canonical = key; lastSwitch = t; conflict = nil; conflictCount = 0
            }
        }
        guard let name = canonical, let mine = votes[name] else { return nil }
        let trusted = votes.values.reduce(0, +)
        guard mine * 2 > trusted, mine > overlap, Double(mine) >= rules.minCoverage * Double(times.count) else { return nil }
        return name
    }

    /// Names for the meeting's system ("Others") lines: segment id → name, or nil to show "Others". Only lines
    /// the user hasn't labelled are in the result. `selfNames` (the user's name) never name a line. `aliases`
    /// (name key → name) are the meeting's renames, applied to every reading, also ones made after the rename.
    public static func attribute(segments: [MeetingSegment], spans: [SpeakerSpan], selfNames: [String] = [],
                                 aliases: [String: String] = [:], rules: Rules = .default) -> [String: String?] {
        let spans = aliases.isEmpty ? spans : spans.map { $0.renaming(aliases) }
        let stops = segments.filter { $0.marker == .stopped }.map(\.startMs)
        let index = Index(spans: spans, stopsMs: stops)
        let selfKeys = Set(selfNames.compactMap(SpeakerNames.clean).map(SpeakerNames.key))
        let spellings = preferredSpellings(spans)
        var out: [String: String?] = [:]
        for s in segments where s.source == .system && s.marker == nil && !s.latched && s.speakerOrigin != .user {
            let key = verdict(startMs: s.startMs, endMs: s.endMs, index: index, rules: rules, selfKeys: selfKeys)
            out.updateValue(key.map { spellings[$0] ?? $0 }, forKey: s.id)
        }
        return out
    }

    /// For each name key, the spelling shown longest in matched spans (the first seen on a tie).
    static func preferredSpellings(_ spans: [SpeakerSpan]) -> [String: String] {
        var shown: [String: [String: (ms: Int, first: Int)]] = [:]
        for (i, s) in spans.enumerated() where s.state == .matched {
            guard let name = s.speakerName else { continue }
            let key = SpeakerNames.key(name)
            let prior = shown[key]?[name] ?? (0, i)
            shown[key, default: [:]][name] = (prior.ms + max(0, s.endMs - s.startMs), prior.first)
        }
        return shown.mapValues { names in
            names.max { a, b in a.value.ms != b.value.ms ? a.value.ms < b.value.ms : a.value.first > b.value.first }!.key
        }
    }

    // MARK: Speakers of a meeting

    /// A person named in the meeting, for the speaker chips.
    public struct Speaker: Hashable, Sendable, Identifiable {
        public var name: String
        /// Transcript lines with this name.
        public var lines: Int
        /// Time shown speaking in the app, or (without readings) the length of their lines.
        public var talkMs: Int
        public var id: String { SpeakerNames.key(name) }

        public init(name: String, lines: Int, talkMs: Int) { self.name = name; self.lines = lines; self.talkMs = talkMs }
    }

    /// The named speakers of a meeting: those with transcript lines in order of their first line, then those the
    /// app showed speaking without a line of their own, longest first. `talkMs`: time shown speaking per name.
    public static func speakers(segments: [MeetingSegment], talkMs: [String: Int] = [:]) -> [Speaker] {
        var talk: [String: (name: String, ms: Int)] = [:]
        // Longest shown first, so the spelling of a person read several ways is the same on every run.
        for (name, ms) in talkMs.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
            let k = SpeakerNames.key(name)
            talk[k] = (talk[k]?.name ?? name, (talk[k]?.ms ?? 0) + ms)
        }
        var order: [String] = []
        var found: [String: Speaker] = [:]
        for s in segments.sorted(by: { $0.startMs < $1.startMs })
        where s.source == .system && s.marker == nil && !s.latched && !s.displayText.isEmpty {
            guard let name = s.speaker.flatMap(SpeakerNames.clean) else { continue }
            let k = SpeakerNames.key(name)
            if found[k] == nil { order.append(k); found[k] = Speaker(name: name, lines: 0, talkMs: 0) }
            found[k]!.lines += 1
            found[k]!.talkMs += max(0, s.endMs - s.startMs)
        }
        var out = order.map { k -> Speaker in
            var sp = found[k]!
            if let t = talk[k], t.ms > 0 { sp.talkMs = t.ms }
            return sp
        }
        out += talk.filter { found[$0.key] == nil && $0.value.ms > 0 }
            .map { Speaker(name: $0.value.name, lines: 0, talkMs: $0.value.ms) }
            .sorted { $0.talkMs != $1.talkMs ? $0.talkMs > $1.talkMs : $0.name < $1.name }
        return out
    }
}
