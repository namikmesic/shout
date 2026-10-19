import Foundation
import ImageIO
import CoreGraphics

/// A screenshot taken while the user described a prompt (docs/PROMPT_MODE.md, step 2).
public struct PromptCapture: Sendable, Equatable {
    public enum Source: String, Sendable {
        /// Taken by Shout (a tap of ⌥): the window under the mouse.
        case shout
        /// macOS's own screenshot, saved as a file.
        case screenshot
        /// An image put on the clipboard (⌃⌘⇧4, or a copied image).
        case clipboard
    }
    /// When it was taken, in seconds into the recording.
    public var time: Double
    public var path: String
    public var source: Source
    /// What was under the mouse, and in which window (Shout's own captures).
    public var detail: String?
    /// Where the picture was before Shout copied it next to the prompt (a macOS screenshot, a copied image file).
    public var original: String?
    /// Text that was selected when ⌥ was tapped: the picture boxes it, and the prompt quotes it.
    public var selection: String?
    /// Where the selection is: "/path/File.swift:12-18" in an editor (or just the file when the lines aren't known).
    public var location: String?

    public init(time: Double, path: String, source: Source, detail: String? = nil, original: String? = nil,
                selection: String? = nil, location: String? = nil) {
        self.time = time; self.path = path; self.source = source; self.detail = detail; self.original = original
        self.selection = selection; self.location = location
    }

    public func record(said: String) -> PromptCaptureRecord {
        PromptCaptureRecord(path: path, original: original, source: source.rawValue, time: time, said: said, detail: detail,
                            selection: selection, location: location)
    }
}

/// The transcript with "[screenshot N]" where each screenshot was taken, and the words around each.
public struct MarkedTranscript: Sendable, Equatable {
    public var text: String
    /// Per screenshot, in order: the last words before it and the first after it.
    public var anchors: [String]
}

/// Ties screenshots to the words said when they were taken. The speech engines give no word timings, so the
/// recording is split at each screenshot (at the nearest pause) and the parts are transcribed in order: a marker
/// then sits exactly between the words before and after it.
public enum PromptScreenshots {
    public static func marker(_ n: Int) -> String { "[screenshot \(n)]" }

    /// Where to split the recording for screenshots taken at `times` (seconds): each moment moved to the quietest
    /// 30 ms within `window` seconds, so no word is cut. Ascending; moments outside the recording are clamped.
    public static func splitPoints(samples: [Float], times: [Double], window: Double = 0.6,
                                   sampleRate: Int = AudioDSP.sampleRate) -> [Int] {
        let frame = 480
        let energies = AudioDSP.frameEnergies(samples, frame: frame)
        var points: [Int] = []
        for t in times.sorted() {
            let target = max(0, min(samples.count, Int(t * Double(sampleRate))))
            // At or past an end, it belongs there.
            if target == 0 || target == samples.count { points.append(max(points.last ?? 0, target)); continue }
            let lo = max(0, (target - Int(window * Double(sampleRate))) / frame)
            let hi = min(energies.count - 1, (target + Int(window * Double(sampleRate))) / frame)
            var best = target
            if lo <= hi {
                // The quietest frame; on a tie, the one closest to the moment.
                var bestFrame = lo
                for f in lo...hi where energies[f] < energies[bestFrame]
                    || (energies[f] == energies[bestFrame] && abs(f * frame - target) < abs(bestFrame * frame - target)) {
                    bestFrame = f
                }
                best = min(samples.count, bestFrame * frame + frame / 2)
            }
            points.append(max(points.last ?? 0, best))
        }
        return points
    }

    /// The parts' texts (one more than the screenshots) joined with a marker between each.
    public static func assemble(_ parts: [String]) -> MarkedTranscript {
        let clean = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var text = clean.first ?? ""
        var anchors: [String] = []
        for i in 1..<max(1, clean.count) {
            text = [text, marker(i), clean[i]].filter { !$0.isEmpty }.joined(separator: " ")
            let before = clean[..<i].joined(separator: " "), after = clean[i...].joined(separator: " ")
            anchors.append(anchor(before: before, after: after))
        }
        return MarkedTranscript(text: text, anchors: anchors)
    }

