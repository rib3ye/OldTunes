import AppKit

/// OLDTUNES_HARNESS=musicwebchecks: exercises the private web client entirely through a
/// scripted transport. It cannot authorize, send HTTP, open Music, or change a real playlist.
@MainActor
enum MusicWebPlaylistHarness {
    static func run() async {
        _ = await checks()
        Log.flush()
        NSApp.terminate(nil)
    }

    /// Also callable from a command-line runner without starting NSApplication.
    static func checks() async -> Bool {
        let tally = HarnessTally()
        tokens(tally)
        await mutations(tally)
        await emptyRelationships(tally)
        await pagination(tally)
        await failures(tally)
        await invalidIdentifiers(tally)
        Log.info("music web checks: \(tally.passed) PASS, \(tally.failed) FAIL")
        Log.info(tally.failed == 0 ? "MUSIC WEB CHECKS: ALL PASS" : "MUSIC WEB CHECKS: FAILURES")
        return tally.failed == 0
    }

    private static func client(_ responses: [MusicWebHarnessTransport.Reply])
        -> (MusicWebPlaylistClient, MusicWebHarnessTransport) {
        let transport = MusicWebHarnessTransport(responses)
        let client = MusicWebPlaylistClient(developerToken: "fixture-developer-secret",
                                            userToken: "fixture-user-secret") { request in
            try await transport.send(request)
        }
        return (client, transport)
    }

