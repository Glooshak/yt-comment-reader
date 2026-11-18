import Foundation

// MARK: - Progress

enum FetchStage: String {
    case connecting
    case roots
    case replies
    case building
    case finished
}

struct FetchProgress {
    var stage: FetchStage = .connecting
    var fraction: Double = 0
    var detail: String = ""
    var roots: Int = 0
    var replies: Int = 0
    var threadsDone: Int = 0
    var threadsTotal: Int = 0
}

enum FetcherError: LocalizedError {
    case badVideo
    case watchPage
    case noComments
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badVideo:
            return "That doesn't look like a YouTube video link or ID."
        case .watchPage:
            return "Could not read the YouTube video page."
        case .noComments:
            return "No comment section found. Comments may be disabled or the video unavailable."
        case .http(let code):
            return "YouTube returned HTTP \(code). Try again in a moment."
        }
    }
}

// MARK: - Fetcher

final class YouTubeFetcher {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    let videoID: String
    private let session: URLSession
    private var apiKey = ""
    private var clientVersion = ""
    private var initial: [String: Any] = [:]
    private var embeddedContext: [String: Any]?
    private var sectionToken = ""
    private var allPayloads: [String: [String: Any]] = [:]
    private var replySeenTokens = Set<String>()
    private var replySeenIDs = Set<String>()
    private let maxReplyDepth = 8
    private var lastRequest = Date.distantPast

    init(videoID: String) {
        self.videoID = videoID
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 40
        config.timeoutIntervalForResource = 90
        config.httpAdditionalHeaders = ["Accept-Language": "en-US,en;q=0.9"]
        self.session = URLSession(configuration: config)
    }

