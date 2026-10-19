import AppKit
import SwiftUI
import Combine

// MARK: - Model

@MainActor
final class FlowBarModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening(handsFree: Bool, command: Bool)
        case processing(command: Bool)
        case success
        case message(String, kind: MessageKind, actionTitle: String?)
    }
    enum MessageKind: Equatable { case info, success, warning, error }

    @Published var phase: Phase = .idle
    @Published var hovering = false
    @Published var showWhenIdle = true
    @Published var hiddenUntil: Date?
    @Published var hint = "Hold fn to dictate"
    @Published var listeningSince = Date()
    /// The app a running dictation goes back to, while the user is in another one.
    struct Target: Equatable { var appName: String; var bundleID: String? }
    @Published var awayTarget: Target?
    /// Screenshots taken so far in a Prompt mode session.
    @Published var captureCount = 0

    /// A meeting is being recorded: the resting pill becomes a recording indicator that stays visible
    /// even when the idle pill is hidden.
    struct MeetingPill: Equatable { var startedAt: Date }
    @Published var meeting: MeetingPill? { didSet { scheduleHourRelayout() } }
    /// The clock ticks inside its own TimelineView, so nothing re-lays out the pill when "59:59" becomes
    /// "1:00:00". One invalidation at the hour widens it.
    private var hourRelayout: Timer?
    /// Read every animation frame by the meeting meter (0…1).
    var meetingLevel: (() -> Float)?
    var onMeetingStop: (() -> Void)?
    var onMeetingOpen: (() -> Void)?

    /// A card above the pill: a detected call, a calendar reminder, "Scribe stopping", Resume.
    @Published var card: FlowCard?
    /// The pointer is clearly away from the card with this id (called 30 times a second while it is). The
    /// panel ignores the mouse there, so SwiftUI may never report the hover's end.
    var onPointerOutsideCard: ((UUID) -> Void)?

    private func scheduleHourRelayout() {
        hourRelayout?.invalidate()
        hourRelayout = nil
        guard let start = meeting?.startedAt else { return }
        let delay = start.addingTimeInterval(3600).timeIntervalSinceNow
        guard delay > 0 else { return }
        let timer = Timer(timeInterval: delay + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        // Common modes: also fires while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        hourRelayout = timer
    }

    /// Latest microphone level (0...1). Deliberately not @Published: the waveform reads it on every
    /// animation frame, so level updates never invalidate the SwiftUI tree.
    var level: Float = 0

    var onClick: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var onMessageAction: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    func push(level: Float) { self.level = level }
    func resetLevels() { level = 0 }

    var isHiddenNow: Bool {
        if let until = hiddenUntil, until > Date() { return true }
        return false
    }

    /// The resting pill is hidden (setting off, or "hide for 1 hour"). Never while recording a meeting.
    var idleHidden: Bool { phase == .idle && meeting == nil && (!showWhenIdle || isHiddenNow) }
}

// MARK: - Metrics

/// Every size in one place so the view and the click-through hit testing always agree.
enum FlowBarMetrics {
    static let panelSize = NSSize(width: 520, height: 210)
    static let cardSize = CGSize(width: 440, height: 66)

    /// A card's height: taller for a three-line explanation and for a row of choices.
    static func cardHeight(_ card: FlowCard) -> CGFloat {
        cardSize.height + (card.subtitleLines > 2 ? 14 : 0) + (card.choices.isEmpty ? 0 : 36)
    }
    static let cardGap: CGFloat = 10
    /// Distance from the panel's bottom edge to the pill (leaves room for the shadow).
    static let bottomInset: CGFloat = 20
    /// Gap between the pill and the top of the Dock / bottom of the screen.
    static let dockGap: CGFloat = 14

    static let resting = CGSize(width: 40, height: 8)
    static let height: CGFloat = 30
    static let barCount = 13
    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 2.25
    static let barsHeight: CGFloat = 16
    static let buttonSize: CGFloat = 20
    static var barsWidth: CGFloat { CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap }

    static let meetingBarCount = 5
    static var meetingBarsWidth: CGFloat { CGFloat(meetingBarCount) * barWidth + CGFloat(meetingBarCount - 1) * barGap }
    static let meetingTimeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    static let messageFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let maxMessageWidth: CGFloat = 440

