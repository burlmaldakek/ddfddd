//
//  PasscodeGalleryManager.swift
//  lara
//
//  Created by neonmodder123 on 20/05/2026.
//

import Foundation
import SwiftUI
import Combine

// just forked the cowabunga theme repo to update JSON structure
let defaultPasscodeRepoURL = "https://raw.githubusercontent.com/neonmodder123/theme-repo/refs/heads/main/passcode-themes.json"
private let passcodeRepoKey = "passcodeThemeRepos"

struct PasscodeGalleryTheme: Identifiable, Decodable, Equatable {
    let name: String
    let description: String
    let url: String
    let preview: String
    let contact: PasscodeThemeContact
    let version: String
    var id: String { name }
}

struct PasscodeThemeContact: Decodable, Equatable {
    private let raw: [String: String]
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        raw = try container.decode([String: String].self)
    }
    var displayName: String {
        raw.map { "\($0.key): \($0.value)" }.first ?? ""
    }
}

struct PasscodeRepoData: Identifiable {
    var id: String { name }
    let name: String
    let author: String?
    let icon: String?
    let themes: [PasscodeGalleryTheme]
    let baseURL: URL
}

struct PasscodeRepoState: Identifiable {
    var id: String { url }
    let url: String
    var isLoading: Bool
    var error: String?
    var data: PasscodeRepoData?
}

@MainActor
final class PasscodeGalleryManager: ObservableObject {
    static let shared = PasscodeGalleryManager()

    @Published var repos: [PasscodeRepoState] = []
    @Published var downloading: Set<String> = []

    private var repoURLs: [String] = loadPasscodeRepoURLs()

    var allThemes: [PasscodeGalleryTheme] { repos.flatMap { $0.data?.themes ?? [] } }
    var themes: [PasscodeGalleryTheme] { allThemes }
    var isLoading: Bool { repos.contains { $0.isLoading } }
    var loadError: String? { repos.first { $0.error != nil }?.error }

    func previewURL(for theme: PasscodeGalleryTheme) -> URL? {
        guard let repoData = repos.first(where: { $0.data?.themes.contains(where: { $0.id == theme.id }) == true })?.data else { return nil }
        if theme.preview.hasPrefix("http") { return URL(string: theme.preview) }
        return repoData.baseURL.appendingPathComponent(theme.preview)
    }

    func downloadURL(for theme: PasscodeGalleryTheme) -> URL? {
        guard let repoData = repos.first(where: { $0.data?.themes.contains(where: { $0.id == theme.id }) == true })?.data else { return nil }
        if theme.url.hasPrefix("http") { return URL(string: theme.url) }
        return repoData.baseURL.appendingPathComponent(theme.url)
    }

    func isDownloading(_ theme: PasscodeGalleryTheme) -> Bool { downloading.contains(theme.id) }

    func loadThemes(forceRefresh: Bool = false) async {
        await refreshRepos(forceRefresh: forceRefresh)
    }

    func refreshRepos(forceRefresh: Bool = false) async {
        // Keep the already-loaded repository data visible while refreshing. SwiftUI may
        // cancel a refresh when the gesture/view ends; clearing `data` here used to blank
        // the gallery permanently and expose "Cancelled" as if it were a real load error.
        var previousByURL: [String: PasscodeRepoState] = [:]
        for previous in repos { previousByURL[previous.url] = previous }
        repos = repoURLs.map { url in
            if var previous = previousByURL[url] {
                previous.isLoading = true
                previous.error = nil
                return previous
            }
            return PasscodeRepoState(url: url, isLoading: true, error: nil, data: nil)
        }

        await withTaskGroup(of: (String, Result<PasscodeRepoData, Error>).self) { group in
            for url in repoURLs {
                group.addTask {
                    do {
                        return (url, .success(try await self.fetchRepo(url, forceRefresh: forceRefresh)))
                    } catch {
                        return (url, .failure(error))
                    }
                }
            }
            for await (url, result) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                guard let idx = repos.firstIndex(where: { $0.url == url }) else { continue }
                repos[idx].isLoading = false
                switch result {
                case .success(let data):
                    repos[idx].data = data
                    repos[idx].error = nil
                case .failure(let error):
                    if Self.isCancellation(error) {
                        // Leave previously loaded theme data in place and avoid showing
                        // a cancellation message as a repository failure.
                        if repos[idx].data == nil { repos[idx].error = nil }
                    } else {
                        repos[idx].error = error.localizedDescription
                    }
                }
            }
        }

