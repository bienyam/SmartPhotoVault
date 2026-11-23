import Foundation
import SwiftUI

/// Where archive copies go inside TidyAway's own folder in an online service. TidyAway can only
/// reach its own folder, so every folder here is inside it: OneDrive and Dropbox › Apps › TidyAway,
/// Google Drive › TidyAway Archive.
enum OnlinePlace: String, CaseIterable, Sendable, Identifiable {
    case google, oneDrive, dropbox

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: "Google Drive"
        case .oneDrive: "OneDrive"
        case .dropbox: "Dropbox"
        }
    }

    /// TidyAway's own folder, as the person sees it in the service.
    var rootPath: String {
        switch self {
        case .google: "Google Drive › \(GoogleDriveConfig.folderName)"
        case .oneDrive: "OneDrive › Apps › TidyAway"
        case .dropbox: "Dropbox › Apps › TidyAway"
        }
    }

    init(_ service: CloudService) { self = service == .oneDrive ? .oneDrive : .dropbox }
}

/// A folder inside TidyAway's own folder. The root is an empty path.
struct OnlineFolder: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// OneDrive and Dropbox: the path inside TidyAway's folder, such as "Trips/Beach". Google Drive: the folder ID.
    let id: String
    /// The path inside TidyAway's folder, for showing. Empty for TidyAway's folder itself.
    let path: String

    static let root = OnlineFolder(id: "", path: "")
    var isRoot: Bool { path.isEmpty }
    var name: String { path.split(separator: "/").last.map(String.init) ?? "" }

    func shown(in place: OnlinePlace) -> String {
        isRoot ? place.rootPath : place.rootPath + " › " + path.split(separator: "/").joined(separator: " › ")
    }

    /// What Get back calls the place a copy went.
    func label(in place: OnlinePlace) -> String {
        isRoot ? place.name : "\(place.name) › \(path.split(separator: "/").joined(separator: " › "))"
    }
}

enum OnlineFolders {
    // MARK: - The chosen folder

    private static func key(_ place: OnlinePlace) -> String { "archive.folder.\(place.rawValue)" }

    static func chosen(_ place: OnlinePlace, defaults: UserDefaults = .standard) -> OnlineFolder {
        guard let data = defaults.data(forKey: key(place)),
              let folder = try? JSONDecoder().decode(OnlineFolder.self, from: data) else { return .root }
        return folder
    }

    static func choose(_ folder: OnlineFolder, for place: OnlinePlace, defaults: UserDefaults = .standard) {
        if folder.isRoot { defaults.removeObject(forKey: key(place)) }
        else if let data = try? JSONEncoder().encode(folder) { defaults.set(data, forKey: key(place)) }
    }