    static func textWidth(_ s: String, font: NSFont = messageFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Room for the target app's icon (`FlowBarModel.awayTarget`).
    static let targetWidth: CGFloat = 22

    /// Room for the screenshot count ("📷 2").
    static func captureWidth(_ n: Int) -> CGFloat {
        n > 0 ? textWidth("\(n)", font: .systemFont(ofSize: 11, weight: .semibold)) + 21 : 0
    }

    static func size(for phase: FlowBarModel.Phase, hovering: Bool, hint: String,
                     meeting: FlowBarModel.MeetingPill? = nil, away: Bool = false, captures: Int = 0) -> CGSize {
        let extra = (away ? targetWidth : 0) + captureWidth(captures)
        switch phase {
        case .idle:
            if let meeting { return meetingSize(meeting) }
            return hovering ? CGSize(width: textWidth(hint) + 46, height: height) : resting
        case .listening(let handsFree, _):
            // [×] bars [■]  vs. just the bars.
            return handsFree ? CGSize(width: barsWidth + 2 * buttonSize + 32 + extra, height: height)
                             : CGSize(width: barsWidth + 26 + extra, height: height)
        case .processing:
            return CGSize(width: barsWidth + 26 + extra, height: height)
        case .success:
            return CGSize(width: 46, height: height)
        case .message(let text, _, let action):
            let actionWidth = action.map { textWidth($0, font: .systemFont(ofSize: 11.5, weight: .semibold)) + 28 } ?? 0
            let natural = textWidth(text) + 50 + actionWidth
            if natural <= maxMessageWidth { return CGSize(width: max(110, natural), height: height) }
            return CGSize(width: maxMessageWidth, height: 50)
        }
    }

    /// [●  12:04  ▂▅▃  ■]: recording dot, elapsed time, meter, stop.
    static func meetingSize(_ m: FlowBarModel.MeetingPill, now: Date = Date()) -> CGSize {
        let sample = now.timeIntervalSince(m.startedAt) >= 3600 ? "0:00:00" : "00:00"
        let width = 12 + 8 + 7 + textWidth(sample, font: meetingTimeFont) + 10 + meetingBarsWidth + 10 + buttonSize + 5
        return CGSize(width: ceil(width), height: height)
    }

    static func cornerRadius(for size: CGSize) -> CGFloat { min(size.height / 2, 18) }
}

// MARK: - View

struct FlowBarView: View {
    @ObservedObject var model: FlowBarModel
    @Environment(\.displayScale) private var displayScale

    /// Quick and settled, no visible overshoot: the pill should feel instant, not bouncy.
    private static let morph = Animation.spring(response: 0.3, dampingFraction: 0.86)

    var body: some View {
        let size = FlowBarMetrics.size(for: model.phase, hovering: model.hovering, hint: model.hint, meeting: model.meeting,
                                       away: model.awayTarget != nil, captures: model.captureCount)
        let radius = FlowBarMetrics.cornerRadius(for: size)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let card = model.card {
                FlowCardView(card: card)
                    .frame(width: FlowBarMetrics.cardSize.width, height: FlowBarMetrics.cardHeight(card))
                    .padding(.bottom, FlowBarMetrics.cardGap)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(card.id)
            }
            ZStack {
                content
                    .id(contentKey)
                    .transition(.blurReplace)
            }
            .frame(width: size.width, height: size.height)
            .background(PillBackground(shape: shape, command: isCommand, resting: isResting, hairline: 1 / max(displayScale, 1)))
            .clipShape(shape)
            .overlay { if isCommand { IntelligenceGlow(shape: shape) } }
            .contentShape(shape)
            .onTapGesture {
                if model.phase == .idle && model.meeting != nil { model.onMeetingOpen?() }
                else if model.phase == .idle && model.hovering { model.onClick?() }
            }
            .scaleEffect(model.idleHidden ? 0.6 : 1, anchor: .bottom)
            .opacity(model.idleHidden ? 0 : (isResting ? 0.85 : 1))
            .padding(.bottom, FlowBarMetrics.bottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Self.morph, value: model.phase)
        .animation(Self.morph, value: model.hovering)
        .animation(Self.morph, value: model.meeting)
        .animation(Self.morph, value: model.card)
        .animation(Self.morph, value: model.awayTarget)
        .animation(Self.morph, value: model.captureCount)
        .animation(.easeOut(duration: 0.2), value: model.idleHidden)
    }

    private var isCommand: Bool {
        switch model.phase {
        case .listening(_, let c), .processing(let c): return c
        default: return false
        }
    }

