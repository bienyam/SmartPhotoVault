import SwiftUI

extension CleanCategory {
    /// Bursts stay review-only: deleting a burst's visible photo may not remove its hidden frames,
    /// so people are pointed to Select in Photos instead.
    var allowsRemoval: Bool { self != .bursts }
}

/// The wording people sign off on. The checkbox line is short (disclosure v2); the full text for
/// each kind of deletion sits behind the (i) button. Source: ACTION_AUTHORIZATION.md.
enum RemovalDisclosure {
    static let shortLine = "I understand these leave Photos and iCloud and can be recovered for 30 days."

    static func duplicates(count: Int) -> String {
        "I authorize TidyAway to delete \(count.formatted()) extra \(count == 1 ? "copy" : "copies") from Apple Photos. One identical full-resolution copy of each photo or video stays in Apple Photos and is checked again just before removal, and favorites are never removed. If iCloud Photos is on, these items will also be deleted from iCloud Photos and synced devices. Apple normally keeps deleted items in Recently Deleted for up to 30 days unless they're permanently deleted sooner."
    }

    static func items(count: Int, from source: String) -> String {
        "I authorize TidyAway to delete \(count.formatted()) \(count == 1 ? "item" : "items") I selected from \(source) in Apple Photos. These items are not duplicates: unless I archived them elsewhere, Apple Photos holds the only copy. If iCloud Photos is on, they will also be deleted from iCloud Photos and synced devices. Apple normally keeps deleted items in Recently Deleted for up to 30 days unless they're permanently deleted sooner; after that they can't be recovered."
    }
}

/// A small (i) button that shows more detail in a popover, for people who want to read more.
struct InfoButton: View {
    let title: String
    let text: String
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "info.circle")
                .imageScale(.large)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("More about \(title)")
        .popover(isPresented: $showing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.headline)
                    Text(text).font(.subheadline)
                }
                .padding(20)
                .frame(maxWidth: 360, alignment: .leading)
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// The bar pinned to the bottom of a cleanup list: what's selected, the sign-off, and Delete.
struct RemovalBar: View {
    let count: Int
    let bytes: Int64
    let fullText: String
    let working: Bool
    let message: String?
    @Binding var agreed: Bool
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message {
                Text(message).font(.subheadline).foregroundStyle(Brand.caution)
                    .accessibilityIdentifier("removal-message")
            }
            Text(count == 0 ? "Tap items to select them" : "\(count.formatted()) selected · \(bytes.fileSize)")
                .font(.subheadline.weight(.semibold))
            if count > 0 {
                HStack(alignment: .center, spacing: 4) {
                    Button { agreed.toggle() } label: {
                        Label(RemovalDisclosure.shortLine, systemImage: agreed ? "checkmark.square.fill" : "square")
                            .font(.footnote)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityAddTraits(agreed ? .isSelected : [])
                    .accessibilityIdentifier("signoff")
                    InfoButton(title: "What you're agreeing to", text: fullText)
                }
                Button(action: delete) {
                    Group {
                        if working { ProgressView() } else { Text("Delete \(count.formatted()) \(count == 1 ? "item" : "items")") }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.primary)
                .disabled(!agreed || working)
                .accessibilityIdentifier("delete-selected")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
}
