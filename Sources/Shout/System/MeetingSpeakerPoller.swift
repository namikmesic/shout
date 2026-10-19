import AppKit
import ApplicationServices
import ShoutKit

/// Reads who is talking in the recorded call from the meeting app's own window through Accessibility, as Wispr
/// Flow's helper does: Zoom's participant boxes and floating "Talking:" label, the tiles of Meet and Slack
/// huddles with their speaking classes, and Teams' gallery tiles and call monitor.
///
/// Polling only, on a utility queue (never the main thread): a one-shot timer re-armed every 0.15 s ± 10 %.
/// Each tick does a bounded slice of work:
/// - Discovery (a walk of the meeting window that finds the tiles) is spread over ticks, a few dozen ms each,
///   and runs at start, every 7 s, after an element went away, and while Teams shows no gallery every 1 s
///   after the previous one ended, backing off to 2, 4 and 7 s while it keeps finding none.
/// - Tiles are read round-robin within the tick's budget; a tile counts while its last read is recent. A web
///   tile reads the element where the speaking class appeared (learned from any tile) first, and its whole top
///   only now and then, or when that path is unknown.
/// Every Accessibility message has a short timeout, and an app that keeps timing out is left alone for a while,
/// so a hung app can't stall it. What a reading means is decided by the pure rules in ShoutKit
/// (`SpeakerTileRules`, `SpeakerChange`); waking Chromium and Electron trees goes through `AXWakeRegistry`.
///
/// Emits a `SpeakerChange` (on its queue) whenever the reading changes, and the same reading again every second
/// while it holds, so the timeline knows it is still current. Does nothing without Accessibility permission.
final class MeetingSpeakerPoller: @unchecked Sendable {
    static let fastTick: TimeInterval = 0.15
    static let jitter = 0.1
    static let heartbeat: TimeInterval = 7
    static let teamsEmptyGalleryRebuild: TimeInterval = 1
    /// The window may still show the previous state right after start (Wispr Flow's `startupAttributionDelay`).
    static let startupDelay: TimeInterval = 0.5
    /// An unchanged reading is sent again this often.
    static let confirmInterval: TimeInterval = 1
    static let readTimeout: Float = 0.1
    static let discoveryTimeout: Float = 0.2
    /// Walk bounds: Wispr Flow's broad tier (30 levels, 40 for Teams; 20 000 elements), plus a time budget per
    /// discovery (smaller for the empty-gallery rebuild) spent in slices of `discoverySlice` per tick.
    static let maxDepth = 30, teamsMaxDepth = 40, maxElements = 20_000
    static let discoveryBudget: TimeInterval = 1.5, emptyGalleryBudget: TimeInterval = 0.3
    static let discoverySlice: TimeInterval = 0.04
    /// Time per tick for reading tiles.
    static let readBudget: TimeInterval = 0.08
    /// A tile read longer ago than this no longer counts (the reading is partial instead).
    static let tileFreshness: TimeInterval = 1.5
    /// A web tile whose speaking path is known is walked in full at most this often.
    static let fullTileWalkEvery: TimeInterval = 2
    static let maxWindows = 8
    /// After this many timed-out messages in a row the app counts as busy and is left alone for a while.
    static let busyAfterTimeouts = 2
    static let busyBackoff: TimeInterval = 2

    let target: SpeakerTarget
    private let selfNames: [String]
    private let classes: SpeakerClassNames
    /// Called on the poller's queue.
    var onChange: (@Sendable (SpeakerChange) -> Void)?

    private let queue = DispatchQueue(label: "shout.meetingSpeakerPoller", qos: .utility)
    /// Start and stop are called on the main thread.
    private var registered = false
    // Everything below is only touched on `queue`.
    private var running = false
    private var generation = 0
    private var timer: DispatchSourceTimer?
    private var startedAt: TimeInterval = 0
    private var lastDiscoveryEnd: TimeInterval = -.infinity
    private var lastFullDiscoveryEnd: TimeInterval = -.infinity
    private var emptyDiscoveries = 0
    private var needsDiscovery = true
    private var walk: Walk?
    private var busyUntil: TimeInterval = 0
    private var tickTimeouts = 0
    private var timeoutsInARow = 0
    private var bound: Bound?
    private var unbound: SpeakerReadReason = .sourceMissing
    private var knownNames: [String] = []
    /// Child indices from a tile to the element where the speaking class appeared.
    private var markerPath: [Int]?
    private var cursor = 0
    private var lastSent: SpeakerChange?
    private var lastSentAt: TimeInterval = 0

