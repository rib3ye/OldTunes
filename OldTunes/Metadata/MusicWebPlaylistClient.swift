import Foundation
import MusicKit

/// Experimental web-player backend. It never launches Music or replaces MusicKit's global
/// token provider. Tokens live only in this actor and an ephemeral URLSession's requests.
/// The normal playlist editor does not use this experimental backend.
actor MusicWebPlaylistClient {
    struct Resource: Decodable, Sendable {
        let id: String
        let type: String
        let attributes: Attributes?
        let relationships: Relationships?

        init(id: String, type: String, attributes: Attributes?, relationships: Relationships? = nil) {
            self.id = id
            self.type = type
            self.attributes = attributes
            self.relationships = relationships
        }
    }

    struct Relationships: Decodable, Sendable {
        let tracks: TrackRelationship?
    }

    struct TrackRelationship: Decodable, Sendable {
        let data: [Resource]
        let next: String?
    }

    struct Attributes: Decodable, Sendable {
        let name: String?
        let canEdit: Bool?
        let isPublic: Bool?
        let description: Description?
        let playParams: PlayParams?
    }

    struct Description: Decodable, Sendable {
        let standard: String?
    }

    struct PlayParams: Decodable, Sendable {
        let id: String?
        let kind: String?
        let catalogId: String?
    }

    /// No server response text, request body, credential, or URL reaches error descriptions.
    enum Failure: LocalizedError, Sendable {
        case authorizationUnavailable
        case nativeTokenUnavailable(Int)
        case nativeTokenTimedOut
        case webTokenUnavailable
        case unsafeURL
        case invalidIdentifier
        case invalidInput
        case invalidResponse
        case paginationLimit
        case transport(Int)
        case http(status: Int, code: String?)

        var errorDescription: String? {
            switch self {
            case .authorizationUnavailable:
                return "Music library authorization is unavailable."
            case .nativeTokenUnavailable(let code):
                return "Native MusicKit could not obtain a web-player user token (code \(code))."
            case .nativeTokenTimedOut:
                return "Native MusicKit timed out obtaining a web-player user token."
            case .webTokenUnavailable:
                return "Apple's website did not supply a current web-player developer token."
            case .unsafeURL:
                return "The web-player request used an unexpected destination."
            case .invalidIdentifier:
                return "The web-player request requires a valid cloud library identifier."
            case .invalidInput:
                return "The web-player request has invalid input."
            case .invalidResponse:
                return "Apple Music returned an unexpected web-player response."
            case .paginationLimit:
                return "Apple Music returned repeated or excessive library pages."
            case .transport(let code):
                return "The Apple Music web request failed (network code \(code)); its result may be unknown."
            case .http(let status, let code):
                return "Apple Music web request failed (HTTP \(status)\(code.map { ", code \($0)" } ?? ""))."
            }
        }
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private struct Page: Decodable {
        let data: [Resource]
        let next: String?
    }

    private struct ErrorResponse: Decodable {
        struct Item: Decodable { let code: String? }
        let errors: [Item]?
    }

    private static let apiHost = "amp-api.music.apple.com"
    private static let webHost = "music.apple.com"
    private static let apiRoot = URL(string: "https://amp-api.music.apple.com")!
    private static let webRoot = URL(string: "https://music.apple.com")!
    private let developerToken: String
    private let userToken: String
    private let transport: Transport

    /// Injection is for the offline request harness; production callers use `connect()`.
    init(developerToken: String, userToken: String, transport: @escaping Transport) {
        self.developerToken = developerToken
        self.userToken = userToken
        self.transport = transport
    }

    static func connect() async throws -> MusicWebPlaylistClient {
        var authorization = MusicAuthorization.currentStatus
        if authorization == .notDetermined {
            authorization = try await withTimeout(60) { await MusicAuthorization.request() }
        }
        guard authorization == .authorized else { throw Failure.authorizationUnavailable }

        let anonymous = makeTransport(host: webHost, allowsRedirects: true)
        let developerToken = try await fetchDeveloperToken(using: anonymous)
        let userToken: String
        do {
            userToken = try await withTimeout(30) {
                try await MusicUserTokenProvider().userToken(for: developerToken, options: [])
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is TimeoutError {
            throw Failure.nativeTokenTimedOut
        } catch {
            throw Failure.nativeTokenUnavailable((error as NSError).code)
        }
        guard !userToken.isEmpty else { throw Failure.nativeTokenUnavailable(0) }
        return MusicWebPlaylistClient(developerToken: developerToken, userToken: userToken,
                                      transport: makeTransport(host: apiHost, allowsRedirects: false))
    }

    func playlists() async throws -> [Resource] {
        try await allPages(path: "/v1/me/library/playlists", query: [.init(name: "limit", value: "100")])
    }

    func songs(limit: Int = 2) async throws -> [Resource] {
        guard (1...100).contains(limit) else { throw Failure.invalidInput }
        return try await allPages(path: "/v1/me/library/songs", query: [.init(name: "limit", value: String(limit))],
                                  maximumResources: limit)
    }

    func playlist(id: String) async throws -> Resource? {
        try Self.validate(id, prefix: "p.")
        return try await resource(path: "/v1/me/library/playlists/\(id)", id: id, type: "library-playlists")
    }

    func song(id: String) async throws -> Resource? {
        try Self.validate(id, prefix: "i.")
        return try await resource(path: "/v1/me/library/songs/\(id)", id: id, type: "library-songs")
    }

    func tracks(playlistID: String) async throws -> [Resource] {
        try Self.validate(playlistID, prefix: "p.")
        let path = "/v1/me/library/playlists/\(playlistID)"
        // Apple's web player obtains the initial track relationship with its parent. The
        // standalone /tracks endpoint can return 40403 for an existing empty playlist.
        let page = try Self.decodePage(try await send(method: "GET", path: path,
                                                     query: [.init(name: "include", value: "tracks")]))
        guard page.data.count == 1, let playlist = page.data.first,
              playlist.id == playlistID, playlist.type == "library-playlists",
              let relationship = playlist.relationships?.tracks else { throw Failure.invalidResponse }
        guard let next = relationship.next else { return relationship.data }
        let trackPath = "\(path)/tracks"
        let url = try Self.paginationURL(next, path: trackPath)
        let remainder = try await readPages(firstURL: url, path: trackPath)
        return relationship.data + remainder
    }

    func createPlaylist(name: String) async throws -> Resource {
        try Self.validateName(name)
        let body = try JSONSerialization.data(withJSONObject: ["attributes": ["name": name, "isPublic": false]])
        let data = try await send(method: "POST", path: "/v1/me/library/playlists", body: body)
        let page = try Self.decodePage(data)
        guard page.data.count == 1, let created = page.data.first,
              created.type == "library-playlists" else { throw Failure.invalidResponse }
        try Self.validate(created.id, prefix: "p.")
        return created
    }

    func renamePlaylist(id: String, name: String) async throws {
        try Self.validate(id, prefix: "p.")
        try Self.validateName(name)
        // PATCH only the name: existing description and visibility are left unchanged.
        let body = try JSONSerialization.data(withJSONObject: ["attributes": ["name": name]])
        _ = try await send(method: "PATCH", path: "/v1/me/library/playlists/\(id)", body: body)
    }

    func addSongs(ids: [String], to playlistID: String) async throws {
        try Self.validate(playlistID, prefix: "p.")
        try Self.validateSongs(ids)
        let body = try JSONSerialization.data(withJSONObject: ["data": ids.map { ["id": $0, "type": "library-songs"] }])
        _ = try await send(method: "POST", path: "/v1/me/library/playlists/\(playlistID)/tracks", body: body)
    }

    /// Removes every occurrence of each song from this playlist. It never targets the song
    /// resource itself, which would delete it from the user's entire cloud library.
    func removeSongs(ids: [String], from playlistID: String) async throws {
        try Self.validate(playlistID, prefix: "p.")
        try Self.validateSongs(ids)
        _ = try await send(method: "DELETE", path: "/v1/me/library/playlists/\(playlistID)/tracks", query: [
            .init(name: "ids[library-songs]", value: ids.joined(separator: ",")),
            .init(name: "mode", value: "all")
        ])
    }

    func deletePlaylist(id: String) async throws {
        try Self.validate(id, prefix: "p.")
        _ = try await send(method: "DELETE", path: "/v1/me/library/playlists/\(id)")
    }

    private func resource(path: String, id: String, type: String) async throws -> Resource? {
        let data: Data
        do { data = try await send(method: "GET", path: path) }
        catch Failure.http(status: 404, code: _) { return nil }
        let page = try Self.decodePage(data)
        guard page.data.count <= 1 else { throw Failure.invalidResponse }
        guard let result = page.data.first else { return nil }
        guard result.id == id, result.type == type else { throw Failure.invalidResponse }
        return result
    }

    private func allPages(path: String, query: [URLQueryItem] = [], maximumResources: Int? = nil) async throws -> [Resource] {
        try await readPages(firstURL: Self.apiURL(path: path, query: query), path: path,
                            maximumResources: maximumResources)
    }

    private func readPages(firstURL: URL, path: String, maximumResources: Int? = nil) async throws -> [Resource] {
        var url = firstURL
        var seen = Set<URL>()
        var resources: [Resource] = []
        while true {
            guard seen.count < 500, seen.insert(url).inserted else { throw Failure.paginationLimit }
            let page = try Self.decodePage(try await send(method: "GET", url: url))
            resources.append(contentsOf: page.data)
            if let maximumResources, resources.count >= maximumResources {
                return Array(resources.prefix(maximumResources))
            }
            guard let next = page.next else { return resources }
            url = try Self.paginationURL(next, path: path)
        }
    }

    private static func paginationURL(_ next: String, path: String) throws -> URL {
        guard !next.hasPrefix("//"), let rawNext = URLComponents(string: next),
              !rawNext.percentEncodedPath.contains("%"),
              !rawNext.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let nextURL = URL(string: next, relativeTo: apiRoot)?.absoluteURL else {
            throw Failure.unsafeURL
        }
        try validateURL(nextURL, host: apiHost)
        // A page may change its query, never its endpoint or credential destination.
        guard nextURL.path == path else { throw Failure.unsafeURL }
        return nextURL
    }

    private func send(method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        try await send(method: method, url: Self.apiURL(path: path, query: query), body: body)
    }

    private func send(method: String, url: URL, body: Data? = nil) async throws -> Data {
        try Self.validateURL(url, host: Self.apiHost)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userToken, forHTTPHeaderField: "media-user-token")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        // Exactly one attempt, including mutations whose response is lost in transit.
        let (data, response) = try await Self.perform(request, using: transport)
        guard response.url == url else { throw Failure.unsafeURL }
        try Self.checkStatus(response, data: data)
        return data
    }

    private static func apiURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard path.hasPrefix("/v1/me/library/") else { throw Failure.unsafeURL }
        var components = URLComponents(url: apiRoot, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw Failure.unsafeURL }
        return url
    }

    private static func validate(_ id: String, prefix: String) throws {
        let tail = id.dropFirst(prefix.count)
        guard id.hasPrefix(prefix), !tail.isEmpty, tail.count <= 200,
              tail.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw Failure.invalidIdentifier
        }
    }

    private static func validateSongs(_ ids: [String]) throws {
        guard !ids.isEmpty, ids.count <= 100 else { throw Failure.invalidInput }
        for id in ids { try validate(id, prefix: "i.") }
    }

    private static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 1_000 else {
            throw Failure.invalidInput
        }
    }

    private static func validateURL(_ url: URL, host: String) throws {
        guard url.scheme == "https", url.host == host, url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil else { throw Failure.unsafeURL }
    }

    private static func decodePage(_ data: Data) throws -> Page {
        do { return try JSONDecoder().decode(Page.self, from: data) }
        catch { throw Failure.invalidResponse }
    }

    private static func checkStatus(_ response: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(response.statusCode) else {
            let rawCode = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.errors?.first?.code
            // Numeric Apple error codes only; an arbitrary error string could contain secrets.
            let code = rawCode.flatMap { value in
                !value.isEmpty && value.count <= 12 && value.utf8.allSatisfy({ (48...57).contains($0) }) ? value : nil
            }
            throw Failure.http(status: response.statusCode, code: code)
        }
    }

    private static func perform(_ request: URLRequest, using transport: @escaping Transport) async throws -> (Data, HTTPURLResponse) {
        do { return try await withTimeout(30) { try await transport(request) } }
        catch is CancellationError { throw CancellationError() }
        catch is TimeoutError { throw Failure.transport(NSURLErrorTimedOut) }
        catch { throw Failure.transport((error as NSError).code) }
    }

    private static func makeTransport(host: String, allowsRedirects: Bool) -> Transport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let delegate = RedirectPolicy(host: host, allowsRedirects: allowsRedirects)
        let owner = SessionOwner(URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil))
        return { request in
            let (data, response) = try await owner.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
            return (data, response)
        }
    }

    private static func fetchDeveloperToken(using transport: @escaping Transport) async throws -> String {
        let pageURL = URL(string: "https://music.apple.com/us/browse")!
        let html = try await anonymousSource(pageURL, using: transport)
        if let token = try? developerToken(in: html) { return token }
        for script in try bootstrapScriptURLs(in: html) {
            let source = try await anonymousSource(script, using: transport)
            if let token = try? developerToken(in: source) { return token }
        }
        throw Failure.webTokenUnavailable
    }

    private static func anonymousSource(_ url: URL, using transport: @escaping Transport) async throws -> String {
        try validateURL(url, host: webHost)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data, response) = try await perform(request, using: transport)
        guard let finalURL = response.url else { throw Failure.invalidResponse }
        try validateURL(finalURL, host: webHost)
        try checkStatus(response, data: data)
        guard data.count <= 25_000_000, let source = String(data: data, encoding: .utf8) else {
            throw Failure.webTokenUnavailable
        }
        return source
    }

    /// Parse only Apple's index bundle paths. A page cannot redirect token discovery to a
    /// third-party script. This and the JWT parser have deterministic offline test seams.
    static func bootstrapScriptURLs(in html: String) throws -> [URL] {
        let pattern = #"(?:src|href)\s*=\s*["']((?:https://music\.apple\.com)?/assets/index~[A-Za-z0-9_.-]+\.js)["']"#
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var seen = Set<URL>()
        return try matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: html),
                  let url = URL(string: String(html[range]), relativeTo: webRoot)?.absoluteURL else { return nil }
            try validateURL(url, host: webHost)
            return seen.insert(url).inserted ? url : nil
        }
    }

    /// The HTTPS source establishes provenance. These checks reject unrelated or stale JWTs;
    /// they do not pretend to verify Apple's signature with a locally available public key.
    static func developerToken(in source: String, now: Date = Date()) throws -> String {
        struct Claims: Decodable { let iss: String; let exp: Double }
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?![A-Za-z0-9_-])"#)
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var latest: (token: String, expiry: Double)?
        for match in matches {
            guard let range = Range(match.range, in: source) else { continue }
            let token = String(source[range])
            let parts = token.split(separator: ".")
            guard parts.count == 3 else { continue }
            var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let data = Data(base64Encoded: encoded),
                  let claims = try? JSONDecoder().decode(Claims.self, from: data),
                  claims.iss == "AMPWebPlay", claims.exp > now.timeIntervalSince1970 + 60 else { continue }
            if latest == nil || claims.exp > latest!.expiry { latest = (token, claims.exp) }
        }
        guard let latest else { throw Failure.webTokenUnavailable }
        return latest.token
    }

    private final class SessionOwner: Sendable {
        let session: URLSession
        init(_ session: URLSession) { self.session = session }
        deinit { session.invalidateAndCancel() }
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
        let host: String
        let allowsRedirects: Bool

        init(host: String, allowsRedirects: Bool) {
            self.host = host
            self.allowsRedirects = allowsRedirects
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            // Authenticated AMP requests follow no redirects, even on the same host, so a
            // server redirect cannot replay a write or forward a credential to a new path.
            guard allowsRedirects, request.httpMethod == "GET", let url = request.url,
                  (try? MusicWebPlaylistClient.validateURL(url, host: host)) != nil,
                  request.value(forHTTPHeaderField: "Authorization") == nil,
                  request.value(forHTTPHeaderField: "media-user-token") == nil else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
