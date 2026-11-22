import SwiftUI

/// First launch: a three-beat photo story that ends on the welcome promises and Get started.
/// Beat 1 shows the moment the phone is full, beat 2 shows TidyAway finding what isn't needed,
/// beat 3 is the payoff with every welcome element. Skip always lands on beat 3.
/// Photos: Adobe Stock 379533224, 254326092, 109692836 (licensed, see mockups/welcome-assets/LICENSES.txt).
struct WelcomeStoryView: View {
    let start: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var beat = 0
    @State private var advance: Task<Void, Never>?

    static let beatSeconds: Double = 4.2
    static let lastBeat = 2

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                switch beat {
                case 0: MomentBeat(animate: !reduceMotion).id(0)
                case 1: ScanBeat(animate: !reduceMotion).id(1)
                default: PayoffBeat(animate: !reduceMotion, start: start).id(2)
                }
            }
            .transition(.opacity)

            if beat < Self.lastBeat {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { show(beat + 1) }
                    .accessibilityHidden(true)
                VStack {
                    HStack {
                        Spacer()
                        Button("Skip") { show(Self.lastBeat) }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.35), in: Capsule())
                            .accessibilityIdentifier("welcome-skip")
                    }
                    Spacer()
                    StoryDots(current: beat, count: Self.lastBeat + 1)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
        }
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: beat)
        .onAppear {
            // VoiceOver users get the welcome straight away, not a timed slideshow.
            show(voiceOver ? Self.lastBeat : 0)
        }
        .onDisappear { advance?.cancel() }
    }

    private func show(_ next: Int) {
        beat = min(next, Self.lastBeat)
        advance?.cancel()
        guard beat < Self.lastBeat else { return }
        let current = beat
        advance = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.beatSeconds * 1_000_000_000))
            if !Task.isCancelled && beat == current { show(current + 1) }
        }
    }
}

// MARK: - Beats

private struct MomentBeat: View {
    let animate: Bool
    @State private var bannerIn = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Covers the upper part only, which keeps the whole phone and hand in the frame.
            StoryPhoto(name: "WelcomeMoment", animate: animate, heightFraction: 0.76)
            BottomShade()
            VStack {
                StorageBanner()
                    .offset(y: bannerIn ? 0 : -220)
                    .padding(.horizontal, 14)
                    .padding(.top, 52)
                Spacer()
            }
            StoryCopy(kicker: "The moment",
                      headline: "Everyone's ready.\nYour phone isn't.",
                      lead: "Storage full, right when it matters most.")
                .padding(.bottom, 92)
        }
        .onAppear {
            if animate {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.8)) { bannerIn = true }
            } else {
                bannerIn = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("welcome-beat-moment")
    }
}

private struct ScanBeat: View {
    let animate: Bool
    @State private var fill: CGFloat = 0
    @State private var found: Double = 0
    @State private var chipsIn = false

    private static let exampleGB = 8.4
    private let finds = ["Duplicates", "Screenshots", "Large videos", "Bursts"]

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            StoryPhoto(name: "WelcomeScan", animate: animate)
            RadialGradient(colors: [Brand.primary.opacity(0.22), .black.opacity(0.85)],
                           center: UnitPoint(x: 0.5, y: 0.38), startRadius: 20, endRadius: 520)
                .ignoresSafeArea()
            GeometryReader { geo in
                ZStack {
                    dial
                        .frame(width: 240, height: 240)
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.32)
                    ForEach(Array(finds.enumerated()), id: \.offset) { index, name in
                        FindChip(text: name)
                            .position(chipPosition(index, in: geo.size))
                            .opacity(chipsIn ? 1 : 0)
                            .scaleEffect(chipsIn ? 1 : 0.85)
                            .animation(animate ? .spring(response: 0.5, dampingFraction: 0.6)
                                .delay(1.0 + Double(index) * 0.6) : nil, value: chipsIn)
                    }
                }
            }
            StoryCopy(kicker: "One scan",
                      headline: "TidyAway finds what you don't need.",
                      lead: "On your iPhone, in seconds. Nothing leaves your phone.")
                .padding(.bottom, 92)
        }
        .onAppear {
            chipsIn = true
            if animate {
                withAnimation(.timingCurve(0.3, 0.7, 0.2, 1, duration: 3.2).delay(0.4)) { fill = 0.77 }
                countUp()
            } else {
                fill = 0.77
                found = Self.exampleGB
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("welcome-beat-scan")
    }

    private var dial: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.14), lineWidth: 16)
            Circle()
                .trim(from: 0, to: fill)
                .stroke(LinearGradient(colors: [Brand.primary, Color(red: 1, green: 0.84, blue: 0.74)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 6) {
                Text(String(format: "%.1f GB", found))
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("EXAMPLE SCAN")
                    .font(.caption.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(Color(red: 1, green: 0.84, blue: 0.74))
            }
            .foregroundStyle(.white)
        }
        .accessibilityLabel("Example scan finding \(String(format: "%.1f", Self.exampleGB)) gigabytes")
    }

    private func chipPosition(_ index: Int, in size: CGSize) -> CGPoint {
        let spots: [(CGFloat, CGFloat)] = [(0.27, 0.14), (0.74, 0.22), (0.25, 0.47), (0.73, 0.52)]
        let spot = spots[index % spots.count]
        return CGPoint(x: size.width * spot.0, y: size.height * spot.1)
    }

    private func countUp() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            while found < Self.exampleGB {
                try? await Task.sleep(nanoseconds: 70_000_000)
                found = min(Self.exampleGB, found + 0.21)
            }
        }
    }
}

