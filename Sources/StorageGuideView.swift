import SwiftUI

struct StorageGuideView: View {
    private enum Goal: String, CaseIterable, Identifiable {
        case space = "Free up phone space"
        case savings = "Lower my storage bill"
        case access = "Keep originals easy to reach"
        var id: Self { self }
    }

    private enum Plan: String, Identifiable {
        case current = "Keep my current setup"
        case optimize = "Optimize iPhone Storage"
        case smaller = "Review a smaller plan"
        case archive = "Explore an independent archive"
        var id: Self { self }
    }

    @Environment(\.locale) private var locale
    @State private var step = 0
    @State private var goal: Goal?
    @State private var usesICloud: Bool?
    @State private var needsQuickAccess: Bool?
    @State private var currentCost = ""
    @State private var usedSpace = ""
    @State private var smallerCapacity = ""
    @State private var smallerCost = ""
    @State private var archiveCost = ""
    @State private var retainedCost = ""
    @State private var migrationCost = ""
    @State private var selectedPlan: Plan?

    private var monthlyCost: Decimal? { amount(currentCost) }
    private var smallerPlanCost: Decimal? { amount(smallerCost) }
    private var archiveMonthlyTotal: Decimal? {
        guard let archive = amount(archiveCost), let retained = amount(retainedCost) else { return nil }
        return archive + retained
    }
    private var canDownsize: Bool {
        guard let used = amount(usedSpace), let capacity = amount(smallerCapacity),
              let current = monthlyCost, let candidate = smallerPlanCost else { return false }
        return capacity > used && candidate < current
    }

    private var recommendation: Plan {
        switch goal {
        case .space: return usesICloud == true ? .optimize : .current
        case .savings:
            if needsQuickAccess == false, let current = monthlyCost, let archive = archiveMonthlyTotal,
               archive < current, let migration = amount(migrationCost) {
                let archiveYear = archive * 12 + migration
                let alternativeYear = (canDownsize ? (smallerPlanCost ?? current) : current) * 12
                if archiveYear < alternativeYear { return .archive }
            }
            return canDownsize ? .smaller : .current
        case .access, nil: return .current
        }
    }

    private var options: [Plan] {
        var plans: [Plan] = [.current]
        if usesICloud == true { plans.append(.optimize) }
        if goal == .savings || canDownsize { plans.append(.smaller) }
        plans.append(.archive)
        return [recommendation] + plans.filter { $0 != recommendation }
    }

