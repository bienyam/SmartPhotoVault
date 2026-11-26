import SwiftUI

/// The drive the person chose, so TidyAway can show it again without choosing it each time.
/// iOS doesn't let apps find drives by themselves; the person picks it once in Apple's Files window.
struct SavedDrive: Codable, Equatable {
    let name: String
    let bookmark: Data

    private static let key = "savedDrive"

    static func load(_ store: UserDefaults = .standard) -> SavedDrive? {
        store.data(forKey: key).flatMap { try? JSONDecoder().decode(SavedDrive.self, from: $0) }
    }

    func save(_ store: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { store.set(data, forKey: Self.key) }
    }

    /// Forgets the drive on this iPhone. Nothing on the drive changes.
    static func forget(_ store: UserDefaults = .standard) { store.removeObject(forKey: key) }

    static func remember(_ folder: URL, _ store: UserDefaults = .standard) {
        let active = folder.startAccessingSecurityScopedResource()
        defer { if active { folder.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? folder.bookmarkData() else { return }
        SavedDrive(name: folder.lastPathComponent, bookmark: bookmark).save(store)
    }
}

/// What TidyAway can see of the saved drive right now.
struct DriveStatus: Equatable, Sendable {
    let url: URL
    let format: String?
    let available: Int64
    let total: Int64

    var usedFraction: Double { total > 0 ? min(1, max(0, Double(total - available) / Double(total))) : 0 }

    /// Nil when the drive isn't plugged in, or iOS no longer lets TidyAway open it.
    static func read(_ drive: SavedDrive) -> DriveStatus? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: drive.bookmark, bookmarkDataIsStale: &stale) else { return nil }
        let active = url.startAccessingSecurityScopedResource()
        defer { if active { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey, .volumeAvailableCapacityKey,
                                                             .volumeTotalCapacityKey]),
              let available = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity, total > 0 else { return nil }
        return DriveStatus(url: url, format: values.volumeLocalizedFormatDescription, available: Int64(available), total: Int64(total))
    }
}

/// Keeps the drive's status up to date while it is on screen.
@MainActor
final class DriveModel: ObservableObject {
    @Published private(set) var drive = SavedDrive.load()
    @Published private(set) var status: DriveStatus?

    func refresh() async {
        drive = SavedDrive.load()
        guard let drive else {
            status = nil
            return
        }
        let found = await Task.detached(priority: .utility) { DriveStatus.read(drive) }.value
        if status != found { status = found }
    }

    /// iOS sends no message when a drive is plugged in or out, so look every few seconds.
    func watch() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    func forget() {
        SavedDrive.forget()
        drive = nil
        status = nil
    }
}

/// The drive, shown in TidyAway: name, space, format, whether it's connected.
struct DriveCard: View {
    let name: String
    let status: DriveStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill").font(.system(size: 34)).foregroundStyle(ArchiveStyle.link)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.title3.bold()).foregroundStyle(ArchiveStyle.ink)
                    Label(status == nil ? "Not connected" : "Connected", systemImage: status == nil ? "circle.dashed" : "circle.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(status == nil ? ArchiveStyle.muted : ArchiveStyle.safeText)
                }
                Spacer(minLength: 0)
            }
            if let status {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.gray.opacity(0.28))
                        Capsule().fill(ArchiveStyle.action).frame(width: max(8, geo.size.width * status.usedFraction))
                    }
                }
                .frame(height: 12)
                .accessibilityHidden(true)
                Text("\(status.available.fileSize) free of \(status.total.fileSize)\(status.format.map { " · \($0)" } ?? "")")
                    .font(.footnote).foregroundStyle(ArchiveStyle.muted)
            } else {
                Text("Plug it in. If it stays like this, choose it again.")
                    .font(.footnote).foregroundStyle(ArchiveStyle.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("drive-card")
    }
}

/// How to reach a drive in Apple's Files window, and what to try when it isn't there.
struct DriveHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let path: [LocalizedStringKey] = [
        "Plug the drive into your \(Device.name). (An \(Device.name) with Lightning needs Apple's camera adapter.)",
        "Tap **Choose archive folder in Files**.",
        "Tap **Browse** at the bottom. If you don't see **Locations**, tap **Browse** again.",
        "Under **Locations**, tap your drive.",
        "Tap **Open**."
    ]
    private let fixes: [(icon: String, title: String, text: String)] = [
        ("bolt.fill", "It needs more power", "Hard drives that spin, and some SSDs, need their own power. Try a powered USB hub."),
        ("cable.connector", "The cable only charges", "Some USB-C cables don't carry data. Try the cable that came with the drive."),
        ("square.split.2x1", "It has more than one partition", "\(Device.name) only shows drives with a single data partition."),
        ("pc", "It's formatted for Windows (NTFS)", "Apple doesn't list NTFS as supported, so it may not appear, or may be read-only. Formats that work: exFAT, APFS, Mac OS Extended, FAT32 (no file over 4 GB)."),
        ("lock.fill", "It's locked", "Open the Files app, tap the drive, and enter its password. Then come back.")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Where to find it").font(.title2.bold())
                    ForEach(path.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)").font(.headline)
                                .frame(width: 32, height: 32)
                                .foregroundStyle(.white)
                                .background(Color(red: 0.722, green: 0.267, blue: 0.102), in: Circle())
                            Text(path[index])
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text("\(Device.name) doesn't let apps find drives by themselves, so you choose it there once. After that TidyAway shows it here.")
                        .font(.footnote).foregroundStyle(ArchiveStyle.muted)
                    Text("Still not there?").font(.title2.bold()).padding(.top, 6)
                    ForEach(fixes.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: fixes[index].icon).font(.title3).frame(width: 32)
                                .foregroundStyle(ArchiveStyle.link).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fixes[index].title).font(.headline)
                                Text(fixes[index].text).font(.subheadline).foregroundStyle(ArchiveStyle.muted)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Label("Changing a drive's format erases everything on it. Copy what you need first. \(Device.name)s with USB-C can erase a drive in Files: touch and hold it, then tap Erase. With Lightning, use a computer.",
                          systemImage: "exclamationmark.triangle")
                        .font(.subheadline).foregroundStyle(Brand.caution)
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Don't see your drive?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("drive-help-done")
                }
            }
        }
    }
}

