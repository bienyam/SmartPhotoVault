import StoreKit
import SwiftUI

/// The one source of truth for TidyAway Pro, shared by every screen.
/// Pro comes three ways: a monthly or yearly subscription, or a one-time lifetime unlock.
/// It listens for purchase updates from launch, so Ask to Buy approvals, renewals, purchases on
/// another device, Family Sharing, expiry and refunds are picked up even when the Pro screen isn't open.
@MainActor
final class ProStore: ObservableObject {
    /// One-time lifetime unlock. Kept from the original product so existing setup still matches.
    static let lifetimeID = "com.bienyam.SmartPhotoVault.storagepro"
    static let monthlyID = "com.bienyam.SmartPhotoVault.pro.monthly"
    static let yearlyID = "com.bienyam.SmartPhotoVault.pro.yearly"
    static let subscriptionIDs: Set<String> = [monthlyID, yearlyID]
    static let productIDs: Set<String> = [lifetimeID, monthlyID, yearlyID]
    /// Free archive allowance before Pro is needed.
    nonisolated static let freeArchiveBytes: Int64 = 5_000_000_000

    enum Plan: Equatable { case none, monthly, yearly, lifetime }

    @Published private(set) var plan: Plan = .none
    @Published private(set) var monthly: Product?
    @Published private(set) var yearly: Product?
    /// True when this Apple Account can still get the subscriptions' introductory offer (the free trial).
    @Published private(set) var trialEligible = false
    @Published private(set) var lifetime: Product?
    @Published private(set) var checking = true
    @Published private(set) var busy = false
    @Published var notice: String?
    /// True in TestFlight builds while `TesterAccess` is on: every Pro feature works, nothing is bought.
    @Published private(set) var testerAccess = false

    var unlocked: Bool { plan != .none || testerAccess }
    /// What the screens show. Testers see Pro the way a free user does (PRO badges, locks, prices)
    /// while `unlocked` still lets every feature through.
    var looksUnlocked: Bool { plan != .none }
    private var updates: Task<Void, Never>?

