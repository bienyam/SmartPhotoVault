import SwiftUI
import UIKit

/// One button on a completion screen.
struct CompletionAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var prominent = false
    var identifier = ""
    let action: () -> Void
}

/// A full-screen "it worked" moment that can't be missed: a check that springs in, a burst of
/// confetti, a success haptic, what happened in plain words, and the next steps as buttons.
struct CompletionView: View {
    let title: String
    let detail: String
    var note: String? = nil
    let actions: [CompletionAction]
    @Environment(\.dismiss) private var dismiss
    @State private var shown = false

    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            ConfettiBurst().ignoresSafeArea().allowsHitTesting(false)
            ScrollView {
                VStack(spacing: 18) {
                    ZStack {
                        Circle().fill(Brand.safe.opacity(0.15)).frame(width: 150, height: 150)
                            .scaleEffect(shown ? 1 : 0.3)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 96))
                            .foregroundStyle(Brand.safe)
                            .scaleEffect(shown ? 1 : 0.2)
                            .rotationEffect(.degrees(shown ? 0 : -45))
                    }
                    .padding(.top, 40)
                    .accessibilityHidden(true)
                    Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                        .accessibilityIdentifier("completion-title")
                    Text(detail).font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    if let note {
                        Text(note).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 10) {
                        ForEach(actions) { item in
                            Button {
                                item.action()
                            } label: {
                                Label(item.title, systemImage: item.icon)
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 54)
                                    .foregroundStyle(item.prominent ? Brand.onAccent : Brand.primary)
                                    .background(item.prominent ? Brand.primary : Brand.surface,
                                                in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(item.identifier)
                        }
                        Button("Done") { dismiss() }
                            .font(.headline)
                            .padding(.top, 4)
                            .accessibilityIdentifier("completion-done")
                    }
                    .opacity(shown ? 1 : 0)
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) { shown = true }
        }
    }
}

/// A short burst of brand-coloured confetti falling from the top, drawn with Canvas.
/// Nothing is drawn with Reduce Motion on, and the timeline stops after `lifetime`, so the screen
/// isn't redrawn every frame while it stays open.
struct ConfettiBurst: View {
    /// How long the burst lasts, in seconds.
    static let lifetime: TimeInterval = 4

    /// True when the burst may be drawn.
    static func plays(reduceMotion: Bool) -> Bool { !reduceMotion }

    private struct Piece {
        let x: Double, speed: Double, drift: Double, spin: Double, size: Double, delay: Double
        let color: Color
    }

    private let pieces: [Piece] = (0..<90).map { _ in
        Piece(x: .random(in: 0...1), speed: .random(in: 260...520), drift: .random(in: -60...60),
              spin: .random(in: -6...6), size: .random(in: 6...12), delay: .random(in: 0...0.5),
              color: [Brand.primary, Brand.safe, Brand.caution, Brand.confettiBlue, Brand.confettiPink].randomElement()!)
    }
    @State private var start = Date()
    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if Self.plays(reduceMotion: reduceMotion) && !finished {
            burst
                .task {
                    try? await Task.sleep(for: .seconds(Self.lifetime))
                    finished = true
                }
        }
    }

    private var burst: some View {
        TimelineView(.animation(paused: finished)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                guard elapsed < Self.lifetime else { return }
                for piece in pieces {
                    let t = max(0, elapsed - piece.delay)
                    let y = -20 + piece.speed * t
                    guard y < size.height + 20 else { continue }
                    let x = piece.x * size.width + piece.drift * sin(t * 3)
                    var copy = context
                    copy.translateBy(x: x, y: y)
                    copy.rotate(by: .radians(piece.spin * t))
                    copy.opacity = max(0, 1 - elapsed / Self.lifetime)
                    let rect = CGRect(x: -piece.size / 2, y: -piece.size / 4, width: piece.size, height: piece.size / 2)
                    copy.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(piece.color))
                }
            }
        }
        .onAppear { start = Date() }
    }
}