    var body: some View {
        List {
            switch step {
            case 0:
                Section("What matters most?") {
                    ForEach(Goal.allCases) { option in
                        Button(option.rawValue) {
                            goal = option
                            step += 1
                        }
                    }
                }
            case 1:
                Section("Do you use iCloud Photos?") {
                    answer("Yes", value: true, field: $usesICloud)
                    answer("No", value: false, field: $usesICloud)
                    answer("I’m not sure", value: nil, field: $usesICloud)
                }
            case 2:
                Section("How quickly do you need your originals?") {
                    answer("I want to open them anytime", value: true, field: $needsQuickAccess)
                    answer("I can wait to restore older photos", value: false, field: $needsQuickAccess)
                    answer("I’m not sure", value: nil, field: $needsQuickAccess)
                }
            case 3:
                Section("What do you pay today?") {
                    numberField("Monthly plan cost", value: $currentCost)
                    numberField("Total storage used (GB)", value: $usedSpace)
                    Text("Include the whole plan’s usage, including shared storage and files other than photos. You can leave unknown answers blank.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Continue") { step += 1 }
                    .disabled(!valid(currentCost) || !valid(usedSpace))
            case 4:
                Section("Do you have a smaller plan in mind?") {
                    numberField("Smaller plan capacity (GB)", value: $smallerCapacity)
                    numberField("Smaller plan monthly cost", value: $smallerCost)
                    Text("Enter prices in the same currency. Leave these blank if you don’t have a quote.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Continue") { step += 1 }
                    .disabled(!valid(smallerCapacity) || !valid(smallerCost))
            case 5:
                Section("Do you have an archive quote?") {
                    numberField("Archive monthly cost", value: $archiveCost)
                    numberField("Monthly cost of plans you’ll keep", value: $retainedCost)
                    numberField("One-time migration cost", value: $migrationCost)
                    Text("Include any subscription overlap in migration cost. Enter 0 if a cost doesn’t apply, or skip this question if you don’t know.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Compare my options") { step += 1 }
                    .disabled(!valid(archiveCost) || !valid(retainedCost) || !valid(migrationCost))
            default:
                Section("Your options") {
                    ForEach(options) { plan in
                        Button {
                            selectedPlan = plan
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                if plan == recommendation {
                                    Text("Suggested starting point").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(plan.rawValue).font(.headline)
                                Text(summary(plan)).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(plan.rawValue)
                    }
                }
            }
            if step > 0 {
                Button(step == 6 ? "Edit answers" : "Previous question") { step -= 1 }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(step < 6 ? "Find a storage plan" : "Compare your options")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedPlan) { plan in
            NavigationStack {
                List {
                    Text(summary(plan))
                    Text(nextStep(plan))
                    Button("Done") { selectedPlan = nil }
                }
                .navigationTitle(plan.rawValue)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func answer(_ title: String, value: Bool?, field: Binding<Bool?>) -> some View {
        Button(title) {
            field.wrappedValue = value
            step += 1
        }
    }

    private func numberField(_ label: String, value: Binding<String>) -> some View {
        TextField(label, text: value)
            .keyboardType(.decimalPad)
    }

    private func amount(_ text: String) -> Decimal? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = locale.decimalSeparator ?? "."
        let parts = cleaned.components(separatedBy: separator)
        guard !cleaned.isEmpty, cleaned.count <= 16, parts.count <= 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return Decimal(string: cleaned, locale: locale)
    }

    private func valid(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || amount(text) != nil
    }

    private func summary(_ plan: Plan) -> String {
        switch plan {
        case .current:
            if let monthlyCost { return "Current monthly cost: \(monthlyCost.formatted()). No migration costs." }
            return "Keep your current access and storage plan."
        case .optimize:
            return "Can free space on this iPhone while keeping originals in iCloud. Your plan cost stays the same."
        case .smaller:
            if canDownsize, let monthlyCost, let smallerPlanCost {
                return "Estimated monthly savings: \((monthlyCost - smallerPlanCost).formatted()) in your currency, if you can switch plans."
            }
            return "Compare a smaller plan with your total usage and current bill before switching."
        case .archive:
            if let total = archiveMonthlyTotal, let current = monthlyCost, let migration = amount(migrationCost) {
                let difference = (current - total) * 12 - migration
                let result = difference >= 0 ? "estimated first-year savings" : "estimated first-year extra cost"
                let magnitude = difference >= 0 ? difference : -difference
                return "\(total.formatted()) per month · \(magnitude.formatted()) \(result), before retrieval fees. Amounts use your entered currency."
            }
            return "Compare storage, migration and restore fees. Confirm how long originals take to retrieve."
        }
    }

    private func nextStep(_ plan: Plan) -> String {
        switch plan {
        case .current:
            "Check your provider’s storage settings when you want to review your usage again."
        case .optimize:
            "On your iPhone, go to Settings → your name → iCloud → Photos → Optimize iPhone Storage. Apple manages which files stay on the phone. Deletions in Apple Photos also sync to iCloud Photos."
        case .smaller:
            "Check the provider’s quoted price, shared usage and headroom for new photos. Make any plan change directly with your provider."
        case .archive:
            "Ask the provider for storage, transfer and retrieval costs. Test restoring an original before considering any removal. Archiving through this app is planned."
        }
    }
}
