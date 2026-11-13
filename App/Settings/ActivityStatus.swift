import SwiftUI

// One calm line for try, test and preview actions: a small mark and what is
// happening now. A wait that runs past a few seconds shows its elapsed time,
// so a slow service never looks frozen. Under Reduce Motion the marks hold
// still and the words alone carry the state.
enum ActivityGlyph: Equatable { case working, playing, paused }

struct ActivityMark: View {
    let glyph: ActivityGlyph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            switch glyph {
            case .working:
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle().frame(width: 4, height: 4)
                                .opacity(reduceMotion ? 0.6 : Self.pulse(time, index))
                        }
                    }
                }
            case .playing:
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 11))
                    .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
            case .paused:
                Image(systemName: "pause.fill").font(.system(size: 9, weight: .semibold))
            }
        }.frame(width: 18, height: 14).foregroundStyle(.secondary).accessibilityHidden(true)
    }
    // A slow wave moving left to right; no dot fully disappears.
    static func pulse(_ time: TimeInterval, _ index: Int) -> Double {
        0.3 + 0.6 * (sin((time / 1.2 - Double(index) * 0.2) * 2 * .pi) + 1) / 2
    }
}

// Recent microphone levels, drawn like the recording indicator's bars. The
// view samples on its own clock, so nothing else redraws while someone speaks.
struct ActivityLevelBars: View {
    let sample: @MainActor () -> Double
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var levels = [Double](repeating: 0, count: 5)
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { level in
                Capsule().frame(width: 2, height: 2 + 12 * level.element)
            }
        }.frame(width: 18, height: 14).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: levels)
            .task(id: active) {
                levels = [Double](repeating: 0, count: levels.count)
                while active, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 50))
                    let value = sample()
                    levels = Array(levels.dropFirst()) + [value.isFinite ? min(1, max(0, value)) : 0]
                }
            }
    }
}

struct ActivityStatus: View {
    let title: String
    var glyph: ActivityGlyph = .working
    // Elapsed seconds appear once the wait passes this; nil never shows them.
    var elapsedAfter: TimeInterval? = 3
    // Explains a long wait, such as a model loading for the first time.
    var slowNote: String? = nil
    var size: CGFloat = 12
    @State private var started = Date()
    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(started)))
            let elapsed = elapsedAfter.map { Double(seconds) >= $0 } == true ? L10n.format("%ld s", seconds) : nil
            HStack(spacing: 6) {
                ActivityMark(glyph: glyph)
                Text(title).lineLimit(1).truncationMode(.tail)
                if let elapsed {
                    Text(elapsed).monospacedDigit().foregroundStyle(.tertiary).fixedSize()
                    if let slowNote { Text("· " + slowNote).lineLimit(1).truncationMode(.tail) }
                }
            }.font(.system(size: size)).foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([title, elapsed == nil ? nil : slowNote].compactMap { $0 }.joined(separator: " "))
                .accessibilityValue(elapsed ?? "")
        }
        .onChange(of: title) { _, _ in started = Date() }
    }
}