        if Task.isCancelled {
            // Discard partial refresh results and restore the last known-good list.
            repos = repoURLs.map { url in
                if var previous = previousByURL[url] {
                    previous.isLoading = false
                    if Self.isCancellationMessage(previous.error) { previous.error = nil }
                    return previous
                }
                return PasscodeRepoState(url: url, isLoading: false, error: nil, data: nil)
            }
            return
        }

        for index in repos.indices { repos[index].isLoading = false }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return (error as NSError).code == NSURLErrorCancelled
    }

    private static func isCancellationMessage(_ message: String?) -> Bool {
        guard let message else { return false }
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "cancelled" || normalized == "canceled"
            || normalized == "the operation could not be completed. (nsurlerror-domain error -999.)"
    }

    func addRepo(_ urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil, !repoURLs.contains(trimmed) else { return }
        repoURLs.append(trimmed)
        savePasscodeRepoURLs(repoURLs)
        await refreshRepos()
    }

    func removeRepo(_ url: String) {
        guard url != defaultPasscodeRepoURL else { return }
        repoURLs.removeAll { $0 == url }
        savePasscodeRepoURLs(repoURLs)
        Task { await refreshRepos() }
    }

    func downloadAndImport(_ theme: PasscodeGalleryTheme) async throws {
        guard let fileURL = downloadURL(for: theme) else { throw URLError(.badURL) }
        downloading.insert(theme.id)
        defer { downloading.remove(theme.id) }
        let (data, _) = try await URLSession.shared.data(from: fileURL)
        let dest = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(theme.name + ".passthm")
        try data.write(to: dest, options: .atomic)
    }

    private func fetchRepo(_ urlString: String, forceRefresh: Bool = false) async throws -> PasscodeRepoData {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        if forceRefresh { req.cachePolicy = .reloadIgnoringLocalCacheData }
        let (data, _) = try await URLSession.shared.data(for: req)
        let baseURL = url.deletingLastPathComponent()

        if let themes = try? JSONDecoder().decode([PasscodeGalleryTheme].self, from: data) {
            let name = urlString == defaultPasscodeRepoURL ? "Cowabunga" : (url.deletingPathExtension().lastPathComponent)
            return PasscodeRepoData(name: name, author: nil, icon: nil, themes: themes, baseURL: baseURL)
        }

        struct RepoJSON: Decodable {
            let repo_name: String
            let repo_author: String?
            let repo_icon: String?
            let themes: [PasscodeGalleryTheme]
        }
        let parsed = try JSONDecoder().decode(RepoJSON.self, from: data)
        return PasscodeRepoData(name: parsed.repo_name, author: parsed.repo_author, icon: parsed.repo_icon, themes: parsed.themes, baseURL: baseURL)
    }
}

private func loadPasscodeRepoURLs() -> [String] {
    if let data = UserDefaults.standard.data(forKey: passcodeRepoKey),
       let urls = try? JSONDecoder().decode([String].self, from: data), !urls.isEmpty {
        var result = urls
        if !result.contains(defaultPasscodeRepoURL) { result.insert(defaultPasscodeRepoURL, at: 0) }
        return result
    }
    return [defaultPasscodeRepoURL]
}

private func savePasscodeRepoURLs(_ urls: [String]) {
    if let encoded = try? JSONEncoder().encode(urls) {
        UserDefaults.standard.set(encoded, forKey: passcodeRepoKey)
    }
}
