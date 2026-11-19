import StoreKit
import SwiftUI

struct StorageScenario: Codable, Identifiable {
    struct Entry: Codable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    var id = UUID()
    var date = Date()
    let goal: String
    let recommendation: String
    let inputs: [Entry]
    let alternatives: [Entry]

    var report: String {
        let sections = [inputs, alternatives].map { entries in
            entries.map { "\($0.label) — \($0.value)" }.joined(separator: "\n")
        }
        return """
        \(date.formatted())
        Goal — \(goal)
        Suggested option — \(recommendation)

        Inputs
        \(sections[0])

        Alternatives
        \(sections[1])
        """
    }
}

struct StorageComparisonView: View {
    var current: StorageScenario? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var saved: [StorageScenario] = []
    @State private var selectedID: UUID?
    @State private var product: Product?
    @State private var unlocked = false
    @State private var loading = true
    @State private var busy = false
    @State private var savedCurrent = false
    @State private var storageAvailable = true
    @State private var notice: String?

    private static let productID = "com.bienyam.SmartPhotoVault.storagepro"

    private var selected: StorageScenario? { saved.first { $0.id == selectedID } }

    var body: some View {
        List {
            if loading {
                ProgressView("Checking Pro access…")
            } else if let current {
                if unlocked { comparisons(current) }
                else { purchaseOptions }
            } else {
                savedLibrary
            }
            if let notice { Text(notice).foregroundStyle(.secondary) }
        }
        .navigationTitle(current == nil ? "Saved comparisons" : "Storage Comparison Pro")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            defer { loading = false }
            load()
            await refreshEntitlement()
            if !unlocked, current != nil {
                do {
                    product = try await Product.products(for: [Self.productID]).first { $0.type == .nonConsumable }
                } catch {
                    notice = "Couldn’t load the store. Try again later."
                }
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

    private var purchaseOptions: some View {
        Section {
            Text("Save your scenarios, compare them side by side, and share a detailed report.")
            if let product {
                Button("Unlock Pro for \(product.displayPrice)") {
                    Task { await purchase(product) }
                }
                Text("One-time purchase").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("The Pro purchase is currently unavailable.")
            }
            Button("Restore purchase") {
                Task { await restore() }
            }
        }
        .disabled(busy)
    }

    private var savedLibrary: some View {
        Section {
            if saved.isEmpty {
                Text("No saved comparisons yet.")
            }
            ForEach(saved) { scenario in
                NavigationLink {
                    List {
                        Text(scenario.report)
                        if unlocked {
                            ShareLink(item: scenario.report) { Label("Share report", systemImage: "square.and.arrow.up") }
                        }
                    }
                    .navigationTitle("Saved scenario")
                } label: {
                    VStack(alignment: .leading) {
                        Text(scenario.goal)
                        Text(scenario.date.formatted()).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                var remaining = saved
                remaining.remove(atOffsets: offsets)
                _ = persist(remaining)
            }
        }
    }

    private func comparisons(_ current: StorageScenario) -> some View {
        Group {
            Section {
                Button(savedCurrent ? "Current scenario saved" : "Save current scenario") {
                    if persist([current] + saved) { savedCurrent = true }
                }
                .disabled(savedCurrent || !storageAvailable)
                if !saved.isEmpty {
                    Picker("Compare with", selection: $selectedID) {
                        Text("Current only").tag(nil as UUID?)
                        ForEach(saved.filter { $0.id != current.id }) { scenario in
                            Text("\(scenario.goal) · \(scenario.date.formatted())").tag(Optional(scenario.id))
                        }
                    }
                }
                ShareLink(item: report(current)) {
                    Label("Share comparison report", systemImage: "square.and.arrow.up")
                }
            }
            Section("Comparison") {
                if let selected {
                    comparisonRow("Scenario", "Current", selected.date.formatted(date: .abbreviated, time: .omitted))
                    comparisonRow("Goal", current.goal, selected.goal)
                    comparisonRow("Suggested option", current.recommendation, selected.recommendation)
                    ForEach(current.inputs) { entry in
                        comparisonRow(entry.label, entry.value, selected.inputs.first { $0.label == entry.label }?.value ?? "Unknown")
                    }
                    if storageAvailable {
                        Button("Remove saved scenario", role: .destructive) {
                            if persist(saved.filter { $0.id != selected.id }) { selectedID = nil }
                        }
                    }
                } else {
                    LabeledContent("Suggested option", value: current.recommendation)
                    ForEach(current.inputs) { entry in LabeledContent(entry.label, value: entry.value) }
                }
            }
            Section("Alternatives") {
                ForEach(current.alternatives) { entry in
                    if let selected {
                        comparisonRow(entry.label, entry.value, selected.alternatives.first { $0.label == entry.label }?.value ?? "Not assessed")
                    } else {
                        LabeledContent(entry.label, value: entry.value)
                    }
                }
                if let selected {
                    ForEach(selected.alternatives.filter { alternative in
                        !current.alternatives.contains { $0.label == alternative.label }
                    }) { entry in
                        comparisonRow(entry.label, "Not assessed", entry.value)
                    }
                }
            }
        }
    }

    private func comparisonRow(_ label: String, _ first: String, _ second: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.headline)
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            layout {
                comparisonValue("Current", first)
                comparisonValue("Saved", second)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func comparisonValue(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption)
            Text(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func report(_ current: StorageScenario) -> String {
        var content = "SmartPhotoVault storage comparison\n\nCurrent scenario\n\(current.report)"
        if let selected { content += "\n\nSaved scenario\n\(selected.report)" }
        return content + "\n\nEstimates use the values and currency entered for each scenario. Verify provider costs and restore terms before making changes."
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

    private func storageURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return directory.appendingPathComponent("storage-comparisons.json")
    }

    private func load() {
        do {
            let url = try storageURL()
            if FileManager.default.fileExists(atPath: url.path) {
                saved = try JSONDecoder().decode([StorageScenario].self, from: Data(contentsOf: url))
            }
        } catch {
            storageAvailable = false
            notice = "Saved comparisons could not be opened."
        }
    }

    private func persist(_ scenarios: [StorageScenario]) -> Bool {
        do {
            try JSONEncoder().encode(scenarios).write(to: storageURL(), options: [.atomic, .completeFileProtection])
            saved = scenarios
            notice = nil
            return true
        } catch {
            notice = "Couldn’t update your saved comparisons."
            return false
        }
    }
}
