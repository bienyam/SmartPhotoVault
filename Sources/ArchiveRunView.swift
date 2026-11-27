import SwiftUI
import UIKit

/// Progress of one archive run, and the request to stop after the current item.
@MainActor
final class ArchiveRun: ObservableObject {
    @Published var total = 0
    @Published var tried = 0
    @Published var copied = 0
    @Published var bytes: Int64 = 0
    @Published var currentID: String?
    @Published var stopping = false
    @Published var outcome: ArchiveOutcome?
    /// What the run is doing once every item is done, such as making sure a drive saved everything.
    @Published var phase: String?
    /// Failures so far, counted by a short reason, so the screen can say why while the run goes on.
    @Published var reasons: [String: Int] = [:]

    var failures: Int { reasons.values.reduce(0, +) }

    func failed(_ error: Error) { reasons[Self.reason(for: error), default: 0] += 1 }

    private var background: UIBackgroundTaskIdentifier = .invalid

    /// Asks iOS for the short extra time it allows when the app is switched away mid-run, so the piece
    /// being copied isn't cut off. Ends by itself when iOS says time is up; the run then stops the way
    /// it always did when the app was suspended.
    func holdBackgroundTime() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Archive copy") {
            // iOS calls this on the main thread.
            MainActor.assumeIsolated { self.releaseBackgroundTime() }
        }
    }

    func releaseBackgroundTime() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    /// A few plain words for why an item couldn't be copied.
    static func reason(for error: Error) -> String {
        switch error {
        case ArchiveError.iCloudDownload: return "iCloud didn't send them"
        case ArchiveError.unsupportedPhoto: return "Kind not supported yet (slo-mo, edited videos, RAW)"
        case ArchiveError.verification, CloudError.verification, GoogleDriveError.verification: return "The copy didn't match the original"
        case CloudError.notConfirmedYet: return "Not confirmed by the service yet"
        case CloudError.server(let name, _): return "\(name) didn't accept them"
        case GoogleDriveError.server: return "Google Drive didn't accept them"
        case ArchiveError.editedDuringCopy: return "Edited while it was being copied"
        case is OverFreeArchive: return "Over the free 5 GB of archiving"
        case ArchiveError.wifi: return "Wi-Fi to the file server dropped"
        case ArchiveError.unavailable, ArchiveError.missingFile: return "The destination couldn't be reached"
        case GoogleDriveError.noSpace: return "Not enough space on this \(Device.name)"
        case is URLError: return "The connection dropped"
        default:
            let error = error as NSError
            if (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC)) {
                return "Not enough space on this \(Device.name)"
            }
            return "Other problem (details at the end)"
        }
    }

    func start(_ count: Int) {
        total = count
        tried = 0
        copied = 0
        bytes = 0
        currentID = nil
        stopping = false
        outcome = nil
        reasons = [:]
        phase = nil
        ArchiveLive.shared.reset()
    }
}

/// How a run ended.
struct ArchiveOutcome {
    let completion: ArchiveCompletion?
    let failures: [String]
    /// Not tried, because the run was stopped. They stay selected.
    let left: Int
    let place: String
}

/// Copying, with a real count. Nothing here can be missed or left halfway by accident.
struct ArchiveProgressView: View {
    @ObservedObject var run: ArchiveRun
    let usesDrive: Bool