    /// "…the last words before, the first after…": what the user was saying when the screenshot was taken.
    static func anchor(before: String, after: String, wordsBefore: Int = 8, wordsAfter: Int = 4) -> String {
        // Word by word: whole-text clean-up would capitalize each piece's first word.
        let fillers: Set<String> = ["um", "uh", "er", "erm", "ah", "hmm", "mm", "uhm"]
        func words(_ s: String) -> [String] {
            s.split(whereSeparator: \.isWhitespace).map(String.init).filter {
                !fillers.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters))
            }
        }
        let b = words(before), a = words(after)
        let head = b.suffix(wordsBefore), tail = a.prefix(wordsAfter)
        guard !head.isEmpty || !tail.isEmpty else { return "" }
        var text = (head + tail).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
        // "…opens this text box. I think…" rather than ".…"
        if a.count > wordsAfter { text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) }
        return (b.count > wordsBefore ? "…" : "") + text + (a.count > wordsAfter ? "…" : "")
    }

    /// "[screenshot 2]", "(see screenshot 2)" and "(See Screenshot 2)" all become "(screenshot 2)".
    public static func normalizeReferences(_ text: String) -> String {
        text.replacingOccurrences(of: #"[\[(](?:see )?screenshot (\d+)[\])]"#, with: "(screenshot $1)",
                                  options: [.regularExpression, .caseInsensitive])
    }

    /// What was said around each marker in `spoken` (the words before it count most: that's what was being shown).
    static func contexts(in spoken: String, count: Int) -> [String] {
        let tokens = spoken.split(whereSeparator: \.isWhitespace).map(String.init)
        return (1...max(1, count)).prefix(count).map { n in
            // A marker is "[screenshot N]" or "(see screenshot N)": find the token holding "N]" or "N)".
            guard let at = tokens.indices.first(where: { i in
                tokens[i] == "\(n)]" || tokens[i] == "\(n))" || tokens[i].hasPrefix("\(n))") || tokens[i].hasPrefix("\(n)]")
            }) else { return "" }
            let before = tokens[max(0, at - 16)..<at].joined(separator: " ")
            let after = tokens[(at + 1)..<min(tokens.count, at + 7)].joined(separator: " ")
            return before + " " + after
        }
    }

    /// A screenshot the prompt doesn't mention gets "(screenshot N)" at the end of the sentence sharing the most words
    /// with what was said around it (at least two), so the picture stays tied to its part of the message. Headings,
    /// "Also consider" and "Open questions" are left alone.
    static func placeMissingReferences(_ prompt: String, contexts: [String]) -> String {
        var text = prompt
        for (k, context) in contexts.enumerated() {
            let ref = "(screenshot \(k + 1))"
            guard !text.contains(ref), !context.isEmpty else { continue }
            let want = contentWords(context)
            var best: (range: Range<String.Index>, score: Int)?
            var section = ""
            for lineRange in lineRanges(text) {
                let line = text[lineRange].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") { section = line.lowercased(); continue }
                if line.isEmpty || section.contains("also consider") || section.contains("open questions") { continue }
                text.enumerateSubstrings(in: lineRange, options: .bySentences) { sentence, range, _, _ in
                    guard let sentence else { return }
                    let score = contentWords(sentence).intersection(want).count
                    if score >= 2 && score > (best?.score ?? 0) { best = (range, score) }
                }
            }
            guard let best else { continue }
            // Before the sentence's closing punctuation: "…immediately (screenshot 1)."
            var end = best.range.upperBound
            while end > best.range.lowerBound, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
            if end > best.range.lowerBound, ".;:!?".contains(text[text.index(before: end)]) { end = text.index(before: end) }
            text.insert(contentsOf: " \(ref)", at: end)
        }
        return text
    }

    private static func lineRanges(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.byLines, .substringNotRequired]) { _, range, _, _ in ranges.append(range) }
        return ranges
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "these", "those", "when", "you", "your", "are", "was", "were", "its",
        "then", "there", "here", "have", "has", "had", "will", "should", "would", "could", "can", "not", "but", "from",
        "into", "they", "them", "what", "which", "about", "just", "like", "okay", "think", "want", "make", "also",
        "see", "screenshot", "one", "some", "all", "any", "out", "get", "got", "now", "right", "really", "thing",
        "things", "same", "both", "need", "needs", "let", "lets", "page", "click", "clicking", "clicked",
    ]

    private static func contentWords(_ s: String) -> Set<String> {
        Set(PromptBuilder.normalize(s).split(separator: " ").map(String.init).filter { $0.count >= 3 && !stopWords.contains($0) && Int($0) == nil })
    }

    /// The list Shout appends to the prompt (not the model, so paths can't be garbled): each file, and the words
    /// said when it was taken.
    public static func section(_ captures: [PromptCapture], anchors: [String]) -> String {
        guard !captures.isEmpty else { return "" }
        var lines = ["## Screenshots"]
        for (i, c) in captures.enumerated() {
            let number = "\(i + 1). "
            var line = number + "`\(c.path)`"
            let said = i < anchors.count ? anchors[i] : ""
            if !said.isEmpty { line += ": taken as I said “\(said)”" }
            if let selection = c.selection {
                // The selected text itself, so the assistant has it exactly.
                line += (said.isEmpty ? ": " : "; ") + "the selected text" + (c.location.map { " (`\($0)`)" } ?? "") + ":"
                lines.append(line)
                lines.append(quote(selection, code: c.location != nil, indent: String(repeating: " ", count: number.count)))
                continue
            }
            if let detail = c.detail, !detail.isEmpty { line += said.isEmpty ? ": pointed at \(detail)" : " (pointed at \(detail))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Longest selection quoted in full; a longer one is cut (its location still points to all of it).
    static let maxQuotedLines = 80, maxQuotedCharacters = 6_000

    /// A selection inside a list item: a code block for a file's text, a quote otherwise.
    static func quote(_ text: String, code: Bool, indent: String) -> String {
        var body = text.trimmingCharacters(in: .newlines)
        var cut = false
        if body.count > maxQuotedCharacters { body = String(body.prefix(maxQuotedCharacters)); cut = true }
        var lines = body.components(separatedBy: "\n")
        if lines.count > maxQuotedLines { lines = Array(lines.prefix(maxQuotedLines)); cut = true }
        if cut { lines.append("…") }
        if code {
            let fence = lines.contains { $0.hasPrefix("```") } ? "~~~" : "```"
            return ([fence] + lines + [fence]).map { $0.isEmpty ? "" : indent + $0 }.joined(separator: "\n")
        }
        return lines.map { indent + ($0.isEmpty ? ">" : "> " + $0) }.joined(separator: "\n")
    }

    /// When a macOS screenshot was taken, from its file name ("Screenshot 2026-10-18 at 18.49.12.png",
    /// "Bildschirmfoto 2026-10-18 um 6.49.12 PM.png"). The file itself is saved later, after the floating thumbnail.
    public static func captureDate(fileName: String, calendar: Calendar = .current) -> Date? {
        let pattern = #/(\d{4})-(\d{2})-(\d{2})\D+?(\d{1,2})[.:](\d{2})[.:](\d{2})(?:\s?([AaPp])\.?\s?[Mm])?/#
        guard let m = fileName.firstMatch(of: pattern),
              let y = Int(m.output.1), let mo = Int(m.output.2), let d = Int(m.output.3),
              var h = Int(m.output.4), let mi = Int(m.output.5), let s = Int(m.output.6) else { return nil }
        if let ampm = m.output.7?.lowercased() {
            if ampm == "p" && h < 12 { h += 12 } else if ampm == "a" && h == 12 { h = 0 }
        }
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))
    }
}