    static func videoID(from input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            "(?:v=)([A-Za-z0-9_-]{11})",
            "youtu\\.be/([A-Za-z0-9_-]{11})",
            "/shorts/([A-Za-z0-9_-]{11})",
            "/embed/([A-Za-z0-9_-]{11})",
            "/live/([A-Za-z0-9_-]{11})",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
               let range = Range(match.range(at: 1), in: value) {
                return String(value[range])
            }
        }
        if value.count == 11,
           value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
            return value
        }
        return nil
    }

    // MARK: network

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetcherError.watchPage }
        guard http.statusCode == 200 else { throw FetcherError.http(http.statusCode) }
        return data
    }

    private func throttle() async throws {
        let elapsed = Date().timeIntervalSince(lastRequest)
        if elapsed < 0.32 {
            try await Task.sleep(nanoseconds: UInt64((0.32 - elapsed) * 1_000_000_000))
        }
    }

    private func post(_ token: String, useThreadedContext: Bool = true) async throws -> [String: Any] {
        try Task.checkCancellation()
        try await throttle()
        let url = URL(string: "https://www.youtube.com/youtubei/v1/next?key=\(apiKey)&prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/watch?v=\(videoID)", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        var context: [String: Any]
        if useThreadedContext, let embeddedContext {
            context = embeddedContext
        } else {
            context = [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": clientVersion,
                    "hl": "en",
                    "gl": "US",
                    "originalUrl": "https://www.youtube.com/watch?v=\(videoID)",
                ],
            ]
        }
        context["user"] = ["lockedSafetyMode": false]
        let body: [String: Any] = [
            "context": context,
            "continuation": token,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        lastRequest = Date()
        guard let http = response as? HTTPURLResponse else { throw FetcherError.http(0) }
        guard http.statusCode == 200 else { throw FetcherError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetcherError.watchPage
        }
        return json
    }

    // MARK: crawl

    func crawl(progress: @escaping (FetchProgress) -> Void) async throws -> Corpus {
        progress(FetchProgress(stage: .connecting, fraction: 0.02, detail: "Reading video page…"))
        try await loadWatchPage()

        var state = FetchProgress(stage: .roots, fraction: 0.05, detail: "Reading root comments…")
        progress(state)

        let (roots, replyTokens) = try await crawlRoots { count, page in
            state.roots = count
            state.fraction = 0.05 + 0.15 * min(1.0, Double(page) / 40.0)
            state.detail = "Root page \(page) · \(count) comments found"
            progress(state)
        }

        let threads = roots.indices.filter { replyTokens[roots[$0].id] != nil }
        state.stage = .replies
        state.threadsTotal = threads.count
        state.fraction = 0.25
        state.detail = "Found \(roots.count) roots · fetching replies for \(threads.count) threads"
        state.replies = 0
        progress(state)

        var comments = roots
        for (offset, rootIndex) in threads.enumerated() {
            try Task.checkCancellation()
            if let token = replyTokens[comments[rootIndex].id] {
                do {
                    let replies = try await fetchChildList(token: token, depth: 1)
                    var root = comments[rootIndex]
                    root.replies = replies
                    root.replies = normalizeReplies(root: root)

                    // Some threads come back empty in the threaded format even
                    // though YouTube still serves them in the legacy flat list.
                    if descendantCount(of: root) < root.repliesCount {
                        let existing = allReplyIDs(of: root).union([root.id])
                        if let flat = try? await fetchFlatReplies(token: token, excluding: existing),
                           !flat.isEmpty {
                            root.replies.append(contentsOf: flat)
                        }
                    }

                    let count = descendantCount(of: root)
                    root.repliesFetched = count
                    root.repliesCount = max(root.repliesCount, count)
                    comments[rootIndex] = root
                    state.replies += count
                    if count == 0, root.repliesCount > 0 {
                        let line = "EMPTY \(root.author) \(root.id) token=\(token.prefix(12)) declared=\(root.repliesCount)\n"
                        FileHandle.standardError.write(line.data(using: .utf8)!)
                    }
                } catch {
                    let line = "THREAD-ERROR \(comments[rootIndex].author): \(error)\n"
                    FileHandle.standardError.write(line.data(using: .utf8)!)
                }
            } else if comments[rootIndex].repliesCount > 0 {
                let line = "NO-TOKEN \(comments[rootIndex].author) \(comments[rootIndex].id) declared=\(comments[rootIndex].repliesCount)\n"
                FileHandle.standardError.write(line.data(using: .utf8)!)
            }
            state.threadsDone = offset + 1
            state.fraction = 0.25 + 0.70 * Double(offset + 1) / Double(max(1, threads.count))
            state.detail = "Reply thread \(offset + 1) of \(threads.count) · \(state.replies) replies"
            state.roots = comments.count
            progress(state)
            try await Task.sleep(nanoseconds: 80_000_000)
        }

        // roots with zero replies
        for i in comments.indices where comments[i].repliesFetched == nil {
            comments[i].repliesFetched = 0
        }

        state.stage = .building
        state.fraction = 0.97
        state.detail = "Building the reading index…"
        progress(state)

        comments.sort {
            if $0.likes != $1.likes { return $0.likes > $1.likes }
            return $0.id < $1.id
        }
        let totalLikes = comments.reduce(0) { $0 + $1.likes }
        let corpus = Corpus(
            schema: 1,
            video: videoMeta(),
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            rootCount: comments.count,
            totalLikes: totalLikes,
            tiers: Self.buildTiers(comments),
            comments: comments
        )

        var done = state
        done.stage = .finished
        done.fraction = 1
        done.detail = "Done · \(comments.count) roots and \(state.replies) replies"
        progress(done)
        return corpus
    }

    private func loadWatchPage() async throws {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)&hl=en&gl=US") else {
            throw FetcherError.badVideo
        }
        let data = try await get(url)
        guard let html = String(data: data, encoding: .utf8) else { throw FetcherError.watchPage }
        guard let match = Self.regex(html, "ytInitialData\\s*=\\s*(\\{.*?\\});</script>", dotAll: true),
              let jsonData = String(html[match]).data(using: .utf8) else {
            throw FetcherError.watchPage
        }
        let obj: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { throw FetcherError.watchPage }
            obj = parsed
        } catch {
            throw FetcherError.watchPage
        }
        initial = obj
        embeddedContext = Self.extractJSONObject(html, key: "INNERTUBE_CONTEXT")
        guard let key = Self.regex(html, "\"INNERTUBE_API_KEY\":\"([^\"]+)\""),
              let version = Self.regex(html, "\"INNERTUBE_CLIENT_VERSION\":\"([^\"]+)\"") else {
            throw FetcherError.watchPage
        }
        apiKey = String(html[key])
        clientVersion = String(html[version])
        guard let token = commentSectionToken(initial) ?? Self.firstToken(initial) else {
            throw FetcherError.noComments
        }
        sectionToken = token
    }

    private func commentSectionToken(_ data: [String: Any]) -> String? {
        var found: String?
        walk(data) { dict in
            guard found == nil,
                  dict["sectionIdentifier"] as? String == "comment-item-section",
                  let contents = dict["contents"] else { return }
            found = Self.firstToken(contents)
        }
        return found
    }

    private func crawlRoots(progress: @escaping (Int, Int) -> Void) async throws
        -> ([Comment], [String: String]) {
        var roots: [Comment] = []
        var replyTokens: [String: String] = [:]
        var seen = Set<String>()
        var token: String? = sectionToken
        var page = 0
        var restarted = false
        var zeroStreak = 0

        while let current = token, page < 300 {
            try Task.checkCancellation()
            page += 1
            let data = try await post(current)
            absorbPayloads(data)
            let entries = threadEntries(data)

            if !restarted, let sort = sortInfo(data),
               (sort.selected ?? "").lowercased() != "top",
               let topToken = sort.tokens["top"] {
                restarted = true
                token = topToken
                page = 0
                roots.removeAll()
                seen.removeAll()
                continue
            }

            var added = 0
            for entry in entries {
                guard !seen.contains(entry.id), let payload = allPayloads[entry.id],
                      let comment = comment(from: payload) else { continue }
                seen.insert(entry.id)
                roots.append(comment)
                if let replyToken = entry.replyToken {
                    replyTokens[entry.id] = replyToken
                }
                added += 1
            }

            progress(roots.count, page)
            zeroStreak = added == 0 ? zeroStreak + 1 : 0
            let next = pageNextToken(data)
            if next == nil || next == current || zeroStreak >= 2 { break }
            token = next
            try await Task.sleep(nanoseconds: 180_000_000)
        }

        guard !roots.isEmpty else { throw FetcherError.noComments }
        return (roots, replyTokens)
    }

    private func fetchChildList(token: String, depth: Int) async throws -> [Comment] {
        var children: [Comment] = []
        var current: String? = token
        var pages = 0

        while let tok = current, pages < 100 {
            try Task.checkCancellation()
            pages += 1
            guard !replySeenTokens.contains(tok) else { break }
            replySeenTokens.insert(tok)

            let data = try await post(tok)
            absorbPayloads(data)
            var pageNext: String?

            for item in continuationItems(data) {
                if let thread = item["commentThreadRenderer"] as? [String: Any] {
                    if let node = try await parseThread(thread, depth: depth) {
                        children.append(node)
                    }
                    continue
                }
                // Flat fallback (old response format).
                if let viewModel = item["commentViewModel"] as? [String: Any],
                   let cid = viewModel["commentId"] as? String,
                   !replySeenIDs.contains(cid),
                   let payload = allPayloads[cid],
                   let node = comment(from: payload) {
                    replySeenIDs.insert(cid)
                    children.append(node)
                    continue
                }
                if let cir = item["continuationItemRenderer"] as? [String: Any],
                   let nextToken = buttonToken(cir),
                   buttonText(cir).lowercased().hasPrefix("show more") {
                    pageNext = nextToken
                }
            }

            current = pageNext
            if current != nil {
                try await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        return children
    }

    private func parseThread(_ thread: [String: Any], depth: Int) async throws -> Comment? {
        guard let outer = thread["commentViewModel"] as? [String: Any],
              let viewModel = outer["commentViewModel"] as? [String: Any],
              let cid = viewModel["commentId"] as? String,
              let payload = allPayloads[cid],
              !replySeenIDs.contains(cid),
              var node = comment(from: payload) else { return nil }
        replySeenIDs.insert(cid)

        if depth < maxReplyDepth,
           let replies = thread["replies"] as? [String: Any],
           let renderer = replies["commentRepliesRenderer"] as? [String: Any] {
            var continuations: [String] = []
            for sub in renderer["subThreads"] as? [[String: Any]] ?? [] {
                if let subThread = sub["commentThreadRenderer"] as? [String: Any] {
                    if let child = try await parseThread(subThread, depth: depth + 1) {
                        node.replies.append(child)
                    }
                } else if let cir = sub["continuationItemRenderer"] as? [String: Any],
                          let token = buttonToken(cir) {
                    continuations.append(token)
                }
            }
            for token in continuations {
                let children = try await fetchChildList(token: token, depth: depth + 1)
                node.replies.append(contentsOf: children)
            }
        }

        let descendants = descendantCount(of: node)
        node.repliesCount = max(node.repliesCount, descendants)
        node.repliesFetched = node.replies.count
        return node
    }

    private func descendantCount(of node: Comment) -> Int {
        node.replies.reduce(0) { $0 + 1 + descendantCount(of: $1) }
    }

    private func allReplyIDs(of node: Comment) -> Set<String> {
        var ids = Set<String>()
        func collect(_ items: [Comment]) {
            for item in items {
                ids.insert(item.id)
                collect(item.replies)
            }
        }
        collect(node.replies)
        return ids
    }

    /// Legacy flat reply list, used to recover threads the threaded endpoint
    /// omits. These comments are attached directly to the root because the
    /// flat format carries no parent information.
    private func fetchFlatReplies(token: String, excluding excluded: Set<String>) async throws
        -> [Comment] {
        var added: [Comment] = []
        var seen = excluded
        var seenTokens = Set<String>()
        var current: String? = token
        var pages = 0

        while let tok = current, pages < 100 {
            try Task.checkCancellation()
            pages += 1
            guard seenTokens.insert(tok).inserted else { break }
            let data = try await post(tok, useThreadedContext: false)
            absorbPayloads(data)
            var pageNext: String?

            for item in continuationItems(data) {
                var cid: String?
                if let vm = item["commentViewModel"] as? [String: Any] {
                    cid = vm["commentId"] as? String
                } else if let thread = item["commentThreadRenderer"] as? [String: Any],
                          let outer = thread["commentViewModel"] as? [String: Any],
                          let vm = outer["commentViewModel"] as? [String: Any] {
                    cid = vm["commentId"] as? String
                }
                if let cid, !seen.contains(cid), let payload = allPayloads[cid],
                   let node = comment(from: payload) {
                    seen.insert(cid)
                    added.append(node)
                    continue
                }
                if let cir = item["continuationItemRenderer"] as? [String: Any],
                   let nextToken = buttonToken(cir),
                   buttonText(cir).lowercased().hasPrefix("show more") {
                    pageNext = nextToken
                }
            }

            current = pageNext
            if current != nil {
                try await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        return added
    }

    // MARK: tree normalization

    private final class TreeNode {
        let comment: Comment
        var children: [TreeNode] = []
        init(_ comment: Comment) { self.comment = comment }
    }

    private struct FlatComment {
        let comment: Comment
        let serverParentID: String
        let actualDepth: Int
        let targetLevel: Int
        let topLevelID: String
    }

    /// YouTube occasionally returns a deep reply flattened among its
    /// grandparent's children while still reporting the true `replyLevel`.
    /// Rebuild the tree using the authoritative level and, for ambiguous
    /// siblings, the leading @mention.
    private func normalizeReplies(root: Comment) -> [Comment] {
        var flat: [FlatComment] = []

        func collect(_ items: [Comment], parentID: String, depth: Int, topID: String) {
            for original in items {
                var item = original
                let children = item.replies
                item.replies = []
                let top = depth == 1 ? item.id : topID
                let target = max(1, min(item.replyLevel ?? depth, maxReplyDepth + 1))
                flat.append(FlatComment(comment: item, serverParentID: parentID,
                                        actualDepth: depth, targetLevel: target,
                                        topLevelID: top))
                collect(children, parentID: item.id, depth: depth + 1, topID: top)
            }
        }
        collect(root.replies, parentID: root.id, depth: 1, topID: "")
        guard !flat.isEmpty else { return [] }

        var levelNodes: [Int: [(id: String, author: String, top: String)]] = [:]
        var correctedParent: [String: String] = [:]

        for item in flat {
            if item.targetLevel > item.actualDepth {
                let candidates = (levelNodes[item.targetLevel - 1] ?? [])
                    .filter { $0.top == item.topLevelID }
                var chosen: String?
                if let mention = Self.leadingMention(item.comment.text) {
                    chosen = candidates.last {
                        $0.author.lowercased() == mention
                    }?.id
                }
                chosen = chosen ?? candidates.last?.id
                if let chosen { correctedParent[item.comment.id] = chosen }
            }
            levelNodes[item.targetLevel, default: []].append(
                (item.comment.id, item.comment.author, item.topLevelID)
            )
        }

        var nodes: [String: TreeNode] = [:]
        for item in flat { nodes[item.comment.id] = TreeNode(item.comment) }

        var childrenByParent: [String: [TreeNode]] = [:]
        for item in flat {
            let parentID = correctedParent[item.comment.id] ?? item.serverParentID
            if let node = nodes[item.comment.id] {
                childrenByParent[parentID, default: []].append(node)
            }
        }

        func materialize(_ id: String) -> [Comment] {
            (childrenByParent[id] ?? []).map { node in
                var comment = node.comment
                comment.replies = materialize(comment.id)
                comment.repliesFetched = comment.replies.count
                comment.repliesCount = max(comment.repliesCount,
                                           descendantCount(of: comment))
                return comment
            }
        }
        return materialize(root.id)
    }

    private static func leadingMention(_ text: String) -> String? {
        let invisibles = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}")
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.trimmingCharacters(in: invisibles)
        guard trimmed.hasPrefix("@") else { return nil }
        let handle = trimmed.prefix { !$0.isWhitespace }
        let cleaned = String(handle).trimmingCharacters(
            in: CharacterSet(charactersIn: ",.;:!?)]}\"'")
        )
        return cleaned.count > 1 ? cleaned.lowercased() : nil
    }

    // MARK: parsing helpers

    private static func extractJSONObject(_ text: String, key: String) -> [String: Any]? {
        guard let keyRange = text.range(of: "\"\(key)\"") else { return nil }
        guard let start = text[keyRange.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let json = String(text[start...index])
                        guard let data = json.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data)
                                as? [String: Any] else { return nil }
                        return object
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func regex(_ text: String, _ pattern: String, dotAll: Bool = false)
        -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: dotAll ? [.dotMatchesLineSeparators] : []
        ) else { return nil }
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return Range(match.range(at: 1), in: text)
    }

    private func walk(_ value: Any, _ body: ([String: Any]) -> Void) {
        if let dict = value as? [String: Any] {
            body(dict)
            for (_, child) in dict { walk(child, body) }
        } else if let array = value as? [Any] {
            for child in array { walk(child, body) }
        }
    }

    private static func firstToken(_ value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let command = dict["continuationCommand"] as? [String: Any],
               let token = command["token"] as? String, !token.isEmpty {
                return token
            }
            for (_, child) in dict {
                if let token = firstToken(child) { return token }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let token = firstToken(child) { return token }
            }
        }
        return nil
    }

    private func absorbPayloads(_ data: [String: Any]) {
        walk(data) { dict in
            guard let payload = dict["commentEntityPayload"] as? [String: Any],
                  let props = payload["properties"] as? [String: Any],
                  let cid = props["commentId"] as? String else { return }
            allPayloads[cid] = payload
        }
    }

    private struct ThreadEntry {
        let id: String
        let replyToken: String?
    }

    private func threadEntries(_ data: [String: Any]) -> [ThreadEntry] {
        var out: [ThreadEntry] = []
        walk(data) { dict in
            guard let thread = dict["commentThreadRenderer"] as? [String: Any],
                  let outer = thread["commentViewModel"] as? [String: Any],
                  let viewModel = outer["commentViewModel"] as? [String: Any],
                  let cid = viewModel["commentId"] as? String else { return }
            var token: String?
            if let replies = thread["replies"] as? [String: Any],
               let renderer = replies["commentRepliesRenderer"] as? [String: Any] {
                for sub in renderer["subThreads"] as? [[String: Any]] ?? [] {
                    if let cir = sub["continuationItemRenderer"] as? [String: Any],
                       let continuation = buttonToken(cir) {
                        token = continuation
                        break
                    }
                }
                if token == nil {
                    token = Self.firstToken(renderer["contents"] ?? [:])
                        ?? Self.firstToken(renderer)
                }
            }
            out.append(ThreadEntry(id: cid, replyToken: token))
        }
        return out
    }

    private func continuationItems(_ data: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        guard let endpoints = data["onResponseReceivedEndpoints"] as? [[String: Any]] else {
            return out
        }
        for endpoint in endpoints {
            for (key, value) in endpoint where key != "clickTrackingParams" {
                if let dict = value as? [String: Any],
                   let items = dict["continuationItems"] as? [[String: Any]] {
                    out.append(contentsOf: items)
                }
            }
        }
        return out
    }

    private func pageNextToken(_ data: [String: Any]) -> String? {
        for item in continuationItems(data).reversed() {
            guard let cir = item["continuationItemRenderer"] as? [String: Any],
                  let endpoint = cir["continuationEndpoint"] as? [String: Any],
                  let command = endpoint["continuationCommand"] as? [String: Any],
                  let token = command["token"] as? String else { continue }
            return token
        }
        return nil
    }

    private func buttonToken(_ cir: [String: Any]) -> String? {
        if let endpoint = cir["continuationEndpoint"] as? [String: Any],
           let command = endpoint["continuationCommand"] as? [String: Any],
           let token = command["token"] as? String {
            return token
        }
        if let button = cir["button"] as? [String: Any],
           let renderer = button["buttonRenderer"] as? [String: Any],
           let command = renderer["command"] as? [String: Any],
           let continuation = command["continuationCommand"] as? [String: Any],
           let token = continuation["token"] as? String {
            return token
        }
        return nil
    }

    private func buttonText(_ cir: [String: Any]) -> String {
        guard let button = cir["button"] as? [String: Any],
              let renderer = button["buttonRenderer"] as? [String: Any],
              let text = renderer["text"] as? [String: Any],
              let runs = text["runs"] as? [[String: Any]] else { return "" }
        return runs.compactMap { $0["text"] as? String }.joined()
    }

    private func sortInfo(_ data: [String: Any])
        -> (selected: String?, tokens: [String: String])? {
        var result: (String?, [String: String])?
        walk(data) { dict in
            guard result == nil,
                  let menu = dict["sortFilterSubMenuRenderer"] as? [String: Any] else { return }
            var selected: String?
            var tokens: [String: String] = [:]
            for item in menu["subMenuItems"] as? [[String: Any]] ?? [] {
                let title = item["title"] as? String ?? ""
                if item["selected"] as? Bool == true { selected = title }
                if let endpoint = item["serviceEndpoint"] as? [String: Any],
                   let command = endpoint["continuationCommand"] as? [String: Any],
                   let token = command["token"] as? String {
                    tokens[title.lowercased()] = token
                }
            }
            result = (selected, tokens)
        }
        return result
    }

    private func comment(from payload: [String: Any]) -> Comment? {
        guard let props = payload["properties"] as? [String: Any],
              let cid = props["commentId"] as? String else { return nil }
        let toolbar = payload["toolbar"] as? [String: Any] ?? [:]
        let author = payload["author"] as? [String: Any] ?? [:]
        let content = props["content"] as? [String: Any] ?? [:]
        let text = content["content"] as? String ?? ""
        let likesDisplay = (toolbar["likeCountNotliked"] as? String)
            ?? (toolbar["likeCountLiked"] as? String)
            ?? (toolbar["likeCountA11y"] as? String) ?? "0"
        let repliesCount = max(
            Self.parseCount(toolbar["replyCount"] as? String),
            Self.parseCount(toolbar["replyCountA11y"] as? String)
        )
        return Comment(
            id: cid,
            author: author["displayName"] as? String ?? "",
            authorId: author["channelId"] as? String,
            published: props["publishedTime"] as? String,
            text: text,
            likes: Self.parseCount(likesDisplay),
            likesDisplay: likesDisplay,
            repliesCount: repliesCount,
            isCreator: author["isCreator"] as? Bool ?? false,
            isVerified: author["isVerified"] as? Bool ?? false,
            hearted: toolbar["heartActiveTooltip"] as? String != nil,
            replies: [],
            repliesFetched: 0,
            replyLevel: props["replyLevel"] as? Int
        )
    }

    static func parseCount(_ value: String?) -> Int {
        guard var string = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return 0 }
        string = string.replacingOccurrences(of: ",", with: "")
        let scanner = Scanner(string: string)
        scanner.locale = Locale(identifier: "en_US_POSIX")
        guard let number = scanner.scanDouble() else { return 0 }
        let rest = String(string[scanner.currentIndex...])
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        let multiplier: Double
        switch rest.first {
        case "K": multiplier = 1_000
        case "M": multiplier = 1_000_000
        case "B": multiplier = 1_000_000_000
        default: multiplier = 1
        }
        return Int((number * multiplier).rounded())
    }

    private func videoMeta() -> VideoMeta {
        var title: String?
        var channel: String?
        var views: String?
        var date: String?
        var total: String?

        walk(initial) { dict in
            if title == nil, let primary = dict["videoPrimaryInfoRenderer"] as? [String: Any] {
                if let runs = (primary["title"] as? [String: Any])?["runs"] as? [[String: Any]] {
                    title = runs.compactMap { $0["text"] as? String }.joined()
                }
                if let counter = primary["videoViewCountRenderer"] as? [String: Any],
                   let viewCount = counter["viewCount"] as? [String: Any] {
                    if let simple = viewCount["simpleText"] as? String {
                        views = simple
                    } else if let runs = viewCount["runs"] as? [[String: Any]] {
                        views = runs.compactMap { $0["text"] as? String }.joined()
                    }
                }
                date = (primary["dateText"] as? [String: Any])?["simpleText"] as? String
            }
            if channel == nil, let owner = dict["videoOwnerRenderer"] as? [String: Any],
               let runs = (owner["title"] as? [String: Any])?["runs"] as? [[String: Any]] {
                channel = runs.compactMap { $0["text"] as? String }.joined()
            }
            if total == nil, let header = dict["commentsEntryPointHeaderRenderer"] as? [String: Any],
               let count = header["commentCount"] as? [String: Any] {
                total = count["simpleText"] as? String
            }
        }

        return VideoMeta(id: videoID,
                         url: "https://www.youtube.com/watch?v=\(videoID)",
                         title: title,
                         channel: channel,
                         views: views,
                         date: date,
                         commentsTotalDisplay: total)
    }

    private static func roundHalfEven(_ x: Double) -> Int {
        let floorValue = floor(x)
        let diff = x - floorValue
        if diff < 0.5 { return Int(floorValue) }
        if diff > 0.5 { return Int(floorValue) + 1 }
        let lower = Int(floorValue)
        return lower.isMultiple(of: 2) ? lower : lower + 1
    }

    static func buildTiers(_ comments: [Comment]) -> [Tier] {
        let n = comments.count
        let descending = comments.map(\.likes).sorted(by: >)
        var tiers: [Tier] = []
        for pct in [1, 5, 10, 25, 50] {
            let k = max(1, roundHalfEven(Double(n) * Double(pct) / 100.0))
            let cutoff = k <= n ? descending[k - 1] : 0
            tiers.append(Tier(id: "top\(pct)", label: "Top \(pct)%", percent: pct,
                              count: k, cutoff: cutoff))
        }
        tiers.append(Tier(id: "all", label: "All roots", percent: 100,
                          count: n, cutoff: descending.last ?? 0))
        return tiers
    }
}
