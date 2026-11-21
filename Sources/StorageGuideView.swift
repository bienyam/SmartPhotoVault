import SwiftUI

struct StorageGuideView: View {
    private let snapshot: ScanSnapshot?

    init(snapshot: ScanSnapshot? = nil) {
        self.snapshot = snapshot
    }

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
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsAdvanced = false
    @State private var showsQuickBill = false
    @State private var lastQuestion = 0
    @State private var step = 0
    @State private var goal: Goal?
    @State private var usesICloud: Bool?
    @State private var needsQuickAccess: Bool?
    @State private var currentCost = ""
    @State private var currencyCode = Locale.current.currency?.identifier ?? "USD"
    @State private var usedSpace = ""
    @State private var smallerCapacity = ""
    @State private var smallerCost = ""
    @State private var archiveCost = ""
    @State private var retainedCost = ""
    @State private var migrationCost = ""
    @State private var annualRetrievalCost = ""
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
               archive < current, let migration = amount(migrationCost), let retrieval = amount(annualRetrievalCost) {
                let archiveYear = archive * 12 + migration + retrieval
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
        Group {
            if showsAdvanced {
                advancedAnalysis
            } else {
                quickWins
            }
        }
        .navigationTitle(showsAdvanced ? analysisTitle : "Analyze storage & cost")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedPlan) { plan in
            NavigationStack {
                List {
                    Text(summary(plan))
                    if plan == .archive {
                        NavigationLink("Choose archive storage") { PhotoArchiveView(snapshot: snapshot) }
                    } else if plan == .optimize {
                        NavigationLink("Review actions for this iPhone") { PhotoCopyOptionsView(snapshot: snapshot) }
                    } else {
                        Text(nextStep(plan))
                    }
                    Button("Done") { selectedPlan = nil }
                }
                .navigationTitle(plan.rawValue)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showsQuickBill) { quickBill }
    }

    private var analysisTitle: String {
        step < 6 ? "Advanced analysis" : step == 6 ? "Storage & cost analysis" : "Compare alternatives"
    }

    private var accent: Color { Brand.primary }

    private var powder: Color {
        colorScheme == .dark
            ? Brand.surface
            : Brand.surface
    }