/// Everything TidyAway can do with the drive, in one place.
struct DriveScreen: View {
    @ObservedObject var model: DriveModel
    let copyHere: (URL) -> Void
    @State private var records: [ArchivedRecord] = []
    @State private var checking = false
    @State private var checked = 0
    @State private var exact = 0
    @State private var problems: [String] = []
    @State private var finished = false
    @State private var showFolder = false
    @State private var showHelp = false
    @State private var confirmForget = false
    @Environment(\.dismiss) private var dismiss

    private var bytes: Int64 { records.reduce(0) { $0 + $1.totalBytes } }

    var body: some View {
        List {
            if let drive = model.drive {
                Section {
                    DriveCard(name: drive.name, status: model.status)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    if let status = model.status {
                        Button("Copy to this drive") { copyHere(status.url) }
                            .buttonStyle(ArchiveButtonStyle())
                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                            .accessibilityIdentifier("drive-copy")
                    }
                }
                Section("On this drive") {
                    if records.isEmpty {
                        Text("Nothing copied here by TidyAway yet.")
                    } else {
                        LabeledContent("Copies", value: "\(records.count.formatted()) · \(bytes.fileSize)")
                        ForEach(ArchiveDay.group(records)) { day in
                            NavigationLink {
                                ArchivedDayView(day: day, reload: load)
                            } label: {
                                LabeledContent(day.day.formatted(date: .abbreviated, time: .omitted),
                                               value: "\(day.records.count.formatted()) · \(day.bytes.fileSize)")
                            }
                        }
                    }
                }
                if !records.isEmpty {
                    Section {
                        if checking {
                            ProgressView(value: Double(checked), total: Double(records.count)) {
                                Text("Checking \(checked.formatted()) of \(records.count.formatted())")
                            }
                        } else {
                            Button("Check every copy on this drive") { Task { await check() } }
                                .disabled(model.status == nil)
                                .accessibilityIdentifier("drive-check")
                        }
                        if finished {
                            Label("\(exact.formatted()) of \(records.count.formatted()) are intact", systemImage: problems.isEmpty ? "checkmark.shield.fill" : "exclamationmark.triangle")
                                .foregroundStyle(problems.isEmpty ? Brand.safe : Brand.caution)
                            ForEach(problems, id: \.self) { Text($0).font(.footnote) }
                        }
                    } footer: {
                        Text("Reads each copy in full and compares it with what was archived. Changes nothing.")
                    }
                }
                Section {
                    Button("Choose a different drive or folder") { showFolder = true }
                    Button("Don't see your drive?") { showHelp = true }
                    Button("Forget this drive", role: .destructive) { confirmForget = true }
                        .accessibilityIdentifier("drive-forget")
                } footer: {
                    Text("Forgetting only removes it from TidyAway. Nothing on the drive changes.")
                }
                .disabled(checking)
            } else {
                Text("No drive chosen yet.")
            }
        }
        .navigationTitle("Your drive")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(checking)
        .task { await model.watch() }
        .onAppear(perform: load)
        .sheet(isPresented: $showHelp) { DriveHelpView() }
        .fileImporter(isPresented: $showFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            SavedDrive.remember(folder)
            Task {
                await model.refresh()
                load()
            }
        }
        .confirmationDialog("Forget this drive?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                model.forget()
                dismiss()
            }
        } message: {
            Text("Nothing on the drive changes. You can choose it again any time.")
        }
    }

    private func load() {
        guard let drive = model.drive else { return }
        records = ((try? InventoryStore.openDefault().archived()) ?? [])
            .filter { $0.folderName == drive.name && $0.driveFileID == nil && !$0.viaHomeServer }
        finished = false
    }

    private func check() async {
        guard let status = model.status, !checking else { return }
        checking = true
        finished = false
        checked = 0
        exact = 0
        problems = []
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            checking = false
        }
        for record in records {
            guard !Task.isCancelled else { return }
            let folder = status.url
            // Every file of the item: one for most, several for a Live Photo or an edited photo.
            let files = record.files.map { (name: $0.name, expected: ArchiveProver.fingerprint(of: $0)) }
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    for file in files {
                        _ = try VerifiedArchive.checkCopy(named: file.name, in: folder, expected: file.expected, wifi: nil, offDevice: false)
                    }
                }
            }.value
            switch result {
            case .success: exact += 1
            case .failure(let error): problems.append("\(record.name) — \(error.localizedDescription)")
            }
            checked += 1
        }
        try? InventoryStore.openDefault().log("Checked \(checked) archive copies on a drive: \(exact) intact, \(problems.count) not.")
        finished = true
    }
}