    /// A participant tile: what discovery read of it, and its latest read.
    private struct Tile {
        let element: AXUIElement
        var name: String
        var isSelf: Bool
        var isMuted: Bool
        var isLit = false
        var readAt: TimeInterval = -.infinity
        /// The element at `markerPath` in this tile (looked up once per path), and when the tile was last walked in full.
        var markerHost: AXUIElement?
        var hostPath: [Int]?
        var walkedAt: TimeInterval = -.infinity

        init(element: AXUIElement, name: String, isSelf: Bool, isMuted: Bool) {
            self.element = element; self.name = name; self.isSelf = isSelf; self.isMuted = isMuted
        }
    }

    /// What discovery found to read on every tick.
    private struct Bound {
        /// The meeting window (Meet's visibility check).
        var window: AXUIElement?
        var tiles: [Tile] = []
        /// Zoom's floating windows, or Teams' call monitor title.
        var compact: [AXUIElement] = []
    }

    /// A discovery in progress, walked a slice per tick.
    private struct Walk {
        struct Window { let element: AXUIElement; let frame: CGRect?; let gallery: Bool }
        var windows: [Window]
        var queue: [(AXUIElement, Int)] = []
        var index = 0
        var visited = 0
        var spent: TimeInterval = 0
        let budget: TimeInterval
        var found = Bound()
        var windowTiles: [Tile] = []
        var roster: [String] = []
        let hadCandidates: Bool
        /// A full discovery (not the quick rebuild of an empty Teams gallery).
        var full = true
    }

    init(target: SpeakerTarget, selfNames: [String], classes: SpeakerClassNames) {
        self.target = target
        self.selfNames = selfNames
        self.classes = classes
    }

    /// Main thread.
    func start() {
        if target.wakesTree && !registered { AXWakeRegistry.shared.register(target.pid) }
        registered = true
        queue.async { [self] in
            guard !running, AXIsProcessTrusted() else { return }
            running = true
            generation += 1
            startedAt = MeetingClock.now()
            // A restart finds everything again and sends its first reading as soon as it has one.
            needsDiscovery = true
            lastDiscoveryEnd = -.infinity
            lastFullDiscoveryEnd = -.infinity
            emptyDiscoveries = 0
            busyUntil = 0
            timeoutsInARow = 0
            unbound = .sourceMissing
            lastSent = nil
            lastSentAt = 0
            schedule(after: 0)
        }
    }

    /// Main thread. The app's tree is put back once no poller reads it (`AXWakeRegistry`).
    func stop() {
        if target.wakesTree && registered { AXWakeRegistry.shared.unregister(target.pid) }
        registered = false
        queue.async { [self] in
            guard running else { return }
            running = false
            generation += 1
            timer?.cancel()
            timer = nil
            bound = nil
            walk = nil
        }
    }

    // MARK: Ticks