    private static func tokens(_ tally: HarnessTally) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func token(issuer: String, expiry: Double) -> String {
            func encode(_ json: [String: Any]) -> String {
                let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
                return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            }
            return encode(["alg": "ES256"]) + "." + encode(["iss": issuer, "exp": expiry]) + ".fixture_signature"
        }
        let valid = token(issuer: "AMPWebPlay", expiry: now.timeIntervalSince1970 + 7_200)
        let older = token(issuer: "AMPWebPlay", expiry: now.timeIntervalSince1970 + 3_600)
        let expired = token(issuer: "AMPWebPlay", expiry: now.timeIntervalSince1970 - 1)
        let expiring = token(issuer: "AMPWebPlay", expiry: now.timeIntervalSince1970 + 30)
        let unrelated = token(issuer: "UnrelatedIssuer", expiry: now.timeIntervalSince1970 + 99_999)
        do {
            let selected = try MusicWebPlaylistClient.developerToken(in: [expired, unrelated, valid, older].joined(separator: " "), now: now)
            tally.check(selected == valid, "web: token discovery selects the latest valid Apple web-player issuer")
        } catch {
            tally.check(false, "web: valid Apple web-player token is found", detail: error.localizedDescription)
        }
        for source in [expired, expiring, unrelated, "eyJinvalid.eyJinvalid.invalid", "no token"] {
            var refused = false
            do { _ = try MusicWebPlaylistClient.developerToken(in: source, now: now) }
            catch { refused = true }
            tally.check(refused, "web: rejects expired, expiring, unrelated, or malformed developer tokens")
        }
        let html = #"""
        <script src="/assets/index~first.js"></script>
        <link href="https://music.apple.com/assets/index~first.js">
        <script src='https://music.apple.com/assets/index~second.js'></script>
        <script src="https://unrelated.example/assets/index~third.js"></script>
        <script src="//unrelated.example/assets/index~fourth.js"></script>
        <script src="https://music.apple.com@unrelated.example/assets/index~fifth.js"></script>
        <script src="/assets/unrelated.js"></script>
        """#
        do {
            let scripts = try MusicWebPlaylistClient.bootstrapScriptURLs(in: html)
            tally.check(scripts.map(\.absoluteString) == ["https://music.apple.com/assets/index~first.js", "https://music.apple.com/assets/index~second.js"],
                        "web: token discovery ignores third-party scripts and duplicate bundle links")
        } catch {
            tally.check(false, "web: token bundle discovery succeeds", detail: error.localizedDescription)
        }
    }

    private static func mutations(_ tally: HarnessTally) async {
        let (client, transport) = client([
            .json(201, #"{"data":[{"id":"p.fixture","type":"library-playlists","attributes":{"name":"Disposable fixture","canEdit":true}}]}"#),
            .json(204, ""), .json(204, ""), .json(204, ""), .json(204, "")
        ])
        do {
            let playlist = try await client.createPlaylist(name: "Disposable fixture")
            let renamed = "A \"quoted\" playlist – 音楽"
            try await client.renamePlaylist(id: playlist.id, name: renamed)
            try await client.addSongs(ids: ["i.first", "i.second"], to: playlist.id)
            try await client.removeSongs(ids: ["i.first", "i.second"], from: playlist.id)
            try await client.deletePlaylist(id: playlist.id)
            let requests = await transport.requests
            tally.check(requests.count == 5, "web: create, rename, append, remove, delete each send one request")
            guard requests.count == 5 else { return }
            tally.check(requests.allSatisfy {
                $0.url?.scheme == "https" && $0.url?.host == "amp-api.music.apple.com"
                    && $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-developer-secret"
                    && $0.value(forHTTPHeaderField: "media-user-token") == "fixture-user-secret"
            }, "web: authenticated mutations use only the Apple API host")
            let body = try JSONSerialization.jsonObject(with: requests[1].httpBody ?? Data()) as? [String: Any]
            tally.check(requests[1].httpMethod == "PATCH"
                        && requests[1].url?.path == "/v1/me/library/playlists/p.fixture"
                        && (body?["attributes"] as? [String: Any])?["name"] as? String == renamed,
                        "web: rename preserves quotes and Unicode in the playlist attributes")
            let appendBody = try JSONSerialization.jsonObject(with: requests[2].httpBody ?? Data()) as? [String: Any]
            let entries = appendBody?["data"] as? [[String: String]]
            tally.check(requests[2].httpMethod == "POST"
                        && requests[2].url?.path == "/v1/me/library/playlists/p.fixture/tracks"
                        && entries?.map { $0["id"] ?? "" } == ["i.first", "i.second"]
                        && entries?.allSatisfy { $0["type"] == "library-songs" } == true,
                        "web: append uses ordered library-song references")
            let remove = requests[3]
            let query = URLComponents(url: remove.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            tally.check(remove.httpMethod == "DELETE"
                        && remove.url?.path == "/v1/me/library/playlists/p.fixture/tracks"
                        && query.contains(URLQueryItem(name: "ids[library-songs]", value: "i.first,i.second"))
                        && query.contains(URLQueryItem(name: "mode", value: "all")),
                        "web: removing songs targets playlist membership, never library songs")
            tally.check(requests[4].httpMethod == "DELETE"
                        && requests[4].url?.path == "/v1/me/library/playlists/p.fixture",
                        "web: deletion targets the returned playlist ID")
        } catch {
            tally.check(false, "web: mutation fixtures complete", detail: error.localizedDescription)
        }
    }

    /// Empty playlist relationships can return 404 from /tracks. The parent response must
    /// explicitly supply an empty data array before the client can conclude there are no songs.
    private static func emptyRelationships(_ tally: HarnessTally) async {
        let (client, transport) = client([.json(200, relationshipPage())])
        do {
            let tracks = try await client.tracks(playlistID: "p.fixture")
            let requests = await transport.requests
            let query = requests.first?.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
            } ?? []
            tally.check(tracks.isEmpty && requests.count == 1
                        && requests.first?.url?.path == "/v1/me/library/playlists/p.fixture"
                        && query.contains(URLQueryItem(name: "include", value: "tracks")),
                        "web: explicit empty parent relationship verifies an empty playlist without requesting /tracks")
        } catch {
            tally.check(false, "web: explicit empty playlist relationship is accepted", detail: error.localizedDescription)
        }

        for body in [
            #"{"data":[{"id":"p.fixture","type":"library-playlists"}]}"#,
            #"{"data":[{"id":"p.fixture","type":"library-playlists","relationships":{"tracks":{}}}]}"#,
            #"{"data":[]}"#,
            #"{"data":[{"id":"p.other","type":"library-playlists","relationships":{"tracks":{"data":[]}}}]}"#
        ] {
            let (incompleteClient, incompleteTransport) = Self.client([.json(200, body)])
            var invalidResponse = false
            do { _ = try await incompleteClient.tracks(playlistID: "p.fixture") }
            catch MusicWebPlaylistClient.Failure.invalidResponse { invalidResponse = true }
            catch {}
            let count = await incompleteTransport.requests.count
            tally.check(invalidResponse && count == 1,
                        "web: missing relationship, missing data, or wrong parent never masquerades as an empty playlist")
        }

        let (missingClient, missingTransport) = Self.client([.json(404, #"{"errors":[{"code":"40403"}]}"#)])
        var missingRejected = false
        do { _ = try await missingClient.tracks(playlistID: "p.fixture") }
        catch MusicWebPlaylistClient.Failure.http(status: 404, code: _) { missingRejected = true }
        catch {}
        let count = await missingTransport.requests.count
        tally.check(missingRejected && count == 1, "web: missing parent playlist is an error, not an empty relationship")
    }

    private static func relationshipPage(ids: [String] = [], next: String? = nil) -> String {
        var relationship: [String: Any] = ["data": ids.map { ["id": $0, "type": "library-songs"] }]
        if let next { relationship["next"] = next }
        let body: [String: Any] = ["data": [["id": "p.fixture", "type": "library-playlists",
                                           "relationships": ["tracks": relationship]]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    private static func pagination(_ tally: HarnessTally) async {
        let (client, transport) = client([
            .json(200, relationshipPage(ids: ["i.first"], next: "/v1/me/library/playlists/p.fixture/tracks?offset=1")),
            .json(200, #"{"data":[{"id":"i.second","type":"library-songs"}]}"#)
        ])
        do {
            let tracks = try await client.tracks(playlistID: "p.fixture")
            let requests = await transport.requests
            tally.check(tracks.map(\.id) == ["i.first", "i.second"] && requests.count == 2
                        && requests.first?.url?.path == "/v1/me/library/playlists/p.fixture"
                        && requests.last?.url?.path == "/v1/me/library/playlists/p.fixture/tracks",
                        "web: playlist verification reads the parent relationship and subsequent track pages in order")
        } catch {
            tally.check(false, "web: paginated tracks succeed", detail: error.localizedDescription)
        }

        for next in [
            "https://unrelated.example/v1/me/library/playlists/p.fixture/tracks",
            "//unrelated.example/v1/me/library/playlists/p.fixture/tracks",
            "https://amp-api.music.apple.com@unrelated.example/v1/me/library/playlists/p.fixture/tracks",
            "https://amp-api.music.apple.com:444/v1/me/library/playlists/p.fixture/tracks",
            "http://amp-api.music.apple.com/v1/me/library/playlists/p.fixture/tracks",
            "/v1/me/library/songs",
            "/v1/me/library/playlists/p.fixture/../p.fixture/tracks",
            "/v1/me/library/playlists/p.fixture/%2e%2e/p.fixture/tracks",
            "/v1/me/library/playlists/p.fixture/tracks#fixture-user-secret"
        ] {
            let (unsafeClient, unsafeTransport) = Self.client([.json(200, relationshipPage(next: next))])
            var refused = false
            do { _ = try await unsafeClient.tracks(playlistID: "p.fixture") }
            catch MusicWebPlaylistClient.Failure.unsafeURL { refused = true }
            catch {}
            let count = await unsafeTransport.requests.count
            tally.check(refused && count == 1, "web: rejects unsafe pagination before forwarding credentials (\(next))")
        }

        let repeated = #"{"data":[],"next":"/v1/me/library/playlists/p.fixture/tracks?offset=1"}"#
        let (cycleClient, cycleTransport) = Self.client([
            .json(200, relationshipPage(next: "/v1/me/library/playlists/p.fixture/tracks?offset=1")),
            .json(200, repeated)
        ])
        var refusedCycle = false
        do { _ = try await cycleClient.tracks(playlistID: "p.fixture") }
        catch MusicWebPlaylistClient.Failure.paginationLimit { refusedCycle = true }
        catch {}
        let count = await cycleTransport.requests.count
        tally.check(refusedCycle && count == 2, "web: cyclic relationship pagination terminates without a repeated request")

        let (unsafeContinuationClient, unsafeContinuationTransport) = Self.client([
            .json(200, relationshipPage(next: "/v1/me/library/playlists/p.fixture/tracks?offset=1")),
            .json(200, #"{"data":[],"next":"https://unrelated.example/v1/me/library/playlists/p.fixture/tracks"}"#)
        ])
        var continuationRefused = false
        do { _ = try await unsafeContinuationClient.tracks(playlistID: "p.fixture") }
        catch MusicWebPlaylistClient.Failure.unsafeURL { continuationRefused = true }
        catch {}
        let continuationCount = await unsafeContinuationTransport.requests.count
        tally.check(continuationRefused && continuationCount == 2,
                    "web: continuation pages cannot change the credential destination")
    }

    private static func failures(_ tally: HarnessTally) async {
        let echoedSecrets = #"{"errors":[{"title":"fixture-developer-secret fixture-user-secret"}]}"#
        for reply in [MusicWebHarnessTransport.Reply.json(401, echoedSecrets),
                      .json(500, echoedSecrets), .json(302, echoedSecrets), .timeout] {
            let (client, transport) = client([reply])
            var errorText: String?
            do { try await client.renamePlaylist(id: "p.fixture", name: "Fixture") }
            catch { errorText = error.localizedDescription }
            let requests = await transport.requests
            tally.check(errorText != nil && requests.count == 1,
                        "web: failed or ambiguous writes are reported without retry")
            tally.check(errorText?.contains("fixture-developer-secret") == false
                        && errorText?.contains("fixture-user-secret") == false,
                        "web: error descriptions cannot echo tokens or server response bodies")
        }

        let (client, transport) = client([.json(404, "")])
        do {
            let missing = try await client.playlist(id: "p.deleted")
            let count = await transport.requests.count
            tally.check(missing == nil && count == 1,
                        "web: an absent playlist can verify successful deletion")
        } catch {
            tally.check(false, "web: missing playlist read returns nil", detail: error.localizedDescription)
        }
    }

    private static func invalidIdentifiers(_ tally: HarnessTally) async {
        for id in ["", "i.song", "p.fixture/tracks", "p.fixture?mode=all", "p.fixture#fragment", "p.é", "p.fixture%2Ftracks"] {
            let (client, transport) = client([])
            var refused = false
            do { try await client.deletePlaylist(id: id) }
            catch { refused = true }
            let count = await transport.requests.count
            tally.check(refused && count == 0, "web: rejects malformed playlist ID before a request (\(id))")
        }
        let (client, transport) = client([])
        var refused = false
        do { try await client.removeSongs(ids: ["i.safe", "i.bad&mode=all"], from: "p.fixture") }
        catch { refused = true }
        let count = await transport.requests.count
        tally.check(refused && count == 0, "web: validates every removal ID before sending any mutation")
    }
}

private actor MusicWebHarnessTransport {
    enum Reply: Sendable {
        case json(Int, String)
        case timeout
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        switch replies.removeFirst() {
        case .json(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            return (Data(body.utf8), response)
        case .timeout:
            throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey:
                "fixture-developer-secret fixture-user-secret"])
        }
    }
}