    /// A folder name people can type: trimmed, without characters the services refuse. Nil when nothing is left.
    static func cleanName(_ text: String) -> String? {
        let refused = CharacterSet(charactersIn: "/\\:*?\"<>|#%")
        let cleaned = String(text.unicodeScalars.filter { !refused.contains($0) && !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(100))
    }

    static func joined(_ parent: OnlineFolder, _ name: String) -> String { parent.isRoot ? name : parent.path + "/" + name }

    /// Percent-encodes each part of a path inside TidyAway's OneDrive folder.
    static func graphPath(_ path: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:?#[]@!$&'()*+,;="))
        return path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    // MARK: - Listing and making folders

    static func list(_ place: OnlinePlace, in parent: OnlineFolder, token: String) async throws -> [OnlineFolder] {
        switch place {
        case .oneDrive:
            let base = "https://graph.microsoft.com/v1.0/me/drive/special/approot"
            let url = parent.isRoot ? "\(base)/children" : "\(base):/\(graphPath(parent.path)):/children"
            struct Page: Decodable { struct Item: Decodable { let name: String; let folder: [String: Int]? }; let value: [Item] }
            let page: Page = try await get(URL(string: url + "?$select=name,folder&$top=200")!, token: token, place: place)
            return page.value.filter { $0.folder != nil }
                .map { OnlineFolder(id: joined(parent, $0.name), path: joined(parent, $0.name)) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        case .dropbox:
            struct Page: Decodable {
                struct Entry: Decodable { let tag: String; let name: String; enum CodingKeys: String, CodingKey { case tag = ".tag", name } }
                let entries: [Entry]
            }
            let body = try JSONSerialization.data(withJSONObject: ["path": parent.isRoot ? "" : "/" + parent.path])
            let page: Page = try await post(URL(string: "https://api.dropboxapi.com/2/files/list_folder")!, body: body, token: token, place: place)
            return page.entries.filter { $0.tag == "folder" }
                .map { OnlineFolder(id: joined(parent, $0.name), path: joined(parent, $0.name)) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        case .google:
            let parentID = parent.isRoot ? try await GoogleDriveClient.archiveFolder(token: token) : parent.id
            var search = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            search.queryItems = [
                URLQueryItem(name: "q", value: "'\(parentID)' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"),
                URLQueryItem(name: "fields", value: "files(id,name)"),
                URLQueryItem(name: "pageSize", value: "200")
            ]
            struct Page: Decodable { struct File: Decodable { let id: String; let name: String }; let files: [File] }
            let page: Page = try await get(search.url!, token: token, place: place)
            return page.files.map { OnlineFolder(id: $0.id, path: joined(parent, $0.name)) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    /// Makes a folder, or uses the one already there with that name. It never changes or removes anything.
    static func create(_ name: String, in parent: OnlineFolder, place: OnlinePlace, token: String) async throws -> OnlineFolder {
        guard let name = cleanName(name) else { throw OnlineFolderError.badName }
        let path = joined(parent, name)
        switch place {
        case .oneDrive:
            let base = "https://graph.microsoft.com/v1.0/me/drive/special/approot"
            let url = parent.isRoot ? "\(base)/children" : "\(base):/\(graphPath(parent.path)):/children"
            let body = try JSONSerialization.data(withJSONObject: ["name": name, "folder": [String: Any](),
                                                                   "@microsoft.graph.conflictBehavior": "fail"])
            let status = try await send(URL(string: url)!, method: "POST", body: body, token: token, place: place)
            // 409: a folder or file of that name is already there; use the folder if it is one.
            guard (200...201).contains(status) || status == 409 else { throw CloudError.server(place.name, status) }
            if status == 409, !(try await list(place, in: parent, token: token)).contains(where: { $0.path == path }) {
                throw OnlineFolderError.nameTaken
            }
            return OnlineFolder(id: path, path: path)
        case .dropbox:
            let body = try JSONSerialization.data(withJSONObject: ["path": "/" + path, "autorename": false])
            let status = try await send(URL(string: "https://api.dropboxapi.com/2/files/create_folder_v2")!, method: "POST",
                                        body: body, token: token, place: place, json: true)
            guard status == 200 || status == 409 else { throw CloudError.server(place.name, status) }
            if status == 409, !(try await list(place, in: parent, token: token)).contains(where: { $0.path == path }) {
                throw OnlineFolderError.nameTaken
            }
            return OnlineFolder(id: path, path: path)
        case .google:
            if let existing = try await list(place, in: parent, token: token).first(where: { $0.name == name }) { return existing }
            let parentID = parent.isRoot ? try await GoogleDriveClient.archiveFolder(token: token) : parent.id
            let body = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": "application/vnd.google-apps.folder",
                                                                   "parents": [parentID]])
            struct Made: Decodable { let id: String }
            let made: Made = try await post(URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!, body: body,
                                            token: token, place: place)
            return OnlineFolder(id: made.id, path: path)
        }
    }

    /// The folder's own web address from OneDrive, wherever the account keeps TidyAway's folder
    /// (work and school accounts can keep it outside My files). Nil when OneDrive doesn't say.
    static func oneDriveWebLink(_ folder: OnlineFolder, token: String) async -> URL? {
        let base = "https://graph.microsoft.com/v1.0/me/drive/special/approot"
        let url = folder.isRoot ? base : "\(base):/\(graphPath(folder.path)):"
        struct Item: Decodable { let webUrl: String? }
        guard let item: Item = try? await get(URL(string: url + "?$select=webUrl")!, token: token, place: .oneDrive),
              let web = item.webUrl else { return nil }
        return URL(string: web)
    }

    /// Opens the folder in the service's website or app.
    static func link(_ folder: OnlineFolder, place: OnlinePlace, rootID: String? = nil) -> URL? {
        switch place {
        case .oneDrive:
            return URL(string: "https://onedrive.live.com/?id=root&qt=apps")
        case .dropbox:
            let allowed = CharacterSet.urlPathAllowed
            let tail = folder.isRoot ? "" : "/" + (folder.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? folder.path)
            return URL(string: "https://www.dropbox.com/home/Apps/TidyAway\(tail)")
        case .google:
            guard let id = folder.isRoot ? rootID : folder.id, !id.isEmpty else { return URL(string: "https://drive.google.com/drive/my-drive") }
            return URL(string: "https://drive.google.com/drive/folders/\(id)")
        }
    }

    // MARK: - Requests

    private static func request(_ url: URL, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    private static func get<T: Decodable>(_ url: URL, token: String, place: OnlinePlace) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request(url, method: "GET", token: token))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CloudError.server(place.name, status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func post<T: Decodable>(_ url: URL, body: Data, token: String, place: OnlinePlace) async throws -> T {
        var request = request(url, method: "POST", token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CloudError.server(place.name, status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func send(_ url: URL, method: String, body: Data, token: String, place: OnlinePlace, json: Bool = true) async throws -> Int {
        var request = request(url, method: method, token: token)
        if json { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (_, response) = try await URLSession.shared.upload(for: request, from: body)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

enum OnlineFolderError: LocalizedError {
    case badName, nameTaken
    var errorDescription: String? {
        switch self {
        case .badName: "Type a folder name. Slashes and symbols like : * ? aren't allowed."
        case .nameTaken: "Something with that name is already there and isn't a folder. Try another name."
        }
    }
}

/// Pick or make a folder inside TidyAway's own folder in an online service.
struct OnlineFolderPicker: View {
    let place: OnlinePlace
    let token: () async throws -> String
    let picked: (OnlineFolder) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var trail: [OnlineFolder] = [.root]
    @State private var folders: [OnlineFolder] = []
    @State private var loading = false
    @State private var problem: String?
    @State private var naming = false
    @State private var newName = ""

    private var current: OnlineFolder { trail.last ?? .root }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(current.shown(in: place), systemImage: "folder.fill")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("folder-current")
                    if trail.count > 1 {
                        Button { trail.removeLast(); Task { await load() } } label: {
                            Label("Up to \(trail[trail.count - 2].isRoot ? "TidyAway's folder" : trail[trail.count - 2].name)",
                                  systemImage: "arrow.turn.left.up")
                        }
                    }
                } footer: {
                    Text("TidyAway can only see and add files inside its own folder, so every folder here is inside it.")
                }
                Section("Folders here") {
                    if loading {
                        ProgressView()
                    } else if folders.isEmpty {
                        Text("No folders here yet.").foregroundStyle(.secondary)
                    }
                    ForEach(folders) { folder in
                        Button {
                            trail.append(folder)
                            Task { await load() }
                        } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                        .accessibilityIdentifier("folder-\(folder.name)")
                    }
                    Button { newName = ""; naming = true } label: {
                        Label("New folder", systemImage: "folder.badge.plus")
                    }
                    .accessibilityIdentifier("folder-new")
                }
                if let problem {
                    Text(problem).foregroundStyle(Brand.caution).font(.footnote)
                }
            }
            .navigationTitle("Choose folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save here") {
                        picked(current)
                        dismiss()
                    }
                    .accessibilityIdentifier("folder-use")
                }
            }
            .alert("New folder", isPresented: $naming) {
                TextField("Name, such as 2024 Beach trip", text: $newName)
                Button("Create") { Task { await make() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It's made inside \(current.shown(in: place)).")
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        problem = nil
        defer { loading = false }
        do {
            folders = try await OnlineFolders.list(place, in: current, token: try await token())
        } catch {
            folders = []
            problem = "Couldn't read the folders in \(place.name). \(error.localizedDescription)"
        }
    }

    private func make() async {
        problem = nil
        do {
            let made = try await OnlineFolders.create(newName, in: current, place: place, token: try await token())
            trail.append(made)
            await load()
        } catch {
            problem = error.localizedDescription
        }
    }
}
