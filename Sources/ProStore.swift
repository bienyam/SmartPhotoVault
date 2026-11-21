import StoreKit
import SwiftUI

/// The one source of truth for TidyAway Pro, shared by every screen.
/// It listens for purchase updates from launch, so Ask to Buy approvals, purchases on another
/// device, Family Sharing and refunds are picked up even when the Pro screen isn't open.
@MainActor
final class ProStore: ObservableObject {
    static let productID = "com.bienyam.SmartPhotoVault.storagepro"
    /// Free archive allowance before Pro is needed.
    nonisolated static let freeArchiveBytes: Int64 = 5_000_000_000

    @Published private(set) var unlocked = false
    @Published private(set) var product: Product?
    @Published private(set) var checking = true
    @Published private(set) var busy = false
    @Published var notice: String?

    private var updates: Task<Void, Never>?

    init() {
        #if DEBUG
        // UI tests can start with Pro on to exercise the unlocked screens.
        if ProcessInfo.processInfo.arguments.contains("--pro") {
            unlocked = true
            checking = false
            return
        }
        #endif
        updates = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                guard case .verified(let transaction) = update,
                      transaction.productID == ProStore.productID else { continue }
                await self?.refresh()
                await transaction.finish()
            }
        }
        Task { await start() }
    }

    deinit { updates?.cancel() }

    func start() async {
        checking = true
        await refresh()
        if !unlocked { await loadProduct() }
        checking = false
    }

    /// Unlocked while a verified, unrevoked purchase is among the current entitlements.
    func refresh() async {
        var found = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                found = true
            }
        }
        unlocked = found
    }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.productID]).first { $0.type == .nonConsumable }
            if product == nil { notice = "Pro isn't available right now. Try again in a moment." }
            else { notice = nil }
        } catch {
            notice = "Couldn't reach the App Store. Check your connection and try again."
        }
    }

    func purchase() async {
        guard !busy else { return }
        if product == nil { await loadProduct() }
        guard let product else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                // Unlock from the verified transaction itself; don't wait for entitlements to catch up.
                unlocked = transaction.revocationDate == nil
                await transaction.finish()
            case .success(.unverified):
                notice = "The purchase could not be verified."
            case .pending:
                notice = "Waiting for approval. Pro unlocks here as soon as it's approved."
            case .userCancelled:
                break
            @unknown default:
                notice = "The purchase could not be completed."
            }
        } catch {
            notice = "The purchase could not be completed."
        }
    }

    func restore() async {
        guard !busy else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refresh()
            if !unlocked { notice = "No Pro purchase was found for this Apple Account." }
        } catch {
            notice = "Couldn't restore purchases. Try again later."
        }
    }

    /// How much of the free archive allowance a selection would use, and whether it fits.
    nonisolated static func archiveAllowance(used: Int64, selection: Int64, unlocked: Bool) -> ArchiveAllowance {
        if unlocked { return .unlimited }
        let left = max(0, freeArchiveBytes - used)
        return selection <= left ? .fits(left: left) : .over(left: left)
    }
}

enum ArchiveAllowance: Equatable {
    case unlimited
    case fits(left: Int64)
    case over(left: Int64)
}

/// The Pro purchase controls, reused wherever Pro is offered.
struct ProPurchaseControls: View {
    @EnvironmentObject private var pro: ProStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Never block on the App Store: the buttons work while the check finishes.
            if pro.unlocked {
                Label("Pro is unlocked.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Brand.safe)
                    .accessibilityIdentifier("pro-unlocked")
            } else {
                Button {
                    Task { await pro.purchase() }
                } label: {
                    Text(pro.product.map { "Unlock Pro for \($0.displayPrice)" } ?? "Unlock Pro")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.primary)
                .disabled(pro.busy)
                .accessibilityIdentifier("pro-unlock")
                Text("One-time purchase through Apple. No renewals.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Restore purchase") { Task { await pro.restore() } }
                    .disabled(pro.busy)
                    .accessibilityIdentifier("pro-restore")
            }
            if let notice = pro.notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
                if pro.product == nil && !pro.unlocked {
                    Button("Try again") { Task { await pro.loadProduct() } }
                }
            }
        }
    }
}
