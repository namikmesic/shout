import AppKit
import SwiftUI

/// A native macOS stepped slider (tick marks, snaps to stops) with a label centred under each tick.
/// Labels are positioned from the slider's own tick geometry, so they line up exactly; clicking a
/// label jumps to that stop, and each snap gives a light haptic tick on Force Touch trackpads.
struct SteppedSlider: NSViewRepresentable {
    let labels: [String]
    @Binding var index: Int

    func makeNSView(context: Context) -> SteppedSliderView {
        let view = SteppedSliderView(labels: labels)
        view.onChange = { i in index = i }
        view.select(index, animated: false)
        return view
    }

    func updateNSView(_ view: SteppedSliderView, context: Context) {
        view.onChange = { i in index = i }
        view.setLabels(labels)
        view.select(index, animated: false)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SteppedSliderView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: SteppedSliderView.height)
    }
}

final class SteppedSliderView: NSView {
    static let height: CGFloat = 46
    private static let sliderHeight: CGFloat = 26

    var onChange: ((Int) -> Void)?
    private let slider = NSSlider()
    private var labelFields: [NSTextField] = []
    private var current = 0

    init(labels: [String]) {
        super.init(frame: .zero)
        slider.minValue = 0
        slider.isContinuous = true
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.controlSize = .regular
        slider.target = self
        slider.action = #selector(sliderChanged)
        addSubview(slider)
        setLabels(labels)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    override var isFlipped: Bool { true }

    func setLabels(_ labels: [String]) {
        guard labels != labelFields.map(\.stringValue) else { return }
        labelFields.forEach { $0.removeFromSuperview() }
        labelFields = labels.enumerated().map { i, text in
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 11)
            field.alignment = .center
            field.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(labelClicked(_:))))
            field.tag = i
            addSubview(field)
            return field
        }
        slider.maxValue = Double(max(1, labels.count - 1))
        slider.numberOfTickMarks = labels.count
        styleLabels()
        needsLayout = true
    }

    func select(_ index: Int, animated: Bool) {
        let i = max(0, min(labelFields.count - 1, index))
        current = i
        if Int(slider.doubleValue.rounded()) != i {
            if animated { slider.animator().doubleValue = Double(i) } else { slider.doubleValue = Double(i) }
        }
        styleLabels()
    }

    override func layout() {
        super.layout()
        slider.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.sliderHeight)
        for (i, field) in labelFields.enumerated() {
            let tick = slider.rectOfTickMark(at: i)
            let tickCenter = convert(NSPoint(x: tick.midX, y: 0), from: slider).x
            // Measure with the semibold face (the widest state) plus slack, so text never clips.
            let width = ceil((field.stringValue as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width) + 6
            let height = ceil(field.intrinsicContentSize.height)
            var x = (tickCenter - width / 2).rounded()
            x = max(-3, min(bounds.width - width + 3, x)) // end labels stay inside, text aligned with the track ends
            field.frame = NSRect(x: x, y: Self.sliderHeight + 3, width: width, height: height)
        }
    }

    private func styleLabels() {
        for (i, field) in labelFields.enumerated() {
            let selected = i == current
            field.font = .systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
            field.textColor = selected ? .labelColor : .secondaryLabelColor
        }
    }

    @objc private func sliderChanged() {
        // The range is at least 0...1, so with a single label a drag can land on a stop that has none.
        guard !labelFields.isEmpty else { return }
        let i = max(0, min(labelFields.count - 1, Int(slider.doubleValue.rounded())))
        guard i != current else { return }
        current = i
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        styleLabels()
        onChange?(i)
    }

    @objc private func labelClicked(_ g: NSClickGestureRecognizer) {
        guard let i = g.view?.tag, i != current else { return }
        select(i, animated: true)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        onChange?(i)
    }
}
