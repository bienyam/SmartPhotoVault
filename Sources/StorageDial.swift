import SwiftUI

/// One arc of the Dial, as a share of the whole circle.
struct DialPart: Equatable {
    let fraction: Double
    let color: Color

    static let photos = Color(red: 1, green: 0.541, blue: 0.361)
    static let other = Color(red: 0.541, green: 0.561, blue: 0.651)

    /// Where each arc starts and ends, never past the full circle.
    static func spans(_ parts: [DialPart]) -> [(from: Double, to: Double)] {
        var start = 0.0
        return parts.map { part in
            let end = min(1, start + max(0, part.fraction))
            defer { start = end }
            return (start, end)
        }
    }
}

/// The Dial: how full the phone is, then progress, then what could be freed. Its middle holds the main thing.
struct StorageDial<Center: View>: View {
    let parts: [DialPart]
    /// What VoiceOver reads for the ring itself.
    let summary: String
    @ViewBuilder let center: Center
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if typeSize.isAccessibilitySize {
            // At the largest text sizes the middle would not fit inside the ring.
            VStack(spacing: 14) {
                ring.frame(width: 160, height: 160)
                center
            }
            .frame(maxWidth: .infinity)
        } else {
            ZStack {
                ring
                center.frame(maxWidth: 190)
            }
            .frame(width: 256, height: 256)
            .frame(maxWidth: .infinity)
        }
    }

    private var ring: some View {
        let spans = DialPart.spans(parts)
        return ZStack {
            Circle().stroke(Color.gray.opacity(0.24), lineWidth: 20)
            ForEach(parts.indices, id: \.self) { index in
                Circle()
                    .trim(from: spans[index].from, to: spans[index].to)
                    .stroke(parts[index].color, style: StrokeStyle(lineWidth: 20, lineCap: parts.count == 1 ? .round : .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(10)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: parts)
        .accessibilityElement()
        .accessibilityLabel(summary)
    }
}

/// The round button in the middle of the Dial.
struct DialButton: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            Button("Free up space", action: action)
                .buttonStyle(ArchiveButtonStyle())
                .accessibilityIdentifier("free-up-space")
        } else {
            Button(action: action) {
                VStack(spacing: 2) {
                    Text("Free up").font(.system(size: 34, weight: .heavy))
                    Text("space").font(.title3.weight(.semibold))
                }
                .foregroundStyle(ArchiveStyle.onAction)
                .frame(width: 180, height: 180)
                .background(ArchiveStyle.action, in: Circle())
                .background {
                    if !reduceMotion {
                        Circle()
                            .fill(DialPart.photos)
                            .phaseAnimator([false, true]) { halo, wide in
                                halo.scaleEffect(wide ? 1.12 : 1).opacity(wide ? 0.12 : 0.35)
                            } animation: { _ in .easeInOut(duration: 1.1) }
                    }
                }
                .shadow(color: ArchiveStyle.action.opacity(0.35), radius: 14, y: 8)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Free up space")
            .accessibilityHint("Checks photos on this \(Device.name)")
            .accessibilityIdentifier("free-up-space")
        }
    }
}

/// What a set of finds means, in words people know.
struct FindTag: View {
    enum Kind { case safe, look, decide }
    let kind: Kind

    private var title: String {
        switch kind {
        case .safe: "Safe to clear"
        case .look: "Worth a look"
        case .decide: "You decide"
        }
    }
    private var note: String {
        switch kind {
        case .safe: "Identical copies. One is always kept."
        case .look: "Often not needed. You choose."
        case .decide: "GIFs, bursts, Live Photos and more."
        }
    }
    private var back: Color {
        switch kind {
        case .safe: ArchiveStyle.safeBack
        case .look: Brand.surface
        case .decide: ArchiveStyle.selected
        }
    }
    private var text: Color {
        switch kind {
        case .safe: ArchiveStyle.safeText
        case .look: ArchiveStyle.link
        case .decide: ArchiveStyle.onSelected
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 4) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var content: some View {
        Text(title).font(.subheadline.weight(.heavy))
            .foregroundStyle(text)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(back, in: Capsule())
        Text(note).font(.footnote).foregroundStyle(ArchiveStyle.muted)
    }
}

/// The full storage card, opened from under the Dial.
struct WhatsUsingView: View {
    let storage: DeviceStorage
    let photosBytes: Int64
    let isDemo: Bool

    var body: some View {
        ScrollView {
            PhoneBreakdown(storage: storage, photosBytes: photosBytes, isDemo: isDemo)
                .frame(maxWidth: 520)
                .padding(20)
                .frame(maxWidth: .infinity)
        }
        .background(Brand.background)
        .navigationTitle("What's using it")
        .navigationBarTitleDisplayMode(.inline)
    }
}