    private func schedule(after delay: TimeInterval) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + delay, leeway: .milliseconds(20))
        let gen = generation
        t.setEventHandler { [weak self] in self?.tick(gen) }
        timer?.cancel()
        timer = t
        t.resume()
    }

    private func tick(_ gen: Int) {
        guard running, gen == generation else { return }
        let now = MeetingClock.now()
        var next = Self.fastTick * Double.random(in: (1 - Self.jitter)...(1 + Self.jitter))
        if now < busyUntil {
            send(.unreadable(defaultSource, .readFailed), now: now)
        } else {
            tickTimeouts = 0
            if walk == nil, discoveryDue(now) { beginDiscovery(now: now) }
            if walk != nil { continueDiscovery() }
            let reading = read(deadline: MeetingClock.now() + Self.readBudget)
            timeoutsInARow = tickTimeouts > 0 ? timeoutsInARow + tickTimeouts : 0
            if timeoutsInARow >= Self.busyAfterTimeouts {
                // A hung app: no more messages piling up in its queue for a while, then everything is found again.
                timeoutsInARow = 0
                busyUntil = MeetingClock.now() + Self.busyBackoff
                walk = nil
                needsDiscovery = true
                next = Self.busyBackoff
                send(.unreadable(defaultSource, .readFailed), now: MeetingClock.now())
            } else {
                send(reading, now: MeetingClock.now())
            }
        }
        guard running, gen == generation else { return }
        schedule(after: next)
    }

    private func send(_ reading: SpeakerReading, now: TimeInterval) {
        guard now - startedAt >= Self.startupDelay else { return }
        let change = SpeakerChange(reading: reading, platform: target.platform, selfNames: selfNames, timestamp: now)
        if let last = lastSent, change.sameReading(as: last), now - lastSentAt < Self.confirmInterval { return }
        lastSent = change
        lastSentAt = now
        onChange?(change)
    }

    private var defaultSource: SpeakerSource {
        switch target.platform {
        case .zoom: .zoomMain
        case .meet: .meetTab
        case .teams: .teamsMain
        case .slack: .slackWindow
        }
    }

    private var teamsGalleryEmpty: Bool { target.platform == .teams && (bound?.tiles.isEmpty ?? true) }

    /// Timed from the end of the previous discovery. An empty Teams gallery is looked for again after 1 s, then
    /// 2, 4 and 7 s while it stays empty; an element that went away asks for one at once (at most once a second).
    private func discoveryDue(_ now: TimeInterval) -> Bool {
        let since = now - lastDiscoveryEnd
        if needsDiscovery { return since >= Self.teamsEmptyGalleryRebuild }
        if teamsGalleryEmpty {
            let backoff = Self.teamsEmptyGalleryRebuild * pow(2, Double(max(0, emptyDiscoveries - 1)))
            return since >= min(Self.heartbeat, backoff)
        }
        return since >= Self.heartbeat
    }

    // MARK: Discovery

    private func beginDiscovery(now: TimeInterval) {
        needsDiscovery = false
        if target.wakesTree { AXWakeRegistry.shared.wake(pid: target.pid, bundleID: target.bundleID) }
        let app = AXUIElementCreateApplication(target.pid)
        guard let windows: [AXUIElement] = value(app, kAXWindowsAttribute, timeout: Self.discoveryTimeout) else {
            finishDiscovery(bound: nil, reason: .readFailed)
            return
        }
        let hidden = NSRunningApplication(processIdentifier: target.pid)?.isHidden ?? false
        var infos: [WindowInfo] = []
        for window in windows.prefix(Self.maxWindows * 4) {
            // An app that stops answering is left to the busy back-off rather than asked about every window.
            guard tickTimeouts < Self.busyAfterTimeouts else { needsDiscovery = true; return }
            if let info = windowInfo(window) { infos.append(info) }
        }
        // While Teams shows no gallery, the frequent rebuilds are quick ones; a full discovery still runs every 7 s.
        let quick = teamsGalleryEmpty && now - lastFullDiscoveryEnd < Self.heartbeat
        let budget = quick ? Self.emptyGalleryBudget : Self.discoveryBudget
        switch target.platform {
        case .zoom: planZoom(infos, hidden: hidden, budget: budget)
        case .meet, .teams, .slack: planWeb(infos, hidden: hidden, budget: budget)
        }
    }

    private struct WindowInfo {
        let element: AXUIElement
        let role: String?, subrole: String?, title: String, identifier: String?
        let minimized: Bool
        let frame: CGRect?
    }

    private func windowInfo(_ element: AXUIElement) -> WindowInfo? {
        guard let v = values(element, [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXIdentifierAttribute,
                                       kAXMinimizedAttribute, kAXPositionAttribute, kAXSizeAttribute], timeout: Self.discoveryTimeout)
        else { return nil }
        return WindowInfo(element: element, role: v[0] as? String, subrole: v[1] as? String, title: v[2] as? String ?? "",
                          identifier: v[3] as? String, minimized: v[4] as? Bool ?? false, frame: Self.frame(position: v[5], size: v[6]))
    }

    private func planZoom(_ windows: [WindowInfo], hidden: Bool, budget: TimeInterval) {
        // The meeting window by its identifier (the same in every language), else a standard window titled so.
        let main = windows.first { $0.identifier == MeetingDetection.zoomMeetingWindowID }
            ?? windows.first { $0.role == kAXWindowRole && $0.subrole == kAXStandardWindowSubrole
                && SpeakerWindows.isMeetingWindow(title: $0.title, platform: .zoom) }
        // Floating windows (minimised meeting, mini video) are ignored while Zoom is hidden.
        let compact = hidden ? [] : windows.filter { $0.role == kAXWindowRole && $0.subrole == "AXSystemDialog" && $0.element != main?.element }
        var found = Bound(window: main?.element, compact: compact.prefix(Self.maxWindows).map(\.element))
        guard let main else {
            finishDiscovery(bound: compact.isEmpty ? nil : found, reason: .sourceMissing)
            return
        }
        found.window = main.element
        startWalk(Walk(windows: [.init(element: main.element, frame: main.frame, gallery: true)], budget: budget, found: found,
                       hadCandidates: true))
    }

    private func planWeb(_ windows: [WindowInfo], hidden: Bool, budget: TimeInterval) {
        let platform = target.platform
        var candidates = windows.filter { SpeakerWindows.isMeetingWindow(title: $0.title, platform: platform) }
        if platform == .meet {
            // Only the recorded call's window, chosen before the visibility gate: when it is minimised the call
            // is hidden, and another meeting's window never stands in for it.
            candidates = SpeakerWindows.meetWindows(candidates, code: target.meetingCode, title: \.title)
            // Meet must be on screen (Wispr Flow's visibility gate): not hidden, not minimised.
            let visible = candidates.filter { !$0.minimized }
            if !candidates.isEmpty && (hidden || visible.isEmpty) {
                finishDiscovery(bound: nil, reason: .sourceHidden)
                return
            }
            candidates = visible
        }
        // Native Teams shows its call monitor in a window of its own, whatever its title. A full discovery walks
        // every window; the quick rebuild of an empty gallery only the meeting windows, keeping the monitor it had.
        let quick = budget < Self.discoveryBudget
        let everyWindow = platform == .teams && !target.inBrowser && !quick
        let walked = (everyWindow ? windows : candidates).prefix(Self.maxWindows).map { w in
            Walk.Window(element: w.element, frame: w.frame, gallery: candidates.contains { $0.element == w.element })
        }
        let kept = quick ? bound?.compact ?? [] : []
        guard !walked.isEmpty else {
            finishDiscovery(bound: kept.isEmpty ? nil : Bound(compact: kept), reason: .sourceMissing, full: !quick)
            return
        }
        startWalk(Walk(windows: walked, budget: budget, found: Bound(window: candidates.first?.element, compact: kept),
                       hadCandidates: !candidates.isEmpty, full: !quick))
    }

    private func startWalk(_ w: Walk) {
        var w = w
        w.queue = [(w.windows[0].element, 0)]
        walk = w
    }

    /// Walks on for a slice of this tick; finishes the discovery when every window is walked or its budget spent.
    private func continueDiscovery() {
        guard var w = walk else { return }
        let start = MeetingClock.now()
        let deadline = start + min(Self.discoverySlice, max(0, w.budget - w.spent))
        let platform = target.platform
        let attributes = platform == .zoom ? [kAXDescriptionAttribute, kAXPositionAttribute, kAXSizeAttribute]
                                           : [kAXRoleAttribute, kAXDescriptionAttribute, "AXDOMIdentifier", "AXDOMClassList"]
        let depthLimit = platform == .teams ? Self.teamsMaxDepth : Self.maxDepth
        var done = false
        while MeetingClock.now() < deadline, tickTimeouts < Self.busyAfterTimeouts {
            if w.index >= w.queue.count {
                endWindow(&w)
                guard !w.windows.isEmpty else { done = true; break }
                w.queue = [(w.windows[0].element, 0)]
                w.index = 0
                continue
            }
            let (element, depth) = w.queue[w.index]
            w.index += 1
            w.visited += 1
            if w.visited > Self.maxElements { done = true; break }
            guard let v = values(element, attributes + [kAXChildrenAttribute], timeout: Self.readTimeout) else { continue }
            let descend = platform == .zoom ? visitZoom(element, v, &w) : visitWeb(element, v, &w)
            if descend, depth < depthLimit, let kids = v.last as? [AXUIElement] { w.queue += kids.map { ($0, depth + 1) } }
        }
        w.spent += MeetingClock.now() - start
        if done || w.spent >= w.budget {
            endWindow(&w)
            finishDiscovery(w)
        } else {
            walk = w
        }
    }

    private func visitZoom(_ element: AXUIElement, _ v: [Any?], _ w: inout Walk) -> Bool {
        guard let d = v[0] as? String, ZoomSpeakerText.isBox(description: d) else { return true }
        // A box outside the window (a gallery page scrolled away) isn't on screen.
        let onScreen = w.windows.first?.frame.map { window in
            Self.frame(position: v[1], size: v[2]).map { window.insetBy(dx: -2, dy: -2).contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? true
        } ?? true
        if onScreen, let box = ZoomSpeakerText.tile(description: d) {
            w.windowTiles.append(Tile(element: element, name: box.name, isSelf: box.isSelf, isMuted: box.isMuted))
        }
        return false
    }

    private func visitWeb(_ element: AXUIElement, _ v: [Any?], _ w: inout Walk) -> Bool {
        let platform = target.platform
        let node = AXNodeSnapshot(role: v[0] as? String, description: v[1] as? String, domIdentifier: v[2] as? String,
                                  domClasses: v[3] as? [String] ?? [])
        if platform == .teams, let id = node.domIdentifier {
            if id == TeamsSpeakerText.callMonitorTitleID { w.found.compact.append(element); return false }
            if id.hasPrefix(TeamsSpeakerText.rosterItemPrefix), let d = node.description,
               let name = d.split(separator: ",").first.flatMap({ SpeakerNames.clean(String($0)) }), SpeakerNames.isPlausible(name) {
                w.roster.append(name)
            }
        }
        guard w.windows.first?.gallery == true, SpeakerTileRules.isTileRoot(node, platform: platform, classes: classes) else { return true }
        if let full = snapshot(element, attributes: Self.identityAttributes, maxDepth: SpeakerTileRules.nameDepth,
                               maxNodes: SpeakerTileRules.nameNodes, deadline: MeetingClock.now() + Self.discoverySlice),
           let id = SpeakerTileRules.identity(of: full, platform: platform, classes: classes) {
            w.windowTiles.append(Tile(element: element, name: id.name, isSelf: id.isSelf, isMuted: id.isMuted))
        }
        return false
    }

    /// The current window is done: Teams and Slack bind only a window with named tiles, and the first such wins.
    private func endWindow(_ w: inout Walk) {
        guard !w.windows.isEmpty else { return }
        if w.found.tiles.isEmpty && !w.windowTiles.isEmpty {
            w.found.tiles = w.windowTiles
            // Meet's visibility check follows the window the tiles are in.
            w.found.window = w.windows[0].element
        }
        w.windowTiles = []
        w.windows.removeFirst()
        w.queue = []
        w.index = 0
    }

    private func finishDiscovery(_ w: Walk) {
        // Names seen in this call, for Teams' call monitor label.
        var seen = Set<String>()
        knownNames = Array((w.found.tiles.map(\.name) + w.roster + knownNames).filter { seen.insert(SpeakerNames.key($0)).inserted }.prefix(1000))
        let empty = w.found.tiles.isEmpty && w.found.compact.isEmpty
        finishDiscovery(bound: empty ? nil : w.found, reason: w.hadCandidates ? .indicatorUnavailable : .sourceMissing, full: w.full)
    }

    private func finishDiscovery(bound found: Bound?, reason: SpeakerReadReason, full: Bool = true) {
        walk = nil
        lastDiscoveryEnd = MeetingClock.now()
        if full { lastFullDiscoveryEnd = lastDiscoveryEnd }
        emptyDiscoveries = (found?.tiles.isEmpty ?? true) ? emptyDiscoveries + 1 : 0
        unbound = reason
        guard var found else { bound = nil; return }
        // Tiles found again keep their latest read, so a discovery never leaves a gap in the readings.
        let old = bound?.tiles ?? []
        for i in found.tiles.indices {
            if let prior = old.first(where: { CFEqual($0.element, found.tiles[i].element) }) {
                found.tiles[i].isLit = prior.isLit
                found.tiles[i].readAt = prior.readAt
                found.tiles[i].markerHost = prior.markerHost
                found.tiles[i].hostPath = prior.hostPath
                found.tiles[i].walkedAt = prior.walkedAt
            }
        }
        bound = found
        cursor = 0
    }

    static let identityAttributes = [kAXRoleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
                                     "AXDOMIdentifier", "AXDOMClassList"]

    // MARK: Reading

    private func read(deadline: TimeInterval) -> SpeakerReading {
        guard var b = bound else { return .unreadable(defaultSource, unbound) }
        if target.platform == .meet, !meetWindowVisible(b) { return .unreadable(.meetTab, .sourceHidden) }
        // Round-robin from where the last tick stopped, within the budget.
        let count = b.tiles.count
        var readCount = 0
        while readCount < count, MeetingClock.now() < deadline {
            let i = (cursor + readCount) % count
            readCount += 1
            if target.platform == .zoom { readZoomTile(&b.tiles[i]) } else { readWebTile(&b.tiles[i]) }
        }
        if count > 0 { cursor = (cursor + readCount) % count }
        bound = b
        let now = MeetingClock.now()
        let fresh = b.tiles.filter { now - $0.readAt <= Self.tileFreshness }
        let tiles = fresh.map { SpeakerTile(name: $0.name, isSelf: $0.isSelf, isMuted: $0.isMuted, isLit: $0.isLit) }
        let partial = fresh.count < b.tiles.count
        return target.platform == .zoom ? zoomReading(b, tiles: tiles, partial: partial, deadline: deadline)
                                        : webReading(b, tiles: tiles, partial: partial)
    }

    /// Meet's visibility gate on every tick (one message): a minimised or hidden window shows stale tiles.
    private func meetWindowVisible(_ b: Bound) -> Bool {
        if NSRunningApplication(processIdentifier: target.pid)?.isHidden == true { return false }
        guard let window = b.window else { return true }
        let minimized: Bool? = value(window, kAXMinimizedAttribute, timeout: Self.readTimeout)
        return minimized != true
    }

    private func readZoomTile(_ tile: inout Tile) {
        guard let d: String = value(tile.element, kAXDescriptionAttribute, timeout: Self.readTimeout),
              let box = ZoomSpeakerText.tile(description: d) else {
            // No longer a participant box (Zoom reused or dropped it): the boxes are found again.
            needsDiscovery = true
            return
        }
        // Name and self too, not only the flags: a box Zoom gave to someone else, or a participant who renamed,
        // would otherwise lend the old name to the new speech until the next discovery.
        tile.name = box.name
        tile.isSelf = box.isSelf
        tile.isLit = box.isLit
        tile.isMuted = box.isMuted
        tile.readAt = MeetingClock.now()
    }

    private func zoomReading(_ b: Bound, tiles: [SpeakerTile], partial: Bool, deadline: TimeInterval) -> SpeakerReading {
        var labels: [String: String] = [:]
        for window in b.compact {
            walk(window, attributes: [kAXRoleAttribute, kAXValueAttribute], maxDepth: 6, maxNodes: 80,
                 deadline: max(deadline, MeetingClock.now() + 0.02)) { _, v in
                if v[0] as? String == kAXStaticTextRole as String, let text = v[1] as? String, let name = ZoomSpeakerText.talkingLabel(text) {
                    labels[SpeakerNames.key(name)] = name
                }
                return true
            }
        }
        if labels.count > 1 { return .unreadable(.zoomCompact, .conflictingLabels) }
        let label = labels.values.first
        if !b.tiles.isEmpty && !partial {
            if !tiles.contains(where: \.isLit), let label { return SpeakerReading(source: .zoomCompact, tiles: tiles, signal: .remote(label)) }
            return SpeakerReading(source: .zoomMain, tiles: tiles)
        }
        if let label { return SpeakerReading(source: .zoomCompact, tiles: tiles, signal: .remote(label)) }
        if partial { return .unreadable(.zoomMain, .partialCoverage) }
        return .unreadable(b.compact.isEmpty ? .zoomMain : .zoomCompact, .indicatorUnavailable)
    }

    /// A web tile: the element on the learned speaking path first (one message); the tile's top in full when that
    /// path is unknown, gone, or not checked in full for a while.
    private func readWebTile(_ tile: inout Tile) {
        let markers = classes.markers(target.platform)
        let now = MeetingClock.now()
        if let path = markerPath, tile.hostPath != path {
            tile.hostPath = path
            tile.markerHost = element(at: path, in: tile.element)
        }
        if let host = tile.markerHost, now - tile.walkedAt < Self.fullTileWalkEvery {
            if let list: [String] = value(host, "AXDOMClassList", timeout: Self.readTimeout) {
                tile.isLit = list.contains(where: markers.contains)
                tile.readAt = MeetingClock.now()
                return
            }
            tile.markerHost = nil
        }
        guard let found = findMarker(in: tile.element, markers: markers) else {
            needsDiscovery = true
            return
        }
        // Cut short by an app that stopped answering: the tile keeps its last read until a later tick walks it.
        guard found.complete else { return }
        tile.isLit = found.path != nil
        tile.walkedAt = MeetingClock.now()
        tile.readAt = tile.walkedAt
        if let path = found.path {
            markerPath = path
            tile.markerHost = found.element
        }
    }

    private func webReading(_ b: Bound, tiles: [SpeakerTile], partial: Bool) -> SpeakerReading {
        if partial { return .unreadable(defaultSource, .partialCoverage) }
        guard target.platform == .teams else {
            return tiles.isEmpty && !b.tiles.isEmpty ? .unreadable(defaultSource, .readFailed) : SpeakerReading(source: defaultSource, tiles: tiles)
        }
        if tiles.contains(where: \.isLit) { return SpeakerReading(source: .teamsMain, tiles: tiles) }
        for monitor in b.compact {
            guard let label = text(of: monitor) else { continue }
            switch TeamsSpeakerText.resolveCompactLabel(label, knownNames: knownNames) {
            case .name(let name): return SpeakerReading(source: .teamsCompact, tiles: tiles, signal: .remote(name))
            case .selfSpeaking: return SpeakerReading(source: .teamsCompact, tiles: tiles, signal: .selfOnly)
            case .ambiguous, .unrecognized: return .unreadable(.teamsCompact, .labelUnrecognized)
            }
        }
        return tiles.isEmpty ? .unreadable(.teamsMain, .indicatorUnavailable) : SpeakerReading(source: .teamsMain, tiles: tiles)
    }

    /// The call monitor title's text: its own value, title or description, else its first static text child.
    private func text(of element: AXUIElement) -> String? {
        guard let v = values(element, [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute],
                             timeout: Self.readTimeout) else { return nil }
        if let own = v[0..<3].compactMap({ ($0 as? String).flatMap(SpeakerNames.clean) }).first { return own }
        for child in (v[3] as? [AXUIElement] ?? []).prefix(8) {
            if let t: String = value(child, kAXValueAttribute, timeout: Self.readTimeout), let c = SpeakerNames.clean(t) { return c }
        }
        return nil
    }

    // MARK: Accessibility I/O (on `queue` only)

    /// Breadth-first walk of a tile's top (Wispr Flow's bounds) for a speaking class, until the app stops answering.
    /// No time limit: the walk is bounded by `markerNodes`, and a slow but working app must still finish it, or
    /// its unlit tiles would never be read. nil when the tile can't be read; `complete` false when the walk was
    /// cut short; otherwise the child-index path to the first element carrying one (nil path: not lit).
    private func findMarker(in tile: AXUIElement, markers: [String]) -> (path: [Int]?, element: AXUIElement?, complete: Bool)? {
        var queue: [(AXUIElement, [Int])] = [(tile, [])]
        var i = 0
        while i < queue.count, i < SpeakerTileRules.markerNodes {
            if i > 0, tickTimeouts >= Self.busyAfterTimeouts { return (nil, nil, false) }
            let (element, path) = queue[i]
            i += 1
            guard let v = values(element, ["AXDOMClassList", kAXChildrenAttribute], timeout: Self.readTimeout) else {
                if i == 1 { return nil }
                continue
            }
            if (v[0] as? [String] ?? []).contains(where: markers.contains) { return (path, element, true) }
            if path.count < SpeakerTileRules.markerDepth, let kids = v[1] as? [AXUIElement] {
                queue += kids.enumerated().map { ($0.element, path + [$0.offset]) }
            }
        }
        return (nil, nil, true)
    }

    /// The element at a child-index path below `root`.
    private func element(at path: [Int], in root: AXUIElement) -> AXUIElement? {
        var current = root
        for index in path {
            guard let kids: [AXUIElement] = value(current, kAXChildrenAttribute, timeout: Self.readTimeout),
                  kids.indices.contains(index) else { return nil }
            current = kids[index]
        }
        return current
    }

    /// Breadth-first walk below `root`, reading `attributes` (plus children) of each element in one message.
    /// `visit` returns whether to go below the element. Stops at `maxDepth`, `maxNodes`, `deadline`, or when the
    /// app stops answering.
    private func walk(_ root: AXUIElement, attributes: [String], maxDepth: Int, maxNodes: Int,
                      deadline: TimeInterval, visit: (AXUIElement, [Any?]) -> Bool) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var i = 0
        let attrs = attributes + [kAXChildrenAttribute]
        while i < queue.count, i < maxNodes, MeetingClock.now() < deadline, tickTimeouts < Self.busyAfterTimeouts {
            let (element, depth) = queue[i]
            i += 1
            guard let v = values(element, attrs, timeout: Self.readTimeout) else { continue }
            guard visit(element, Array(v.dropLast())), depth < maxDepth, let kids = v.last as? [AXUIElement] else { continue }
            queue += kids.map { ($0, depth + 1) }
        }
    }

    /// The subtree below `root` as snapshots (breadth-first within the bounds); nil when `root` can't be read.
    private func snapshot(_ root: AXUIElement, attributes: [String], maxDepth: Int, maxNodes: Int,
                          deadline: TimeInterval) -> AXNodeSnapshot? {
        var flat: [(node: AXNodeSnapshot, parent: Int?)] = []
        var queue: [(AXUIElement, Int, Int?)] = [(root, 0, nil)]
        var i = 0
        let attrs = attributes + [kAXChildrenAttribute]
        while i < queue.count, flat.count < maxNodes, MeetingClock.now() < deadline {
            let (element, depth, parent) = queue[i]
            i += 1
            guard let v = values(element, attrs, timeout: Self.readTimeout) else {
                if flat.isEmpty { return nil }
                continue
            }
            var node = AXNodeSnapshot()
            for (name, raw) in zip(attributes, v) {
                switch name {
                case kAXRoleAttribute: node.role = raw as? String
                case kAXTitleAttribute: node.title = raw as? String
                case kAXValueAttribute: node.value = raw as? String
                case kAXDescriptionAttribute: node.description = raw as? String
                case "AXDOMIdentifier": node.domIdentifier = raw as? String
                case "AXDOMClassList": node.domClasses = raw as? [String] ?? []
                default: break
                }
            }
            flat.append((node, parent))
            if depth < maxDepth, let kids = v.last as? [AXUIElement] {
                let me = flat.count - 1
                queue += kids.map { ($0, depth + 1, me) }
            }
        }
        guard !flat.isEmpty else { return nil }
        var nodes = flat.map(\.node)
        for idx in stride(from: nodes.count - 1, through: 1, by: -1) {
            if let p = flat[idx].parent { nodes[p].children.insert(nodes[idx], at: 0) }
        }
        return nodes[0]
    }

    /// Several attributes in one message; nil when the element didn't answer. Missing values come back as nil.
    private func values(_ element: AXUIElement, _ attributes: [String], timeout: Float) -> [Any?]? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var raw: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(), &raw)
        note(error)
        guard error == .success, let array = raw as? [Any], array.count == attributes.count else { return nil }
        // Errors come back as AXValue(kAXValueAXErrorType); the casts callers make simply fail for them.
        return array.map { $0 is NSNull ? nil : $0 }
    }

    private func value<T>(_ element: AXUIElement, _ attribute: String, timeout: Float) -> T? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        note(error)
        guard error == .success, let raw else { return nil }
        return raw as? T
    }

    /// Timeouts mean a busy app; an element that went away means the tiles must be found again.
    private func note(_ error: AXError) {
        switch error {
        case .cannotComplete: tickTimeouts += 1
        case .invalidUIElement: needsDiscovery = true
        default: break
        }
    }

    static func frame(position: Any?, size: Any?) -> CGRect? {
        guard let p = position, let s = size, CFGetTypeID(p as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(s as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
}