    /// The app the text goes back to, while the user is in another one.
    @ViewBuilder private var targetIcon: some View {
        if let target = model.awayTarget {
            AppIconView(bundleID: target.bundleID, size: 16)
                .help("Goes to \(target.appName)")
                .transition(.scale.combined(with: .opacity))
        }
        if model.captureCount > 0 {
            HStack(spacing: 2) {
                Image(systemName: "camera.fill").font(.system(size: 9, weight: .semibold))
                Text("\(model.captureCount)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(.white.opacity(0.88))
            .help("Screenshots in this prompt")
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var isResting: Bool { model.phase == .idle && !model.hovering && model.meeting == nil }

    /// Content identity: changes trigger the blur-replace transition. Listening and processing share
    /// one identity so the bars calm down continuously instead of being swapped out.
    private var contentKey: String {
        switch model.phase {
        case .idle: return model.meeting != nil ? "meeting" : (model.hovering ? "hint" : "rest")
        case .listening(let handsFree, _): return handsFree ? "handsfree" : "bars"
        case .processing: return "bars"
        case .success: return "success"
        case .message(let t, _, let a): return "msg:\(t)\(a ?? "")"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            if let meeting = model.meeting {
                MeetingPillContent(model: model, meeting: meeting)
            } else if model.hovering {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    Text(model.hint).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                }
                .fixedSize()
            } else {
                Color.clear
            }

        case .listening(let handsFree, let command):
            if handsFree {
                HStack(spacing: 10) {
                    PillButton(symbol: "xmark", fill: .white.opacity(0.16), iconColor: .white.opacity(0.92), help: "Cancel (Esc)") { model.onCancel?() }
                    HStack(spacing: 6) {
                        targetIcon
                        LiveBars(model: model, thinking: false, command: command)
                            .frame(width: FlowBarMetrics.barsWidth, height: FlowBarMetrics.barsHeight)
                    }
                    PillButton(symbol: "stop.fill", fill: Color(red: 1, green: 0.27, blue: 0.23), iconColor: .white, iconSize: 7.5, help: "Finish and paste") { model.onFinish?() }
                }
                .padding(.horizontal, 5)
            } else {
                HStack(spacing: 6) {
                    targetIcon
                    LiveBars(model: model, thinking: false, command: command)
                        .frame(width: FlowBarMetrics.barsWidth, height: FlowBarMetrics.barsHeight)
                }
            }

        case .processing(let command):
            HStack(spacing: 6) {
                targetIcon
                LiveBars(model: model, thinking: true, command: command)
                    .frame(width: FlowBarMetrics.barsWidth, height: FlowBarMetrics.barsHeight)
            }

        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)

        case .message(let text, let kind, let action):
            HStack(spacing: 7) {
                Image(systemName: symbol(kind))
                    .symbolRenderingMode(.palette)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(kind == .warning ? Color.black.opacity(0.85) : .white, tint(kind))
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action: { model.onMessageAction?() }) {
                        Text(action)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 3.5)
                            .background(Capsule().fill(.white.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private func symbol(_ k: FlowBarModel.MessageKind) -> String {
        switch k {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func tint(_ k: FlowBarModel.MessageKind) -> Color {
        switch k {
        case .info: Color(red: 0.25, green: 0.55, blue: 1.0)
        case .success: Color(red: 0.2, green: 0.78, blue: 0.4)
        case .warning: Color(red: 1, green: 0.8, blue: 0.2)
        case .error: Color(red: 1, green: 0.36, blue: 0.33)
        }
    }
}

/// Recording indicator: a softly pulsing red dot, elapsed time, a small meter and a stop button.
private struct MeetingPillContent: View {
    @ObservedObject var model: FlowBarModel
    let meeting: FlowBarModel.MeetingPill

    var body: some View {
        HStack(spacing: 0) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                let pulse = 0.5 + 0.5 * cos(tl.date.timeIntervalSinceReferenceDate * .pi / 1.1)
                Circle()
                    .fill(Color(red: 1, green: 0.27, blue: 0.23))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().fill(Color(red: 1, green: 0.27, blue: 0.23).opacity(0.35 * pulse)).frame(width: 14, height: 14))
            }
            .frame(width: 8, height: 14)
            .padding(.leading, 12)
            TimelineView(.periodic(from: meeting.startedAt, by: 1)) { tl in
                Text(Self.clock(tl.date.timeIntervalSince(meeting.startedAt)))
                    .font(Font(FlowBarMetrics.meetingTimeFont))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize()
            }
            .padding(.leading, 7)
            Spacer(minLength: 10)
            LiveBars(model: model, thinking: false, command: false, meeting: true)
                .frame(width: FlowBarMetrics.meetingBarsWidth, height: FlowBarMetrics.barsHeight)
            PillButton(symbol: "stop.fill", fill: Color(red: 1, green: 0.27, blue: 0.23), iconColor: .white, iconSize: 7.5,
                       help: "Stop Scribe") { model.onMeetingStop?() }
                .padding(.leading, 10)
                .padding(.trailing, 5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scribe is recording")
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Near-black glass pill: dark fill, faint top sheen, hairline edge and a two-layer shadow.
private struct PillBackground: View {
    let shape: RoundedRectangle
    let command: Bool
    let resting: Bool
    let hairline: CGFloat

    var body: some View {
        ZStack {
            // The resting pill is a touch lighter so it stays visible on dark wallpapers.
            shape.fill(resting ? Color(white: 0.16).opacity(0.92) : Color(red: 0.047, green: 0.047, blue: 0.058).opacity(0.97))
            shape.fill(LinearGradient(colors: [.white.opacity(resting ? 0.06 : 0.075), .white.opacity(0)],
                                      startPoint: .top, endPoint: .center))
        }
        .overlay(shape.strokeBorder(.white.opacity(command ? 0 : (resting ? 0.28 : 0.14)), lineWidth: hairline))
        .compositingGroup()
        .shadow(color: .black.opacity(resting ? 0.18 : 0.32), radius: resting ? 4 : 12, y: resting ? 1 : 5)
        .shadow(color: .black.opacity(0.22), radius: 0.8, y: 0.5)
    }
}

/// Apple Intelligence–style rotating gradient edge for Command Mode.
private struct IntelligenceGlow: View {
    let shape: RoundedRectangle
    private static let colors: [Color] = [
        Color(red: 0.68, green: 0.45, blue: 1.0), Color(red: 0.35, green: 0.56, blue: 1.0),
        Color(red: 0.25, green: 0.85, blue: 0.95), Color(red: 1.0, green: 0.45, blue: 0.7),
        Color(red: 0.68, green: 0.45, blue: 1.0),
    ]

    var body: some View {
        TimelineView(.animation) { tl in
            let angle = Angle.degrees(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4 * 360)
            let gradient = AngularGradient(colors: Self.colors, center: .center, angle: angle)
            ZStack {
                shape.strokeBorder(gradient, lineWidth: 1.5)
                shape.strokeBorder(gradient, lineWidth: 3).blur(radius: 4).opacity(0.6)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Small circular control used in hands-free mode.
private struct PillButton: View {
    let symbol: String
    let fill: Color
    let iconColor: Color
    var iconSize: CGFloat = 9
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: FlowBarMetrics.buttonSize, height: FlowBarMetrics.buttonSize)
                .background(Circle().fill(fill))
                .overlay(Circle().fill(.white.opacity(hover ? 0.12 : 0)))
        }
        .buttonStyle(.plain)
        .scaleEffect(hover ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Waveform

/// Audio-reactive bars drawn with Canvas at display refresh rate. Centre bars respond most, each bar
/// wobbles at its own rate, attack is fast and release slow. In "thinking" mode the bars settle low
/// and a soft highlight sweeps across them.
struct LiveBars: View {
    let model: FlowBarModel
    let thinking: Bool
    let command: Bool
    /// Meeting meter: fewer bars, fed by the Scribe's levels instead of the dictation microphone.
    var meeting = false
    @State private var animator: BarAnimator

    init(model: FlowBarModel, thinking: Bool, command: Bool, meeting: Bool = false) {
        self.model = model; self.thinking = thinking; self.command = command; self.meeting = meeting
        _animator = State(initialValue: BarAnimator(count: meeting ? FlowBarMetrics.meetingBarCount : FlowBarMetrics.barCount))
    }

    private static let commandColors: [(Double, Double, Double)] = [
        (0.72, 0.52, 1.0), (0.42, 0.62, 1.0), (0.36, 0.86, 0.96), (1.0, 0.52, 0.76),
    ]

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                animator.step(level: meeting ? (model.meetingLevel?() ?? 0) : model.level, thinking: thinking, time: t)
                let n = animator.heights.count
                let w = FlowBarMetrics.barWidth, gap = FlowBarMetrics.barGap
                let total = CGFloat(n) * w + CGFloat(n - 1) * gap
                var x = (size.width - total) / 2
                for i in 0..<n {
                    let h = min(size.height, max(3, animator.heights[i] * size.height))
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: w, height: h)
                    let path = Path(roundedRect: rect, cornerRadius: w / 2)
                    let alpha = animator.alphas[i]
                    let color = command ? Self.gradientColor(Double(i) / Double(n - 1)) : .white
                    ctx.fill(path, with: .color(color.opacity(alpha)))
                    x += w + gap
                }
            }
        }
    }

    private static func gradientColor(_ p: Double) -> Color {
        let c = commandColors
        let scaled = p * Double(c.count - 1)
        let i = min(c.count - 2, Int(scaled))
        let f = scaled - Double(i)
        let a = c[i], b = c[i + 1]
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }
}

final class BarAnimator {
    private(set) var heights: [CGFloat]
    private(set) var alphas: [Double]
    private let rates: [Double]
    private let phases: [Double]
    private var lastTime: Double?
    private var smoothedLevel: Double = 0

    init(count: Int) {
        heights = Array(repeating: 0, count: count)
        alphas = Array(repeating: 0.95, count: count)
        // Deterministic per-bar variation.
        rates = (0..<count).map { 4.2 + 2.6 * abs(sin(Double($0) * 12.9898)) }
        phases = (0..<count).map { 6.283 * abs(sin(Double($0) * 78.233)) }
    }

    func step(level: Float, thinking: Bool, time t: Double) {
        let dt = min(0.05, max(0.001, t - (lastTime ?? t - 1.0 / 60)))
        lastTime = t
        // Noise gate + gentle curve so quiet rooms look calm and speech looks lively.
        var l = Double(level)
        l = l < 0.04 ? 0 : min(1, pow((l - 0.04) / 0.96, 0.85) * 1.1)
        smoothedLevel += (l - smoothedLevel) * (1 - exp(-dt * (l > smoothedLevel ? 30 : 8)))
        let n = heights.count
        let sweep = sin(t * 2.2) * 1.15
        for i in 0..<n {
            let x = Double(i) / Double(n - 1) * 2 - 1           // -1 … 1
            let envelope = 0.3 + 0.7 * exp(-pow(x / 0.62, 2))     // centre-weighted
            let target: Double
            if thinking {
                target = 0.2
                let d = abs(x - sweep)
                alphas[i] = 0.28 + 0.72 * pow(max(0, cos(min(d * 2.0, .pi / 2))), 3)
            } else {
                // A soft ripple keeps the bars alive in silence; speech lifts the centre most.
                let wobble = 0.7 + 0.3 * sin(t * rates[i] + phases[i])
                let ripple = 0.04 * (1 + sin(t * 5.5 - x * 2.4))
                target = 0.2 + ripple + 0.8 * smoothedLevel * envelope * wobble
                alphas[i] += (0.95 - alphas[i]) * min(1, dt * 10)
            }
            let current = Double(heights[i])
            let k = target > current ? 26.0 : 9.0
            heights[i] = CGFloat(current + (target - current) * (1 - exp(-dt * k)))
        }
    }
}

// MARK: - Panel controller

/// Hosts the Flow Bar in a fixed-size, transparent, non-activating panel above all apps and Spaces.
/// The panel never resizes (SwiftUI morphs the pill inside it) and it ignores the mouse everywhere
/// except over the pill.
@MainActor
final class FlowBarController {
    let model = FlowBarModel()
    private let panel: NSPanel
    private var cancellables: Set<AnyCancellable> = []
    private var messageTimer: Timer?
    private var pointerTimer: Timer?
    private var hoverEnterSince: Date?
    private var hoverExitSince: Date?

    init() {
        panel = FlowBarPanel(contentRect: NSRect(origin: .zero, size: FlowBarMetrics.panelSize),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        let host = FlowBarHostingView(rootView: FlowBarView(model: model))
        host.sizingOptions = []
        host.onRightClick = { [weak self] e in self?.model.onRightClick?(e) }
        panel.contentView = host

        reposition(to: screenUnderPointer())
        panel.orderFrontRegardless()

        model.$phase
            .removeDuplicates()
            .scan((FlowBarModel.Phase.idle, FlowBarModel.Phase.idle)) { ($0.1, $1) }
            .sink { [weak self] pair in self?.phaseChanged(from: pair.0, to: pair.1) }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout(animated: false) }
        }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        pointerTimer = t
    }

    func show(_ phase: FlowBarModel.Phase) {
        messageTimer?.invalidate()
        if case .listening = phase, !isListening(model.phase) { model.listeningSince = Date() }
        model.phase = phase
    }

    func flash(_ text: String, kind: FlowBarModel.MessageKind = .info, action: String? = nil, seconds: Double = 2.5,
               onAction: (() -> Void)? = nil) {
        model.onMessageAction = onAction
        show(.message(text, kind: kind, actionTitle: action))
        scheduleReturnToIdle(after: seconds) { if case .message = $0 { return true }; return false }
    }

    /// Brief checkmark after a successful paste.
    func success() {
        show(.success)
        scheduleReturnToIdle(after: 0.7) { $0 == .success }
    }

    /// Keeps the Flow Bar out of screenshots and screen sharing.
    func setHiddenFromCapture(_ hidden: Bool) {
        panel.sharingType = hidden ? .none : .readOnly
    }

    /// Re-applies placement and visibility (after settings or display changes).
    func layout(animated: Bool) {
        reposition(to: panel.screen ?? screenUnderPointer())
        if !panel.isVisible { panel.orderFrontRegardless() }
        model.objectWillChange.send()
    }

    // MARK: Internals

    private func isListening(_ p: FlowBarModel.Phase) -> Bool { if case .listening = p { return true }; return false }

    private func scheduleReturnToIdle(after seconds: Double, if matches: @escaping (FlowBarModel.Phase) -> Bool) {
        messageTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, matches(self.model.phase) else { return }
                self.model.phase = .idle
            }
        }
        // Common modes: a message still goes away on time while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        messageTimer = timer
    }

    private func phaseChanged(from old: FlowBarModel.Phase, to new: FlowBarModel.Phase) {
        // A new dictation appears on the display the user is working on.
        if old == .idle && new != .idle {
            let screen = screenUnderPointer()
            if screen != panel.screen { reposition(to: screen) }
        }
        if new != .idle && model.hovering { model.hovering = false }
        hoverEnterSince = nil; hoverExitSince = nil
    }

    private func screenUnderPointer() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }

    private func reposition(to screen: NSScreen?) {
        guard let vf = screen?.visibleFrame else { return }
        let size = FlowBarMetrics.panelSize
        let origin = NSPoint(x: (vf.midX - size.width / 2).rounded(),
                             y: vf.minY + FlowBarMetrics.dockGap - FlowBarMetrics.bottomInset)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func cardRect() -> NSRect? {
        guard let card = model.card else { return nil }
        let pill = FlowBarMetrics.size(for: model.phase, hovering: model.hovering, hint: model.hint, meeting: model.meeting,
                                       away: model.awayTarget != nil, captures: model.captureCount)
        let s = CGSize(width: FlowBarMetrics.cardSize.width, height: FlowBarMetrics.cardHeight(card))
        // The (possibly invisible) pill still takes its height in the layout below the card.
        let y = panel.frame.minY + FlowBarMetrics.bottomInset + pill.height + FlowBarMetrics.cardGap
        return NSRect(x: panel.frame.midX - s.width / 2, y: y, width: s.width, height: s.height)
    }

    private func pillRect(_ size: CGSize) -> NSRect {
        NSRect(x: panel.frame.midX - size.width / 2, y: panel.frame.minY + FlowBarMetrics.bottomInset,
               width: size.width, height: size.height)
    }

    /// 30 Hz: decides click-through and drives the idle hover state with hysteresis.
    private func tick() {
        let p = NSEvent.mouseLocation
        let current = FlowBarMetrics.size(for: model.phase, hovering: model.hovering, hint: model.hint, meeting: model.meeting,
                                       away: model.awayTarget != nil, captures: model.captureCount)
        let overCard = cardRect()?.insetBy(dx: -6, dy: -6).contains(p) ?? false
        let overPill = (!model.idleHidden && pillRect(current).insetBy(dx: -4, dy: -4).contains(p)) || overCard
        if panel.ignoresMouseEvents == overPill { panel.ignoresMouseEvents = !overPill }
        // Off the card, where the card doesn't take the mouse: a hover whose end SwiftUI didn't see (a fast
        // flick out, the panel turning click-through first) is ended here.
        if let id = model.card?.id, !overCard { model.onPointerOutsideCard?(id) }

        guard model.phase == .idle, !model.idleHidden, model.meeting == nil else {
            if model.hovering { model.hovering = false }
            return
        }
        let now = Date()
        if model.hovering {
            let expanded = pillRect(FlowBarMetrics.size(for: .idle, hovering: true, hint: model.hint))
            if expanded.insetBy(dx: -6, dy: -6).contains(p) { hoverExitSince = nil; return }
            if let since = hoverExitSince {
                if now.timeIntervalSince(since) > 0.15 { hoverExitSince = nil; model.hovering = false }
            } else { hoverExitSince = now }
        } else {
            guard pillRect(FlowBarMetrics.resting).insetBy(dx: -4, dy: -5).contains(p) else { hoverEnterSince = nil; return }
            if let since = hoverEnterSince {
                if now.timeIntervalSince(since) > 0.08 { hoverEnterSince = nil; model.hovering = true }
            } else { hoverEnterSince = now }
        }
    }
}

final class FlowBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FlowBarHostingView: NSHostingView<FlowBarView> {
    var onRightClick: ((NSEvent) -> Void)?
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Cards

/// A prompt shown above the Flow Bar.
struct FlowCard: Equatable, Identifiable {
    enum Kind: Equatable {
        case detected, reminder, stopping, resume, info
        /// Needs an answer now ("Started by mistake?", "Couldn't start recording"); takes the slot from any card.
        case alert
    }
    let id = UUID()
    var kind: Kind
    var title: String
    var subtitle: String?
    /// App icon to show (bundle identifier), else an SF Symbol.
    var bundleID: String?
    var symbol = "waveform"
    var primary: String
    var secondary: String?
    /// Extra actions in a "⌄" menu (e.g. Snooze for 2 min).
    var menu: [String] = []
    /// When the card acts on its own (auto-start, auto-stop) or goes away; drawn as a progress line.
    var deadline: Date?
    var startedAt = Date()
    /// Menu items drawn with a checkmark (a setting that is on).
    var checkedMenu: Set<String> = []
    /// Ticking text after the subtitle while the deadline runs; "%d" becomes the seconds left ("starting in %d s").
    var countdownText: String?
    /// A m:ss tile counting down to this moment, in place of the icon (the maximum-length warning).
    var tileDeadline: Date?
    /// Up to this many subtitle lines (three make the card taller).
    var subtitleLines = 2
    /// Options shown as capsules under the text, `selectedChoice` highlighted (the auto-end picker).
    var choices: [String] = []
    var selectedChoice: String?
    /// Set while the pointer rests on the card: the countdown and progress line stand still.
    var pausedAt: Date?
    var onPrimary: () -> Void = {}
    var onSecondary: () -> Void = {}
    var onMenu: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    /// Runs when the deadline passes (auto-start, auto-stop); nil just removes the card.
    var onTimeout: (() -> Void)?
    /// Another card took the slot before this one was answered.
    var onSuperseded: (() -> Void)?
    /// The ⌄ menu is about to open.
    var onMenuOpen: () -> Void = {}
    var onChoice: (String) -> Void = { _ in }
    /// The pointer entered (true) or left the card.
    var onHover: (Bool) -> Void = { _ in }

    /// Which card keeps the single slot: a reminder gives way to anything, an alert to nothing.
    var priority: Int {
        switch kind {
        case .reminder: 0
        case .info: 1
        case .detected: 2
        case .resume: 3
        case .stopping: 4
        case .alert: 5
        }
    }

    static func == (a: FlowCard, b: FlowCard) -> Bool {
        a.id == b.id && a.kind == b.kind && a.title == b.title && a.subtitle == b.subtitle && a.deadline == b.deadline
            && a.primary == b.primary && a.secondary == b.secondary && a.menu == b.menu && a.checkedMenu == b.checkedMenu
            && a.countdownText == b.countdownText && a.selectedChoice == b.selectedChoice && a.pausedAt == b.pausedAt
    }
}

struct FlowCardView: View {
    let card: FlowCard
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(card.subtitle == nil ? 2 : 1).truncationMode(.tail)
                    if card.subtitle != nil || card.countdownText != nil { subtitle }
                }
                Spacer(minLength: 6)
                if let secondary = card.secondary {
                    Button(action: card.onSecondary) {
                        Text(secondary).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 0) {
                    Button(action: card.onPrimary) {
                        Text(card.primary).font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                            .lineLimit(1).fixedSize()
                            .padding(.leading, 11).padding(.trailing, card.menu.isEmpty ? 11 : 7).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    if !card.menu.isEmpty {
                        Rectangle().fill(.black.opacity(0.15)).frame(width: 1, height: 16)
                        Button(action: openMenu) {
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                                .frame(width: 22, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("More options")
                    }
                }
                .background(Capsule().fill(.white))
            }
            if !card.choices.isEmpty { choiceRow.padding(.leading, 41) }
        }
        .padding(.leading, 12).padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.97)))
        .overlay(alignment: .bottom) { progress }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        .overlay(alignment: .topLeading) {
            if hover {
                Button(action: card.onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color(white: 0.3)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
                .help("Dismiss")
            }
        }
        .onHover { inside in
            hover = inside
            card.onHover(inside)
        }
    }

    /// Subtitle, followed by the seconds left while an auto-action counts down.
    @ViewBuilder private var subtitle: some View {
        if card.countdownText != nil && card.deadline != nil {
            TimelineView(.periodic(from: card.startedAt, by: 0.25)) { tl in
                let parts = subtitleParts(at: card.pausedAt ?? tl.date)
                // One line when it fits; otherwise break at the separator rather than mid-phrase.
                ViewThatFits(in: .horizontal) {
                    subtitleLabel(parts.joined(separator: " · ")).lineLimit(1).fixedSize()
                    subtitleLabel(parts.joined(separator: "\n"))
                }
            }
        } else {
            subtitleLabel(card.subtitle ?? "")
        }
    }

    private func subtitleLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
            .lineLimit(card.subtitleLines)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func subtitleParts(at now: Date) -> [String] {
        guard let format = card.countdownText, let deadline = card.deadline else { return [card.subtitle ?? ""] }
        let left = String(format: format, max(0, Int(deadline.timeIntervalSince(now).rounded(.up))))
        return [card.subtitle, left].compactMap { $0 }
    }

    private var choiceRow: some View {
        HStack(spacing: 6) {
            ForEach(card.choices, id: \.self) { choice in
                let selected = choice == card.selectedChoice
                Button { card.onChoice(choice) } label: {
                    Text(choice).font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .black : .white.opacity(0.85))
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(selected ? .white : .white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    /// The ⌄ menu as a native pop-up, so the card knows when it opens and can show checkmarks.
    private func openMenu() {
        card.onMenuOpen()
        let target = CardMenuTarget(card.onMenu)
        let menu = NSMenu()
        for title in card.menu {
            let item = NSMenuItem(title: title, action: #selector(CardMenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.state = card.checkedMenu.contains(title) ? .on : .off
            menu.addItem(item)
        }
        // Menu items hold their target weakly; `popUp` blocks until the menu closes.
        withExtendedLifetime(target) {
            _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @ViewBuilder private var icon: some View {
        if let end = card.tileDeadline {
            TimelineView(.periodic(from: card.startedAt, by: 1)) { tl in
                Text(Self.clock(end.timeIntervalSince(tl.date)))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                    .frame(width: 44, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.14)))
            }
        } else if let id = card.bundleID, NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
            AppIconView(bundleID: id, size: 30)
        } else {
            Image(systemName: card.symbol)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.14)))
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    @ViewBuilder private var progress: some View {
        if let deadline = card.deadline {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: card.pausedAt != nil)) { tl in
                let total = max(0.1, deadline.timeIntervalSince(card.startedAt))
                let left = max(0, min(1, deadline.timeIntervalSince(card.pausedAt ?? tl.date) / total))
                GeometryReader { g in
                    Rectangle().fill(card.kind == .stopping ? Color(red: 1, green: 0.36, blue: 0.33) : .white.opacity(0.5))
                        .frame(width: g.size.width * left, height: 2)
                }
                .frame(height: 2)
            }
        }
    }
}

/// Target of the card menu's items (NSMenu needs an object).
private final class CardMenuTarget: NSObject {
    private let action: (String) -> Void
    init(_ action: @escaping (String) -> Void) { self.action = action }
    @objc func pick(_ sender: NSMenuItem) { action(sender.title) }
}