extension PromptScreenshots {
    /// Kinds of things Accessibility reports for a container rather than a control: worse than nothing next to a
    /// picture of it (the model wrote "the scroll area" for a task row).
    static let vagueKinds: Set<String> = ["scroll area", "group", "cell", "list", "text", "image", "split group", "unknown",
                                          "layout area", "web area", "html content", "content", "outline", "table", "item"]

    /// A capture's detail for a model that sees the picture: "pointed at: button “Add” in the toolbar; window: …", or
    /// just the window when Accessibility only named a container ("scroll area; window: Shout (Shout)").
    public static func withoutVagueThing(_ detail: String) -> String {
        var parts = detail.components(separatedBy: "; ")
        guard var thing = parts.first else { return detail }
        if thing.hasPrefix("under the mouse: ") { thing = String(thing.dropFirst("under the mouse: ".count)) }
        if thing.hasPrefix("window: ") || thing.hasPrefix("app: ") { return detail }
        let kind = thing.components(separatedBy: " in ").first ?? thing
        if !thing.contains("“") && vagueKinds.contains(kind.trimmingCharacters(in: .whitespaces).lowercased()) {
            parts.removeFirst()
            return parts.joined(separator: "; ")
        }
        parts[0] = "pointed at: " + thing
        return parts.joined(separator: "; ")
    }
}

/// Sizes the pictures a prompt points to for the assistant that reads them: just big enough to read an interface,
/// not so big that each one costs thousands of tokens.
public enum PromptImages {
    /// Claude reads images up to 1568 px on the long side and charges about width × height / 750 tokens: at 1280 px a
    /// full screen costs about 1,400 tokens and a window often under 1,000, and interface text stays readable.
    public static let maxLongEdge = 1280

