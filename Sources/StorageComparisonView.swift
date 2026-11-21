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
    @EnvironmentObject private var pro: ProStore
    @State private var savedCurrent = false
    @State private var storageAvailable = true
    @State private var notice: String?

    private var selected: StorageScenario? { saved.first { $0.id == selectedID } }

    var body: some View {
        List {
            if pro.checking {
                ProgressView("Checking Pro…")
            } else if !pro.unlocked {
                purchaseOptions
            } else if let current {
                comparisons(current)
            } else {
                savedLibrary
            }
            if let notice { Text(notice).foregroundStyle(.secondary) }
        }
        .navigationTitle(current == nil ? "Saved comparisons" : "Compare and save")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private var purchaseOptions: some View {
        Section {
            Text("Save storage plans, compare them side by side, and share a report. Part of TidyAway Pro.")
            ProPurchaseControls()
        }
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
                        if pro.unlocked {
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
        var content = "TidyAway storage comparison\n\nCurrent scenario\n\(current.report)"
        if let selected { content += "\n\nSaved scenario\n\(selected.report)" }
        return content + "\n\nEstimates use the values and currency entered for each scenario. Verify provider costs and restore terms before making changes."
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