    private var quickWins: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 34, weight: .medium))
                        .accessibilityHidden(true)
                    Text("Make room for more").font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Get a quick win for your phone space or storage bill.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(powder.gradient, in: RoundedRectangle(cornerRadius: 24))

                Button {
                    selectedPlan = .optimize
                } label: {
                    quickCard(
                        "Free up phone space",
                        benefit: "See how iCloud Photos can keep smaller copies on this iPhone.",
                        icon: "internaldrive",
                        prominent: true
                    )
                }
                .accessibilityIdentifier("Free up phone space")

                if let snapshot {
                    let groupCount = snapshot.groups.count
                    if groupCount > 0 {
                        NavigationLink {
                            DuplicateResultsView(snapshot: snapshot)
                        } label: {
                            quickCard(
                                "Review exact matches",
                                benefit: groupCount == 1
                                    ? "Your latest scan found one group of matching files."
                                    : "Your latest scan found \(groupCount.formatted()) groups of matching files.",
                                icon: "square.on.square"
                            )
                        }
                    }
                }

                NavigationLink {
                    PhotoCopyOptionsView(snapshot: snapshot)
                } label: {
                    quickCard(
                        "Decide which copies to keep",
                        benefit: "Choose how to use iCloud Photos, merge duplicates, or keep an independent original.",
                        icon: "photo.on.rectangle"
                    )
                }
                .accessibilityIdentifier("Decide which copies to keep")

                Button {
                    showsQuickBill = true
                } label: {
                    quickCard(
                        "Check my storage bill",
                        benefit: "Turn a monthly price into a yearly cost in one step.",
                        icon: "creditcard"
                    )
                }
                .accessibilityIdentifier("Check my storage bill")

                NavigationLink {
                    SelectedFilesAnalysisView()
                } label: {
                    quickCard(
                        "Analyze selected files",
                        benefit: "See which documents are largest across the locations you choose.",
                        icon: "folder"
                    )
                }
                .accessibilityIdentifier("Analyze selected files")

                Button {
                    showsAdvanced = true
                } label: {
                    quickCard(
                        "Advanced analysis",
                        benefit: "Compare your current setup, a smaller plan, or an archive.",
                        icon: "slider.horizontal.3"
                    )
                }
                .accessibilityIdentifier("Advanced analysis")

                NavigationLink("Saved comparisons") { StorageComparisonView() }
                    .padding(.vertical, 8)
            }
            .frame(maxWidth: 520)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .background(colorScheme == .dark ? Color(uiColor: .systemBackground) : Brand.background)
    }

    private func quickCard(_ title: String, benefit: String, icon: String, prominent: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(benefit).font(.subheadline)
                    .foregroundStyle(prominent ? Color.white : Color.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.footnote.bold()).accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .padding(16)
        .foregroundStyle(prominent ? Color.white : Color.primary)
        .background(prominent ? accent : powder, in: RoundedRectangle(cornerRadius: 17))
        .contentShape(RoundedRectangle(cornerRadius: 17))
    }

    private var quickBill: some View {
        NavigationStack {
            List {
                Section("What do you pay per month?") {
                    numberField("Monthly plan cost", value: $currentCost)
                    TextField("Currency code", text: $currencyCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                if let monthlyCost, validCurrency {
                    Section("Estimated yearly cost") {
                        Text("\((monthlyCost * 12).formatted()) \(enteredCurrency)")
                            .font(.largeTitle.bold())
                        Text("Based on the monthly amount you entered. Taxes, one-time fees and other plans may change the total.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Compare storage options") {
                            goal = .savings
                            step = 3
                            showsAdvanced = true
                            showsQuickBill = false
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Check my storage bill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showsQuickBill = false }
                }
            }
        }
    }

    private var validCurrency: Bool {
        enteredCurrency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil
    }

    private var advancedAnalysis: some View {
        List {
            if step < 6 {
                Section {
                    ProgressView(value: Double(step + 1), total: 6) {
                        Text("Question \(step + 1) of 6")
                    }
                }
            }
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
                    TextField("Currency code (for example, USD)", text: $currencyCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Text("Include the whole plan’s usage, including shared storage and files other than photos. You can leave unknown answers blank.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Continue") { step += 1 }
                    .disabled(!valid(currentCost) || !valid(usedSpace) || !validCurrency)
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
                    numberField("Estimated yearly retrieval fees", value: $annualRetrievalCost)
                    Text("Include any subscription overlap in migration cost. Enter 0 if a cost doesn’t apply, or skip this question if you don’t know.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("See my analysis") { showAnalysis() }
                    .disabled(!validInputs)
            case 6:
                Section("Your current setup") {
                    if let goal { LabeledContent("Your goal", value: goal.rawValue) }
                    LabeledContent("Monthly cost", value: monthlyCost?.formatted() ?? "Unknown")
                    LabeledContent("Storage used", value: amount(usedSpace).map { "\($0.formatted()) GB" } ?? "Unknown")
                }
                Section("What stands out") {
                    ForEach(findings, id: \.self) { finding in
                        Text(finding)
                    }
                }
                Section {
                    Button("Compare alternatives") { step += 1 }
                } footer: {
                    Text("This analysis uses your answers. It has no access to provider bills or device storage settings.")
                }
            default:
                Section("Alternatives") {
                    ForEach(options) { plan in
                        Button {
                            selectedPlan = plan
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                if plan == recommendation {
                                    Text("Suggested for your goal").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(plan.rawValue).font(.headline)
                                Text(summary(plan)).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(plan.rawValue)
                    }
                }
                Section {
                    NavigationLink("Save, compare & share with Pro") {
                        StorageComparisonView(current: scenario)
                    }
                }
            }
            if (1...4).contains(step) {
                Button("See my analysis now") { showAnalysis() }
                    .disabled(!validInputs)
            }
            if step > 0 {
                Button(step == 7 ? "Back to analysis" : step == 6 ? "Edit answers" : "Previous question") {
                    step = step == 6 ? lastQuestion : step - 1
                }
            }
            Button("Back to quick wins") { showsAdvanced = false }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var validInputs: Bool {
        validCurrency && [currentCost, usedSpace, smallerCapacity, smallerCost, archiveCost,
                          retainedCost, migrationCost, annualRetrievalCost].allSatisfy(valid)
    }

    private func showAnalysis() {
        lastQuestion = step
        step = 6
    }

    private var scenario: StorageScenario {
        let inputs: [(String, Decimal?)] = [
            ("Current monthly cost", monthlyCost),
            ("Storage used (GB)", amount(usedSpace)),
            ("Smaller plan capacity (GB)", amount(smallerCapacity)),
            ("Smaller plan monthly cost", smallerPlanCost),
            ("Archive monthly cost", amount(archiveCost)),
            ("Monthly cost of plans kept", amount(retainedCost)),
            ("One-time migration cost", amount(migrationCost)),
            ("Estimated yearly retrieval fees", amount(annualRetrievalCost))
        ]
        return StorageScenario(
            goal: goal?.rawValue ?? "Unknown",
            recommendation: recommendation.rawValue,
            inputs: [StorageScenario.Entry(label: "Currency", value: enteredCurrency)] + inputs.map { label, value in
                StorageScenario.Entry(label: label, value: value?.formatted() ?? "Unknown")
            } + [
                StorageScenario.Entry(label: "Uses iCloud Photos", value: usesICloud.map { $0 ? "Yes" : "No" } ?? "Unknown"),
                StorageScenario.Entry(label: "Needs immediate access", value: needsQuickAccess.map { $0 ? "Yes" : "No" } ?? "Unknown")
            ],
            alternatives: options.map {
                let total = firstYearCost($0).map { "First-year cost: \($0.formatted()) \(enteredCurrency)." } ?? "First-year total unknown."
                return StorageScenario.Entry(label: $0.rawValue, value: "\(total) \(summary($0)) \(nextStep($0))")
            }
        )
    }

    private var enteredCurrency: String {
        currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func firstYearCost(_ plan: Plan) -> Decimal? {
        switch plan {
        case .current, .optimize: return monthlyCost.map { $0 * 12 }
        case .smaller: return smallerPlanCost.map { $0 * 12 }
        case .archive:
            guard let monthly = archiveMonthlyTotal, let migration = amount(migrationCost),
                  let retrieval = amount(annualRetrievalCost) else { return nil }
            return monthly * 12 + migration + retrieval
        }
    }

    private var findings: [String] {
        var results: [String] = []
        if goal == .space, usesICloud == true {
            results.append("Check whether Optimize iPhone Storage is on. If full-size originals are staying on the phone, this setting may reduce local usage without a plan change.")
        }
        if let used = amount(usedSpace), let capacity = amount(smallerCapacity), used >= capacity {
            results.append("Your current usage leaves no room on the smaller plan. Switching at this usage would leave no headroom.")
        } else if canDownsize, let current = monthlyCost, let smaller = smallerPlanCost {
            results.append("Based on your quote, the smaller plan fits your reported usage and could save \((current - smaller).formatted()) per month in your currency. Check how much room you need for growth.")
        }
        if let total = archiveMonthlyTotal, let current = monthlyCost, let migration = amount(migrationCost) {
            if total >= current {
                results.append("The archive plus the plans you’d keep would cost at least as much each month as your current setup.")
            } else if (current - total) * 12 <= migration + (amount(annualRetrievalCost) ?? 0) {
                results.append("The archive has a lower monthly cost, but the costs you entered would absorb the first year’s savings.")
            } else if amount(annualRetrievalCost) == nil {
                results.append("The archive could cost less, but there’s no retrieval estimate yet. Check the cost and wait time for getting originals back.")
            } else {
                results.append("The archive quote shows potential first-year savings after the migration and retrieval costs you entered. Check how long it takes to get originals back.")
            }
        }
        if needsQuickAccess == true {
            results.append("You want to open originals anytime. A slow-restore archive may be a poor fit for photos you use often.")
        }
        if goal == .savings && (monthlyCost == nil || amount(usedSpace) == nil) {
            results.append("Add your current monthly bill and total storage used to assess whether you’re paying for more space than you need.")
        }
        if results.isEmpty {
            results.append("Your answers do not identify a clear inefficiency. Compare the alternatives or add a provider quote to check for savings.")
        }
        return results
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
            return "If you use iCloud Photos and have enough iCloud storage, optimizing may free space on this iPhone while keeping originals in iCloud."
        case .smaller:
            if canDownsize, let monthlyCost, let smallerPlanCost {
                return "Estimated monthly savings: \((monthlyCost - smallerPlanCost).formatted()) in your currency, if you can switch plans."
            }
            return "Compare a smaller plan with your total usage and current bill before switching."
        case .archive:
            if let total = archiveMonthlyTotal, let current = monthlyCost, let migration = amount(migrationCost) {
                let retrieval = amount(annualRetrievalCost)
                let difference = (current - total) * 12 - migration - (retrieval ?? 0)
                let result = difference >= 0 ? "estimated first-year savings" : "estimated first-year extra cost"
                let magnitude = difference >= 0 ? difference : -difference
                let qualification = retrieval == nil ? "before retrieval fees" : "including your retrieval estimate"
                return "\(total.formatted()) per month · \(magnitude.formatted()) \(result), \(qualification)."
            }
            return "Compare storage, migration and restore fees. Confirm how long originals take to retrieve."
        }
    }

    private func nextStep(_ plan: Plan) -> String {
        switch plan {
        case .current:
            "Check your provider’s storage settings when you want to review your usage again."
        case .optimize:
            "On your iPhone, go to Settings → your name → iCloud → Photos. Look for Optimize Storage, sometimes under iPhone Storage. Apple manages which files stay on your phone. Deletions in Apple Photos also sync to iCloud Photos."
        case .smaller:
            "Check the provider’s quoted price, shared usage and headroom for new photos. Make any plan change directly with your provider."
        case .archive:
            "Choose an archive folder in the app, compare space, and test a restore before considering any removal. Include your provider’s transfer and retrieval costs when comparing."
        }
    }
}