    /// Writes `source` to `destination` as PNG with its long side at most `maxLongEdge` (never enlarged). Returns the
    /// new pixel size. `destination` may be `source`.
    @discardableResult
    public static func fit(_ source: URL, to destination: URL, maxLongEdge: Int = maxLongEdge) throws -> CGSize {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: min(max(w, h), maxLongEdge),
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try write(image, to: destination)
        return CGSize(width: image.width, height: image.height)
    }

    /// Writes an image as PNG, its long side at most `maxLongEdge` (Shout's own captures, before saving).
    @discardableResult
    public static func save(_ image: CGImage, to destination: URL, maxLongEdge: Int = maxLongEdge) throws -> CGSize {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxLongEdge else { try write(image, to: destination); return CGSize(width: image.width, height: image.height) }
        let scale = Double(maxLongEdge) / Double(longEdge)
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        try write(small, to: destination)
        return CGSize(width: w, height: h)
    }

    // MARK: For the local model

    /// About how many tokens Qwen's image reader spends on a picture: one per 32 × 32 pixels (16-pixel patches,
    /// merged 2 × 2), plus its start and end.
    public static func modelTokens(width: Int, height: Int) -> Int {
        ((width + 31) / 32) * ((height + 31) / 32) + 2
    }

    /// Tokens each of `count` pictures may take in a context of `contextTokens`, leaving room for the instructions,
    /// what was said and the reply: about 1,000 (a 1280 × 800 window) when they fit, fewer for many.
    public static func modelTokenBudget(count: Int, contextTokens: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(160, min(maxModelTokens, (contextTokens - 3_500) / count))
    }

    /// The most tokens one picture may take (`shout-cli prompt --image-tokens` changes it to compare sizes).
    nonisolated(unsafe) public static var maxModelTokens = 1_100

    /// The picture at `path` as PNG for the local model to look at, its long side at most `maxLongEdge` and scaled
    /// down to about `maxTokens` (`modelTokens`). Nil when it can't be read.
    public static func forModel(_ path: String, maxTokens: Int) -> (data: Data, tokens: Int)? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let longEdge = Double(max(w, h))
        var scale = min(1, Double(maxLongEdge) / longEdge)
        let area = Double(w * h) * scale * scale
        let allowed = Double(max(1, maxTokens - 2) * 32 * 32)
        if area > allowed { scale *= (allowed / area).squareRoot() }
        // Partly filled 32-pixel blocks count whole, so shrink a little more until it really fits.
        var edge = max(32, Int(longEdge * scale))
        var image: CGImage?
        for _ in 0..<12 {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: edge,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true]
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
            guard let i = image, modelTokens(width: i.width, height: i.height) > maxTokens, edge > 32 else { break }
            edge = max(32, edge - 16)
        }
        guard let image else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data, modelTokens(width: image.width, height: image.height))
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        // To a temporary file first: the destination may be the source, still being read.
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: tmp); throw CocoaError(.fileWriteUnknown) }
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp) }
        else { try FileManager.default.moveItem(at: tmp, to: url) }
    }
}

/// Which lines of a file selected text is on, for a prompt's "File.swift:12-18".
public enum SelectionLines {
    /// The lines of `text` in `contents`: where it occurs, or where the editor says it starts (`editorLine`) when it
    /// occurs more than once. Nil when it isn't there (unsaved changes) or can't be told apart.
    public static func lines(of text: String, in contents: String, editorLine: Int?) -> ClosedRange<Int>? {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let ns = contents as NSString
        var starts: [Int] = []
        var from = 0
        while starts.count < 50, from < ns.length {
            let r = ns.range(of: needle, options: [], range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound else { break }
            starts.append(line(at: r.location, in: ns))
            from = r.location + 1
        }
        let first: Int
        if starts.count == 1 { first = starts[0] }
        else if let editorLine, starts.contains(editorLine) { first = editorLine }
        else { return nil }
        return first...(first + needle.components(separatedBy: "\n").count - 1)
    }

    /// The 1-based line of a UTF-16 offset.
    public static func line(at offset: Int, in text: NSString) -> Int {
        var line = 1
        var i = 0
        let end = min(offset, text.length)
        while i < end {
            let r = text.range(of: "\n", options: [], range: NSRange(location: i, length: end - i))
            guard r.location != NSNotFound else { break }
            line += 1
            i = r.location + 1
        }
        return line
    }
}
