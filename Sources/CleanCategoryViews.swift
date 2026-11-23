import SwiftUI

/// Apple doesn't let apps see Messages attachments, so this is a short guide to clearing them in Settings.
struct MessagesAttachmentsGuide: View {
    var body: some View {
        List {
            Section {
                Text("Photos, videos and GIFs you send and receive in Messages are stored inside Messages, separate from your Photos library. They can take a lot of space without showing up in Photos.")
            }
            Section("Clear large attachments") {
                step(1, "Open Settings, then General, then \(Device.name) Storage.")
                step(2, "Wait for the list to load, then tap Messages.")
                step(3, "Tap Review Large Attachments, or open Photos, Videos, or GIFs and Stickers.")
                step(4, "Tap Edit, select what you don't need, and tap Delete.")
            }
            Section("Keep less in future") {
                step(1, "Open Settings, then Apps, then Messages. On older iOS versions, Messages is listed directly in Settings.")
                step(2, "Tap Keep Messages and choose 1 Year or 30 Days.")
                Text("This deletes whole older messages, including the text, not just the attachments. Leave it on Forever if you want to keep your message history.")
                    .font(.footnote).foregroundStyle(Brand.caution)
            }
            Section {
                Text("If Messages in iCloud is on, deleting an attachment removes it from your other Apple devices too. Save anything you want to keep to Photos first: open the conversation, touch and hold the photo, and tap Save.")
                    .font(.footnote)
                Text("Menu names can differ slightly between iOS versions.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Messages attachments")
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.subheadline.bold()).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text)
        }
    }
}
