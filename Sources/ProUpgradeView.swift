import StoreKit
import SwiftUI

/// The one place that explains TidyAway Pro. It never interrupts: people open it from Home or the Ledger.
/// What Pro unlocks is unchanged: saving, comparing and sharing storage scenarios.
struct ProUpgradeView: View {
    static let productID = "com.bienyam.SmartPhotoVault.storagepro"

    @State private var product: Product?
    @State private var unlocked = false
    @State private var loading = true
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TidyAway Pro").font(.title2.bold())
                    Text("One-time unlock. Never a subscription.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            Section("Free for everyone") {
                feature("Scan your library on your iPhone", icon: "magnifyingglass")
                feature("Find exact duplicates and remove extra copies after you sign off", icon: "square.on.square")
                feature("Look through screenshots, bursts, Live Photos, videos and more", icon: "square.grid.2x2")
                feature("Archive originals to your own storage and restore them", icon: "archivebox")
                feature("Storage and cost analysis", icon: "chart.bar")
            }
            Section("Added with Pro") {
                feature("Save storage scenarios to revisit later", icon: "tray.and.arrow.down")
                feature("Compare scenarios side by side", icon: "rectangle.split.2x1")
                feature("Share a detailed savings and migration report", icon: "square.and.arrow.up")
            }
            Section {
                if loading {
                    ProgressView("Checking Pro access…")
                } else if unlocked {
                    Label("Pro is unlocked on this Apple Account.", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                } else {
                    if let product {
                        Button("Unlock Pro for \(product.displayPrice)") {
                            Task { await purchase(product) }
                        }
                        .accessibilityIdentifier("pro-unlock")
                        Text("One-time purchase through Apple. No renewals.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("The Pro purchase is currently unavailable.")
                    }
                    Button("Restore purchase") { Task { await restore() } }
                }
                if let notice { Text(notice).foregroundStyle(.secondary) }
            } footer: {
                Text("Pro is optional. Everything that protects your photos stays free.")
            }
            .disabled(busy)
        }
        .navigationTitle("TidyAway Pro")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            defer { loading = false }
            await refreshEntitlement()
            guard !unlocked else { return }
            do {
                product = try await Product.products(for: [Self.productID]).first { $0.type == .nonConsumable }
            } catch {
                notice = "Couldn’t load the store. Try again later."
            }
        }
        .task {
            for await update in StoreKit.Transaction.updates {
                guard case .verified(let transaction) = update, transaction.productID == Self.productID else { continue }
                await refreshEntitlement()
                await transaction.finish()
            }
        }
    }

    private func feature(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
    }

    private func refreshEntitlement() async {
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == Self.productID,
               transaction.productType == .nonConsumable {
                unlocked = true
                return
            }
        }
        unlocked = false
    }

    private func purchase(_ product: Product) async {
        guard !busy else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await refreshEntitlement()
                await transaction.finish()
            case .success(.unverified):
                notice = "The purchase could not be verified."
            case .pending:
                notice = "The purchase is awaiting approval."
            case .userCancelled:
                break
            @unknown default:
                notice = "The purchase could not be completed."
            }
        } catch {
            notice = "The purchase could not be completed."
        }
    }

    private func restore() async {
        guard !busy else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            if !unlocked { notice = "No Pro purchase was found for this Apple Account." }
        } catch {
            notice = "Couldn’t restore purchases. Try again later."
        }
    }
}
