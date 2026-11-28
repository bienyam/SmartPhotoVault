import SwiftUI

/// How to keep a Windows (NTFS) drive as it is and archive to it through a Windows PC on the same
/// network. The PC shares a folder on the drive, the iPhone connects to it in Files, and TidyAway
/// uses it as a Home file server. Nothing is reformatted and nothing on the drive is removed.
struct WindowsPCGuideView: View {
    @Environment(\.dismiss) private var dismiss
    /// Shown as a sheet it has its own Done button; pushed inside another sheet it uses that one's.
    var standalone = true

    private let onPC: [LocalizedStringKey] = [
        "Plug the drive into your PC. On the drive, make a folder for your archive, for example **TidyAway Archive**.",
        "Right-click the folder and choose **Properties**. Open the **Sharing** tab and choose **Share**.",
        "Pick your own name, set it to **Read/Write**, then choose **Share**.",
        "In **Settings › Network & internet**, open your Wi-Fi or Ethernet connection and set it to **Private network**. Windows doesn't share folders on a public network.",
        "On the same page, open the connection's properties and note the **IPv4 address**, for example 192.168.1.20.",
        "Keep the PC awake and the drive plugged in while TidyAway copies or brings photos back."
    ]
    private var onPhone: [LocalizedStringKey] {
        [
            "Join the same Wi-Fi as the PC. Open the **Files** app, tap **Browse**, tap **More** (•••) at the top, then **Connect to Server**.",
            "Type **smb://** and the PC's address, for example smb://192.168.1.20, then tap **Connect**.",
            "Choose **Registered User** and sign in with the name and password you use on the PC. With a Microsoft account, that's its email and password, not your PIN.",
            "Back in TidyAway, choose **Home file server**, then **Choose archive folder in Files**, and pick the shared folder."
        ]
    }

    var body: some View {
        if standalone {
            NavigationStack {
                content
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }.accessibilityIdentifier("windows-guide-done")
                        }
                    }
            }
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Use your Windows PC").font(.title2.bold())
                    .accessibilityIdentifier("windows-guide-title")
                Text("Keep your drive formatted for Windows. Plug it into your PC, share a folder on your home network, and TidyAway copies to it over Wi-Fi.")
                    .foregroundStyle(ArchiveStyle.muted)
                section("On your PC", steps: onPC, start: 1)
                section("On your \(Device.name)", steps: onPhone, start: onPC.count + 1)
                Label("TidyAway only adds files to the shared folder. It never deletes or changes anything on your PC or the drive.",
                      systemImage: "checkmark.shield")
                    .font(.subheadline).foregroundStyle(Brand.safe)
                Text("Copying, checking and bringing photos back all need the \(Device.name) and the PC on the same Wi-Fi. Menu names can differ a little between Windows versions.")
                    .font(.footnote).foregroundStyle(ArchiveStyle.muted)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, steps: [LocalizedStringKey], start: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).padding(.top, 4)
            ForEach(steps.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(start + index)").font(.headline)
                        .frame(width: 32, height: 32)
                        .foregroundStyle(ArchiveStyle.onAction)
                        .background(ArchiveStyle.action, in: Circle())
                    Text(steps[index])
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