    init() {
        #if DEBUG
        // UI tests can start with Pro on to exercise the unlocked screens.
        if ProcessInfo.processInfo.arguments.contains("--pro") {
            plan = .lifetime
            checking = false
            return
        }
        #endif
        updates = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                guard case .verified(let transaction) = update,
                      ProStore.productIDs.contains(transaction.productID) else { continue }
                await self?.refresh()
                await transaction.finish()
            }
        }
        Task { await start() }
    }

    deinit { updates?.cancel() }

    func start() async {
        checking = true
        if TesterAccess.enabled, let app = try? await AppTransaction.shared {
            switch app {
            case .verified(let transaction), .unverified(let transaction, _):
                testerAccess = transaction.environment == .sandbox
            }
        }
        await refresh()
        await loadProducts()
        checking = false
    }

    /// Lifetime wins over a subscription. A subscription counts only while it hasn't expired or been revoked.
    func refresh() async {
        var found = Plan.none
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if transaction.productID == Self.lifetimeID {
                found = .lifetime
            } else if Self.subscriptionIDs.contains(transaction.productID), found == .none,
                      (transaction.expirationDate ?? .distantFuture) > Date() {
                found = transaction.productID == Self.yearlyID ? .yearly : .monthly
            }
        }
        plan = found
    }

    func loadProducts() async {
        do {
            let products = try await Product.products(for: Self.productIDs)
            monthly = products.first { $0.id == Self.monthlyID }
            yearly = products.first { $0.id == Self.yearlyID }
            lifetime = products.first { $0.id == Self.lifetimeID }
            // Eligibility is per subscription group, so either subscription answers it.
            if let subscription = (monthly ?? yearly)?.subscription {
                trialEligible = await subscription.isEligibleForIntroOffer
            }
            notice = (monthly == nil && yearly == nil && lifetime == nil) ? "Pro isn't available right now. Try again in a moment." : nil
        } catch {
            notice = "Couldn't reach the App Store. Check your connection and try again."
        }
    }

    func purchase(_ product: Product) async {
        guard !busy else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                // Unlock from the verified transaction itself; don't wait for entitlements to catch up.
                if transaction.revocationDate == nil {
                    plan = Self.plan(after: transaction.productID, current: plan)
                    trialEligible = false
                }
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

    /// The plan a verified purchase leads to. Lifetime is never downgraded by a subscription.
    static func plan(after productID: String, current: Plan) -> Plan {
        if productID == lifetimeID || current == .lifetime { return .lifetime }
        return productID == yearlyID ? .yearly : .monthly
    }

    /// The trial line shown under a subscription, such as "3 days free, then $4.99 a month."
    /// Nil when there is no free-trial offer or this account has already used one.
    static func trialLine(for product: Product?, eligible: Bool, per unit: String) -> String? {
        guard eligible, let product, let offer = product.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        return "\(trialLength(offer.period.value, offer.period.unit)) free, then \(product.displayPrice) a \(unit)."
    }

    nonisolated static func trialLength(_ value: Int, _ unit: Product.SubscriptionPeriod.Unit) -> String {
        let name: String
        switch unit {
        case .day: name = "day"
        case .week: name = "week"
        case .month: name = "month"
        case .year: name = "year"
        @unknown default: name = "day"
        }
        return "\(value) \(name)\(value == 1 ? "" : "s")"
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

/// The Pro purchase controls, reused wherever Pro is offered: monthly or once, with the
/// subscription terms Apple requires shown next to the buttons.
struct ProPurchaseControls: View {
    @EnvironmentObject private var pro: ProStore
    @Environment(\.openURL) private var openURL

    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://github.com/bienyam/SmartPhotoVault/blob/main/PRIVACY.md")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Never block on the App Store: the buttons work while the check finishes.
            switch pro.plan {
            case .lifetime:
                Label("Pro is unlocked.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Brand.safe)
                    .accessibilityIdentifier("pro-unlocked")
            case .monthly, .yearly:
                Label(pro.plan == .yearly ? "Pro is unlocked. Yearly plan." : "Pro is unlocked. Monthly plan.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Brand.safe)
                    .accessibilityIdentifier("pro-unlocked")
                Button("Manage subscription") {
                    Task {
                        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                            try? await AppStore.showManageSubscriptions(in: scene)
                        }
                    }
                }
                if let lifetime = pro.lifetime {
                    Button("Switch to lifetime for \(lifetime.displayPrice)") { Task { await pro.purchase(lifetime) } }
                        .disabled(pro.busy)
                }
            case .none:
                option(title: pro.monthly.map { "\($0.displayPrice) a month" } ?? "Monthly",
                       detail: ProStore.trialLine(for: pro.monthly, eligible: pro.trialEligible, per: "month") ?? "Cancel anytime.",
                       product: pro.monthly, prominent: false, id: "pro-monthly")
                if pro.yearly != nil {
                    option(title: pro.yearly.map { "\($0.displayPrice) a year" } ?? "Yearly",
                           detail: ProStore.trialLine(for: pro.yearly, eligible: pro.trialEligible, per: "year") ?? "Cancel anytime.",
                           product: pro.yearly, prominent: false, id: "pro-yearly")
                }
                option(title: pro.lifetime.map { "\($0.displayPrice) once" } ?? "Lifetime",
                       detail: "Pay once, keep Pro.", product: pro.lifetime, prominent: true, id: "pro-lifetime")
                Text(renewalTerms)
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button("Terms of Use") { openURL(Self.termsURL) }
                    Button("Privacy Policy") { openURL(Self.privacyURL) }
                }
                .font(.footnote)
                Button("Restore purchase") { Task { await pro.restore() } }
                    .disabled(pro.busy)
                    .accessibilityIdentifier("pro-restore")
            }
            if let notice = pro.notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
                if pro.monthly == nil && pro.yearly == nil && pro.lifetime == nil && !pro.unlocked {
                    Button("Try again") { Task { await pro.loadProducts() } }
                }
            }
        }
        .buttonStyle(.borderless)
    }

    /// Apple's required subscription terms, including what happens when a free trial ends.
    private var renewalTerms: String {
        let monthly = pro.monthly?.displayPrice ?? "the price shown"
        var text = "Subscriptions renew automatically at \(monthly) a month"
        if let yearly = pro.yearly?.displayPrice { text += " or \(yearly) a year" }
        text += " until you cancel."
        if pro.trialEligible, (pro.monthly ?? pro.yearly)?.subscription?.introductoryOffer?.paymentMode == .freeTrial {
            text += " The free trial becomes a paid subscription when it ends unless you cancel before then."
        }
        return text + " Cancel at least 24 hours before the end of the current period in Settings, your name, Subscriptions. Payment is charged to your Apple Account."
    }

    private func option(title: String, detail: String, product: Product?, prominent: Bool, id: String) -> some View {
        Button {
            if let product { Task { await pro.purchase(product) } } else { Task { await pro.loadProducts() } }
        } label: {
            VStack(spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(prominent ? Color.white : Brand.primary)
            .background(prominent ? Brand.primary : Brand.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(pro.busy)
        .accessibilityIdentifier(id)
    }
}
