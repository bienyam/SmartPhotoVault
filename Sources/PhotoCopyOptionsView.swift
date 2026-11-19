import SwiftUI

struct PhotoCopyOptionsView: View {
    private enum Option: String, CaseIterable, Identifiable {
        case optimize = "Keep smaller copies on my iPhone"
        case merge = "Merge duplicates in Apple Photos"
        case archive = "Keep one original in another location"
        case documents = "Free space used by documents"

        var id: Self { self }

        var icon: String {
            switch self {
            case .optimize: "iphone"
            case .merge: "square.on.square"
            case .archive: "externaldrive"
            case .documents: "folder"
            }
        }

        var benefit: String {
            switch self {
            case .optimize: "Free phone space while browsing in Apple Photos."
            case .merge: "Combine duplicates within your Apple Photos library."
            case .archive: "Work out which full-resolution copy to retain."
            case .documents: "Remove offline downloads while keeping cloud files."
            }
        }
    }

    private let slate = Color(red: 0.19, green: 0.32, blue: 0.44)
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Where should your originals live?")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                ForEach(Option.allCases) { option in
                    NavigationLink {
                        details(option)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: option.icon)
                                .font(.title2)
                                .frame(width: 32)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.rawValue).font(.headline)
                                Text(option.benefit).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.forward").accessibilityHidden(true)
                        }
                        .padding(16)
                        .foregroundStyle(.primary)
                        .background(colorScheme == .dark ? Color(uiColor: .secondarySystemBackground) :
                            Color(red: 0.88, green: 0.92, blue: 0.96), in: RoundedRectangle(cornerRadius: 17))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(colorScheme == .dark ? Color(uiColor: .systemBackground) : Color(red: 0.99, green: 0.98, blue: 0.96))
        .navigationTitle("Decide which copies to keep")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func details(_ option: Option) -> some View {
        List {
            switch option {
            case .optimize:
                Section("What stays where") {
                    LabeledContent("Full-resolution originals", value: "iCloud Photos")
                    LabeledContent("Smaller copies", value: "Managed by Apple on this iPhone")
                    Text("iPhone and iCloud Photos are one synced library. Deleting an item in Photos also removes it from synced devices. Storage savings depend on what Apple keeps locally.")
                }
                Link("See Apple’s Optimize Storage steps", destination: URL(string: "https://support.apple.com/en-us/105061")!)
            case .merge:
                Section("How to merge") {
                    Text("Open Apple Photos → Collections → Utilities → Duplicates. Review the items, then tap Merge for the group you choose.")
                    Text("The action affects your Apple Photos library and its synced copies. It does not merge copies in a separate cloud account.")
                }
                Link("See Apple’s merge instructions", destination: URL(string: "https://support.apple.com/guide/iphone/iph1978d9c23/ios")!)
            case .archive:
                Section("Before removing any copy") {
                    Label("Choose the account or drive that will hold the original.", systemImage: "1.circle")
                    Label("Verify the full-resolution file and required parts, such as the video in a Live Photo.", systemImage: "2.circle")
                    Label("Restore and open an original from that location.", systemImage: "3.circle")
                    Label("Review exactly what would be removed and where.", systemImage: "4.circle")
                }
                Section("What this app supports today") {
                    Text("The app can compare storage costs and review readable local copies. Copying to an independent archive, verifying remote originals, and removing copies are planned.")
                    Text("A single retained original has no independent backup. A future archive preview would appear inside this app.")
                }
            case .documents:
                Section("iCloud Drive in Files") {
                    Text("In Files → Browse → iCloud Drive, touch and hold a downloaded file and choose Remove Download if it appears. This removes the iPhone download while keeping the iCloud file. Confirm the file is synced first.")
                    Text("Delete removes the iCloud Drive file across devices. Files under On My iPhone may have no other copy.")
                }
                Section("OneDrive") {
                    Text("In the OneDrive app, choose Remove from Offline for a file you no longer need offline. The online file stays in OneDrive.")
                }
                Link("See Apple’s Files instructions", destination: URL(string: "https://support.apple.com/en-ie/104953")!)
            }
        }
        .tint(slate)
        .navigationTitle(option.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }
}