private struct PayoffBeat: View {
    let animate: Bool
    let start: () -> Void
    @State private var glow = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // The photo fills only the upper part, so the faces stay clear of the text below.
            StoryPhoto(name: "WelcomePayoff", animate: animate, heightFraction: 0.58)
            LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0),
                                   .init(color: .clear, location: 0.12),
                                   .init(color: .clear, location: 0.30),
                                   .init(color: .black.opacity(0.75), location: 0.42),
                                   .init(color: .black, location: 0.56)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        BrandMark(size: 40)
                        Text("TidyAway").font(.title3.bold())
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Out of space? Let's fix it safely.")
                            .font(.largeTitle.bold())
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text("TidyAway shows what is filling your iPhone and iCloud, then helps you clear it without losing a photo.")
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        promise("The check runs on your iPhone. Your photos stay put.")
                        promise("Nothing is removed until you approve it.")
                        promise("Every change is logged and can be traced.")
                    }
                    VStack(spacing: 10) {
                        Button(action: start) {
                            Text("Get started")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .foregroundStyle(Color.white)
                                // Deep orange in both modes: white on the lighter dark-mode orange is hard to read.
                                .background(Color(red: 0.784, green: 0.314, blue: 0.122), in: RoundedRectangle(cornerRadius: 16))
                                .shadow(color: Brand.primary.opacity(glow ? 0.85 : 0.45), radius: glow ? 20 : 12, y: 8)
                        }
                        Text("TidyAway asks for Photos access only when you start a scan, and it only reads at that stage.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .bottom)
            }
            .scrollBounceBehavior(.basedOnSize)
            }
        }
        .onAppear {
            if animate {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { glow = true }
            }
        }
    }

    private func promise(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color(red: 0.24, green: 0.86, blue: 0.59))
                .accessibilityHidden(true)
            Text(text).font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Pieces

/// Full-bleed photo with a slow push-in (Ken Burns) unless Reduce Motion is on.
private struct StoryPhoto: View {
    let name: String
    let animate: Bool
    /// How much of the screen, from the top, the photo covers.
    var heightFraction: CGFloat = 1
    @State private var zoomed = false

    var body: some View {
        GeometryReader { geo in
            Image(name)
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height * heightFraction)
                .scaleEffect(zoomed ? 1.14 : 1.04)
                .offset(x: zoomed ? -geo.size.width * 0.015 : 0, y: zoomed ? -geo.size.height * 0.01 : 0)
                .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear {
            guard animate else { return }
            withAnimation(.easeOut(duration: 6)) { zoomed = true }
        }
    }
}

private struct BottomShade: View {
    var body: some View {
        // Darker at the very top so the status bar and Skip read; fully dark where the photo ends.
        LinearGradient(stops: [.init(color: .black.opacity(0.40), location: 0),
                               .init(color: .black.opacity(0.10), location: 0.12),
                               .init(color: .clear, location: 0.28),
                               .init(color: .black.opacity(0.10), location: 0.46),
                               .init(color: .black.opacity(0.85), location: 0.69),
                               .init(color: .black, location: 0.755)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// Illustration of the moment the camera stops. Branded, so it never passes for a real iOS alert.
private struct StorageBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Brand.primary, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                // The words people see when the camera stops, in TidyAway's own look and with no buttons.
                Text("Cannot Take Photo").font(.subheadline.bold())
                Text("There is not enough available storage to take a photo.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct StoryCopy: View {
    let kicker: String
    let headline: String
    let lead: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kicker.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1)
                .foregroundStyle(Color(red: 1, green: 0.84, blue: 0.74))
            Text(headline)
                .font(.system(size: 34, weight: .heavy))
                .shadow(color: .black.opacity(0.35), radius: 12)
                .accessibilityAddTraits(.isHeader)
            Text(lead)
                .font(.body)
                .foregroundStyle(.white.opacity(0.86))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 26)
        .frame(maxWidth: 520, alignment: .leading)
    }
}

private struct FindChip: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Brand.primary).frame(width: 7, height: 7)
            Text(text).font(.footnote.weight(.bold))
        }
        .foregroundStyle(Color(red: 0.48, green: 0.18, blue: 0.06))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color(red: 1, green: 0.97, blue: 0.93), in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
    }
}

private struct StoryDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(index == current ? 1 : 0.4))
                    .frame(width: index == current ? 22 : 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}