    private var fraction: Double { run.total > 0 ? Double(run.tried) / Double(run.total) : 0 }

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 20)
            ZStack {
                Circle().stroke(Color.gray.opacity(0.28), lineWidth: 18)
                Circle()
                    .trim(from: 0, to: max(0.01, fraction))
                    .stroke(Color(red: 1, green: 0.541, blue: 0.361), style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                AssetCover(assetID: run.currentID ?? "sample-", side: 500)
                    .id(run.currentID)
                    .frame(width: 170, height: 170)
                    .clipShape(Circle())
            }
            .frame(width: 240, height: 240)
            .accessibilityHidden(true)
            Text("\(run.tried.formatted()) of \(run.total.formatted())")
                .font(.largeTitle.bold()).monospacedDigit()
                .accessibilityIdentifier("archive-progress")
            Text("done · \(run.copied.formatted()) copied and checked (\(run.bytes.fileSize))\(run.failures > 0 ? " · \(run.failures.formatted()) failed" : "")")
                .foregroundStyle(ArchiveStyle.muted)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("archive-progress-split")
            if run.failures > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(run.reasons.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }, id: \.key) { reason, count in
                        Label("\(count.formatted()) · \(reason)", systemImage: "exclamationmark.circle.fill")
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.caution)
                .accessibilityIdentifier("archive-failure-reasons")
            }
            if run.total > 0, run.tried >= run.total, run.outcome == nil {
                Label(run.phase ?? "Finishing up…", systemImage: "hourglass")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ArchiveStyle.muted)
                    .symbolEffect(.pulse)
                    .accessibilityIdentifier("archive-finishing")
            }
            // Live activity, so a long first item never looks like nothing is happening.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let live = ArchiveLive.shared.now
                VStack(spacing: 4) {
                    if live.downloading > 0 {
                        Label("Downloading \(live.downloading.formatted()) from iCloud · \(Int(live.fraction * 100))%", systemImage: "icloud.and.arrow.down")
                            .accessibilityIdentifier("archive-downloading")
                    }
                    if live.written > 0 {
                        Text("\(live.written.fileSize) read from Photos so far")
                    }
                    let sent = ArchiveLive.shared.uploadedBytes
                    if sent > 0 {
                        Text("\(sent.fileSize) uploaded so far")
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ArchiveStyle.muted)
                .monospacedDigit()
            }
            if run.tried > run.copied {
                Text("Failed items stay on your \(Device.name) and stay selected to try again. Details at the end.")
                    .font(.footnote).foregroundStyle(ArchiveStyle.muted)
                    .multilineTextAlignment(.center)
            }
            Text(usesDrive ? "Keep TidyAway open and stay online." : "Keep TidyAway open. Keep your drive plugged in or your server in reach.")
                .font(.subheadline).foregroundStyle(ArchiveStyle.muted)
                .multilineTextAlignment(.center)
            Spacer(minLength: 20)
            Button(run.stopping ? "Stopping after this item…" : "Stop") { run.stopping = true }
                .buttonStyle(ArchiveOutlineStyle())
                .disabled(run.stopping)
                .accessibilityIdentifier("archive-stop")
        }
        .padding(24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.background)
        .interactiveDismissDisabled()
    }
}

/// The end of a run: a full screen that can't be missed, with the next step right there.
struct ArchiveDoneView: View {
    let outcome: ArchiveOutcome
    let note: String?
    let canDelete: Bool
    let openDrive: (() -> Void)?
    let delete: () -> Void
    let getBack: () -> Void
    let details: () -> Void
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private var copied: Int { outcome.completion?.count ?? 0 }
    private var worked: Bool { copied > 0 }

    var body: some View {
        ZStack {
            (worked ? ArchiveStyle.done : Color(red: 0.45, green: 0.28, blue: 0)).ignoresSafeArea()
            if worked && !reduceMotion { ConfettiBurst().ignoresSafeArea().allowsHitTesting(false) }
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: worked ? "checkmark" : "exclamationmark")
                        .font(.system(size: 64, weight: .black))
                        .foregroundStyle(worked ? ArchiveStyle.done : Color(red: 0.45, green: 0.28, blue: 0))
                        .frame(width: 132, height: 132)
                        .background(Color.white, in: Circle())
                        .scaleEffect(shown ? 1 : 0.4)
                        .padding(.top, 36)
                        .accessibilityHidden(true)
                    Text(worked ? "\(copied.formatted()) copied and checked" : "Nothing was copied")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("completion-title")
                    if let done = outcome.completion {
                        Text("\(done.bytes.fileSize) is now on \(done.place), checked against the originals.")
                            .font(.title3)
                        HStack(spacing: -8) {
                            ForEach(done.photoIDs.prefix(5), id: \.self) { id in
                                AssetCover(assetID: id, side: 180)
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white, lineWidth: 2.5))
                            }
                        }
                        .accessibilityHidden(true)
                    }
                    if !outcome.failures.isEmpty {
                        Label("\(outcome.failures.count.formatted()) need attention. They stay on your \(Device.name).", systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("completion-failures")
                    }
                    if outcome.left > 0 {
                        Text("Stopped. \(outcome.left.formatted()) not copied yet are still selected.")
                            .font(.subheadline.weight(.semibold))
                    }
                    if let note { Text(note).font(.subheadline) }
                    HStack(spacing: 8) {
                        if let openDrive { link("See in Drive", "completion-drive", openDrive) }
                        if worked { link("Get back", "completion-getback", getBack) }
                        link("Details", "completion-details", details)
                    }
                    VStack(spacing: 10) {
                        if canDelete {
                            Button("Delete from \(Device.name)…", action: delete)
                                .buttonStyle(ArchiveButtonStyle(fill: .white, text: ArchiveStyle.done))
                                .accessibilityIdentifier("completion-remove")
                        }
                        Button(canDelete ? "Keep on \(Device.name)" : "Done", action: close)
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("completion-done")
                    }
                    .padding(.top, 8)
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(worked ? .success : .warning)
            withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.6)) { shown = true }
        }
    }

    private func link(_ title: String, _ identifier: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.bold))
            .underline()
            .frame(minWidth: 80, minHeight: 44)
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
    }
}
