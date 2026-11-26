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
    /// True while the prices are on their way from the App Store.
    @Published private(set) var loadingProducts = false
    /// A plan tapped before its price arrived. It is bought as soon as the App Store answers.
    @Published private(set) var waitingToBuy: String?
    /// People who started on TidyAway 1.0 keep the smart picks on Free up for good.
    @Published private(set) var grandfathered = Grandfather.isSet()
    @Published var notice: String?
    /// True in TestFlight builds while `TesterAccess` is on: every Pro feature works, nothing is bought.
    @Published private(set) var testerAccess = false

    var unlocked: Bool { plan != .none || testerAccess }
    /// What the screens show. Testers are shown as Pro, the same as a paying customer.
    var looksUnlocked: Bool { unlocked }
    /// True while a purchase, a restore or a price check is talking to the App Store.
    var connecting: Bool { busy || waitingToBuy != nil }
    private var updates: Task<Void, Never>?
    private var productLoad: Task<Void, Never>?
    /// Identifies the queued buy, so one cancelled with its screen is never carried out later.
    private var queuedBuy: UUID?

    /// The one question every screen asks before opening a Pro feature.
    func allows(_ feature: ProFeature) -> Bool {
        ProGate.allows(feature, pro: unlocked, grandfathered: grandfathered)
    }

    init() {
        #if DEBUG
        // UI tests can start as someone who installed 1.0.
        if ProcessInfo.processInfo.arguments.contains("--grandfathered") { grandfathered = true }
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
        // Apple's record of the first installed build, asked once and kept.
        Task { [weak self] in
            guard let self, !self.grandfathered else { return }
            if await Grandfather.checkAppStoreRecord() { self.grandfathered = true }
        }
    }

    deinit { updates?.cancel() }

    func start() async {
        checking = true
        // Prices are fetched alongside the purchase check, not after it, so the buttons are ready sooner.
        let prices = Task { await loadProducts() }
        // Tester builds (TESTER_ACCESS, never the App Review build) unlock Pro for everyone except a
        // real App Store customer. If Apple's record can't be read, a tester build still unlocks.
        if TesterAccess.enabled { testerAccess = !(await Self.isAppStoreCustomer()) }
        await refresh()
        checking = false
        await prices.value
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

    /// Fetches the prices once, however many screens ask at the same time.
    func loadProducts() async {
        if let productLoad {
            await productLoad.value
            return
        }
        let load = Task { await fetchProducts() }
        productLoad = load
        await load.value
        productLoad = nil
    }

    private func product(_ id: String) -> Product? {
        [monthly, yearly, lifetime].compactMap { $0 }.first { $0.id == id }
    }

    /// Buys a plan. Tapped before its price has arrived, it waits for the App Store and then buys,
    /// so the first tap is never lost.
    func buy(_ id: String) async {
        if let product = product(id) {
            await purchase(product)
            return
        }
        guard waitingToBuy == nil else { return }
        let ticket = UUID()
        queuedBuy = ticket
        waitingToBuy = id
        notice = nil
        await loadProducts()
        // The sheet or page that queued it has closed: don't start a purchase nobody is looking at.
        guard queuedBuy == ticket else { return }
        queuedBuy = nil
        waitingToBuy = nil
        if let product = product(id) {
            await purchase(product)
        } else if notice == nil {
            notice = "Couldn't reach the App Store. Check your connection and try again."
        }
    }

    /// Drops a plan tapped before its price arrived. Called when the screen that queued it goes away
    /// ("Not now", a swipe down, or navigating away). A purchase already with the App Store is not touched.
    func cancelQueuedBuy() {
        guard waitingToBuy != nil else { return }
        queuedBuy = nil
        waitingToBuy = nil
    }

    private func fetchProducts() async {
        loadingProducts = true
        defer { loadingProducts = false }
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

    /// True only when Apple's record says this copy came from the App Store itself.
    private static func isAppStoreCustomer() async -> Bool {
        guard let app = try? await AppTransaction.shared else { return false }
        switch app {
        case .verified(let transaction), .unverified(let transaction, _):
            return transaction.environment == .production
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

    /// A trial's length as it reads in a button: "7-day", "1-week".
    nonisolated static func trialName(_ value: Int, _ unit: Product.SubscriptionPeriod.Unit) -> String {
        let name: String
        switch unit {
        case .day: name = "day"
        case .week: name = "week"
        case .month: name = "month"
        case .year: name = "year"
        @unknown default: name = "day"
        }
        return "\(value)-\(name)"
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
    /// The Pro page pins the plans to the bottom of the screen and keeps the terms in the page.
    enum Part { case all, plans, terms }

    var part = Part.all
    @EnvironmentObject private var pro: ProStore
    @Environment(\.openURL) private var openURL

    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://github.com/bienyam/SmartPhotoVault/blob/main/PRIVACY.md")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if part != .terms { plans }
            if part != .plans, pro.plan == .none { terms }
        }
        .buttonStyle(.borderless)
    }

    /// The plan buttons, or what is already unlocked, with the App Store's progress and notices.
    @ViewBuilder
    private var plans: some View {
        if pro.testerAccess, pro.plan == .none {
            Label("Pro is on for testers. Buying below is free in TestFlight.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Brand.safe)
                .accessibilityIdentifier("pro-tester")
        }
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
            // Pinned to the bottom of the Pro page the plans sit side by side; elsewhere, one under another.
            let layout = part == .plans
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 8))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            layout {
                option(title: pro.monthly.map { "\($0.displayPrice) a month" } ?? "Monthly",
                       detail: ProStore.trialLine(for: pro.monthly, eligible: pro.trialEligible, per: "month") ?? "Cancel anytime.",
                       product: pro.monthly, productID: ProStore.monthlyID, prominent: false, id: "pro-monthly")
                if pro.yearly != nil {
                    option(title: pro.yearly.map { "\($0.displayPrice) a year" } ?? "Yearly",
                           detail: ProStore.trialLine(for: pro.yearly, eligible: pro.trialEligible, per: "year") ?? "Cancel anytime.",
                           product: pro.yearly, productID: ProStore.yearlyID, prominent: false, id: "pro-yearly")
                }
                option(title: pro.lifetime.map { "\($0.displayPrice) once" } ?? "Lifetime",
                       detail: "Pay once, keep Pro.", product: pro.lifetime, productID: ProStore.lifetimeID, prominent: true, id: "pro-lifetime")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        if pro.connecting {
            HStack(spacing: 8) {
                ProgressView()
                Text("Connecting to the App Store…")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(ArchiveStyle.muted)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pro-connecting")
        }
        if let notice = pro.notice {
            Text(notice).font(.footnote).foregroundStyle(.secondary)
            if pro.monthly == nil && pro.yearly == nil && pro.lifetime == nil && !pro.unlocked {
                Button("Try again") { Task { await pro.loadProducts() } }
            }
        }
    }

    /// Apple's subscription terms, the links they require, and Restore.
    @ViewBuilder
    private var terms: some View {
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

    private func option(title: String, detail: String, product: Product?, productID: String, prominent: Bool, id: String) -> some View {
        let waiting = product == nil && (pro.loadingProducts || pro.waitingToBuy == productID)
        return Button {
            Haptics.light()
            Task { await pro.buy(productID) }
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.headline).lineLimit(2).minimumScaleFactor(0.75)
                    // The price is still on its way: a tap now buys as soon as it arrives.
                    if waiting {
                        ProgressView()
                            .tint(prominent ? ArchiveStyle.onAction : Brand.primary)
                            .accessibilityLabel("Getting the price")
                    }
                }
                Text(waiting ? "Getting the price from the App Store…" : detail).font(.caption)
                    .lineLimit(3).minimumScaleFactor(0.85)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 56, maxHeight: .infinity)
            .foregroundStyle(prominent ? ArchiveStyle.onAction : Brand.primary)
            .background(prominent ? ArchiveStyle.action : Brand.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PressableStyle())
        .disabled(pro.busy)
        .accessibilityIdentifier(id)
    }
}
