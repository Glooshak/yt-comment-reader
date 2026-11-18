import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Theme

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

enum Theme {
    static let accent = Color(hex: 0xE4573D)
    static let accentSoft = Color(hex: 0xE4573D, opacity: 0.12)
    static let like = Color(hex: 0xE0526B)
    static let likeSoft = Color(hex: 0xE0526B, opacity: 0.10)
    static let reply = Color(hex: 0x4B84E8)
    static let replySoft = Color(hex: 0x4B84E8, opacity: 0.10)

    static let bg = Color.dynamic(light: 0xF6F3EC, dark: 0x0F1115)
    static let bgGlow = Color.dynamic(light: 0xFFF9EF, dark: 0x171B23)
    static let card = Color.dynamic(light: 0xFFFFFF, dark: 0x191C22)
    static let cardBorder = Color.dynamic(light: 0xE6E0D4, dark: 0x2B303A)
    static let chip = Color.dynamic(light: 0xEEE9DE, dark: 0x232830)
    static let chipBorder = Color.dynamic(light: 0xDDD6C7, dark: 0x343A45)
}

enum Format {
    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    static func number(_ n: Int) -> String {
        decimal.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - Models

struct Corpus: Codable {
    let schema: Int
    let video: VideoMeta
    let capturedAt: String
    let rootCount: Int
    let totalLikes: Int
    let tiers: [Tier]
    let comments: [Comment]
}

struct VideoMeta: Codable {
    let id: String
    let url: String
    let title: String?
    let channel: String?
    let views: String?
    let date: String?
    let commentsTotalDisplay: String?
}

struct Tier: Codable, Identifiable {
    let id: String
    let label: String
    let percent: Int
    let count: Int
    let cutoff: Int
}

struct Comment: Codable, Identifiable {
    let id: String
    let author: String
    let authorId: String?
    let published: String?
    let text: String
    let likes: Int
    var likesDisplay: String
    var repliesCount: Int
    let isCreator: Bool
    let isVerified: Bool
    let hearted: Bool
    var replies: [Comment]
    var repliesFetched: Int?
    var replyLevel: Int?

    var displayName: String {
        author.hasPrefix("@") ? String(author.dropFirst()) : author
    }

    var ownWordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    var totalWordCount: Int {
        ownWordCount + replies.reduce(0) { $0 + $1.totalWordCount }
    }

    var descendantCount: Int {
        replies.reduce(0) { $0 + 1 + $1.descendantCount }
    }

    var replyBadgeCount: Int {
        repliesCount > 0 ? repliesCount : descendantCount
    }
}

struct PersistedState: Codable {
    var tierID: String = "top5"
    var positions: [String: String] = [:]
}

private struct LegacyState: Codable {
    var tierID: String = ""
    var positions: [String: String] = [:]
    var corpusPath: String?
}

// MARK: - Reader model

final class ReaderModel: ObservableObject {
    @Published var corpus: Corpus?
    @Published var tierID: String = "top5"
    @Published var index: Int = 0
    @Published var isLoading = false
    @Published var loadError: String?
    @Published var notice: String?

    // fetching
    @Published var showAddVideo = false
    @Published var isFetching = false
    @Published var fetchProgress: FetchProgress?
    @Published var fetchError: String?
    @Published var urlText = ""

    // per-root reply expansion (session only)
    @Published var replyLimits: [String: Int] = [:]

    var corpusURL: URL?
    private var state = PersistedState()
    private var fetchTask: Task<Void, Never>?
    private var noticeToken = UUID()

    private let lastPathKey = "CommentReader.lastCorpusPath"

    init() {
        if let saved = UserDefaults.standard.string(forKey: lastPathKey),
           FileManager.default.fileExists(atPath: saved) {
            corpusURL = URL(fileURLWithPath: saved)
        }
    }

    private func stateKey(_ videoID: String) -> String {
        "CommentReader.reader.v2.\(videoID)"
    }

    // MARK: derived

    var tier: Tier? {
        guard let corpus else { return nil }
        return corpus.tiers.first { $0.id == tierID } ?? corpus.tiers.first
    }

    var roots: [Comment] {
        guard let corpus else { return [] }
        let count = min(tier?.count ?? 0, corpus.comments.count)
        return Array(corpus.comments.prefix(count))
    }

    var focused: Comment? {
        let items = roots
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    var canPrevious: Bool { index > 0 && !roots.isEmpty }
    var canNext: Bool { index + 1 < roots.count }

    var progressHeadline: String {
        "Top \(index + 1) of \(roots.count)"
    }

    var progressCaption: String {
        guard let tier else { return "Roots" }
        if tier.id == "all" { return "All \(tier.count) root comments" }
        return "\(tier.label) · \(Format.number(tier.cutoff))+ likes"
    }

    var progressFraction: Double {
        let n = roots.count
        guard n > 0 else { return 0 }
        return Double(min(index + 1, n)) / Double(n)
    }

    /// Reading time for the whole selected tier: every root comment in it
    /// plus all of their captured replies, at 200 words per minute.
    var tierReadingLabel: String {
        let minutes = Double(roots.reduce(0) { $0 + $1.totalWordCount }) / 200.0
        if minutes < 1 { return "<1 min" }
        let rounded = Int(minutes.rounded())
        if rounded < 60 { return "\(rounded) min" }
        let hours = rounded / 60
        let remainder = rounded % 60
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
    }

    func visibleReplyLimit(_ id: String) -> Int {
        replyLimits[id] ?? 8
    }

    func showMoreReplies(_ id: String, total: Int) {
        replyLimits[id] = min(total, visibleReplyLimit(id) + 10)
    }

    // MARK: loading

    func defaultCorpusURL() -> URL? {
        if let i = CommandLine.arguments.firstIndex(of: "--corpus"),
           CommandLine.arguments.indices.contains(i + 1) {
            return URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        if let url = corpusURL, FileManager.default.fileExists(atPath: url.path) { return url }
        if let bundled = Bundle.main.url(forResource: "corpus", withExtension: "json") { return bundled }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CommentReader/corpus.json")
        if FileManager.default.fileExists(atPath: support.path) { return support }
        return nil
    }

    func load(_ url: URL? = nil) {
        guard !isLoading else { return }
        guard let target = url ?? defaultCorpusURL() else {
            loadError = "No comment corpus found. Paste a YouTube link to download one."
            return
        }
        isLoading = true
        loadError = nil
        corpusURL = target

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: target)
                let decoded = try JSONDecoder().decode(Corpus.self, from: data)
                DispatchQueue.main.async {
                    self.corpus = decoded
                    self.isLoading = false
                    self.restoreState(for: decoded)
                    self.persistNow()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.loadError = "Could not read \(target.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    func openCorpus(_ url: URL) {
        corpus = nil
        index = 0
        replyLimits = [:]
        load(url)
    }

    private func restoreState(for corpus: Corpus) {
        var restored: PersistedState?
        if let data = UserDefaults.standard.data(forKey: stateKey(corpus.video.id)),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            restored = decoded
        } else if corpus.video.id == "EByqXjBo6Ig",
                  let data = UserDefaults.standard.data(forKey: "CommentReader.state.v1"),
                  let legacy = try? JSONDecoder().decode(LegacyState.self, from: data) {
            restored = PersistedState(tierID: legacy.tierID, positions: legacy.positions)
        }
        state = restored ?? PersistedState()

        if corpus.tiers.contains(where: { $0.id == state.tierID }) {
            tierID = state.tierID
        } else {
            tierID = corpus.tiers.first?.id ?? "top5"
        }
        index = 0
        if let id = state.positions[tierID],
           let found = roots.firstIndex(where: { $0.id == id }) {
            index = found
        }
        replyLimits = [:]
    }

    // MARK: navigation

    func next() {
        guard canNext else { return }
        index += 1
        persistNow()
    }

    func previous() {
        guard canPrevious else { return }
        index -= 1
        persistNow()
    }

    func selectTier(_ id: String) {
        guard id != tierID,
              corpus?.tiers.contains(where: { $0.id == id }) == true else { return }
        persistNow()
        tierID = id
        index = 0
        if let commentID = state.positions[id],
           let found = roots.firstIndex(where: { $0.id == commentID }) {
            index = found
        }
        persistNow()
    }

    // MARK: fetching

    func startFetch() {
        guard !isFetching else { return }
        guard let videoID = YouTubeFetcher.videoID(from: urlText) else {
            fetchError = "Paste a YouTube video link or an 11-character video ID."
            return
        }
        fetchError = nil
        isFetching = true
        fetchProgress = FetchProgress(stage: .connecting, fraction: 0.01,
                                      detail: "Reading video page…")

        let fetcher = YouTubeFetcher(videoID: videoID)
        fetchTask = Task { [weak self] in
            do {
                let corpus = try await fetcher.crawl { progress in
                    Task { @MainActor in
                        self?.fetchProgress = progress
                    }
                }
                let url = try Self.writeCorpus(corpus)
                await MainActor.run {
                    guard let self else { return }
                    self.isFetching = false
                    self.fetchProgress = nil
                    self.showAddVideo = false
                    self.urlText = ""
                    self.openCorpus(url)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isFetching = false
                    self.fetchProgress = nil
                    if Task.isCancelled {
                        self.fetchError = "Download cancelled."
                    } else {
                        self.fetchError = error.localizedDescription
                    }
                }
            }
        }
    }

    func cancelFetch() {
        fetchTask?.cancel()
        fetchTask = nil
    }

    private static func writeCorpus(_ corpus: Corpus) throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CommentReader/corpora", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("\(corpus.video.id).json")
        let data = try JSONEncoder().encode(corpus)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: persistence

    private func persistNow() {
        guard let corpus else { return }
        var next = state
        next.tierID = tierID
        if let focused {
            next.positions[tierID] = focused.id
        }
        state = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: stateKey(corpus.video.id))
        }
        if let url = corpusURL {
            UserDefaults.standard.set(url.path, forKey: lastPathKey)
        }
    }

    func flash(_ message: String) {
        let token = UUID()
        noticeToken = token
        withAnimation(.easeOut(duration: 0.18)) { notice = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            guard let self, self.noticeToken == token else { return }
            withAnimation(.easeIn(duration: 0.2)) { self.notice = nil }
        }
    }
}

// MARK: - App

@main
struct CommentReaderApp: App {
    @StateObject private var model = ReaderModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 680)
                .task { if model.corpus == nil { model.load() } }
        }
        .defaultSize(width: 1080, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Video…") {
                    NotificationCenter.default.post(name: .addVideoRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open Corpus…") {
                    NotificationCenter.default.post(name: .openCorpusRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Navigate") {
                Button("Previous Comment") { model.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next Comment") { model.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
        }
    }
}

extension Notification.Name {
    static let openCorpusRequested = Notification.Name("openCorpusRequested")
    static let addVideoRequested = Notification.Name("addVideoRequested")
}

// MARK: - Content

struct ContentView: View {
    @ObservedObject var model: ReaderModel
    @State private var showImporter = false

    var body: some View {
        ZStack {
            background
            if let corpus = model.corpus {
                VStack(spacing: 0) {
                    header(corpus)
                    divider
                    tierBar(corpus)
                    mainArea
                    divider
                    navigationBar
                }
            } else {
                emptyState
            }
            if let notice = model.notice {
                VStack {
                    Spacer()
                    Text(notice)
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(.regularMaterial))
                        .overlay(Capsule().strokeBorder(Theme.cardBorder))
                        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                        .padding(.bottom, 108)
                }
                .transition(.opacity)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                model.openCorpus(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCorpusRequested)) { _ in
            showImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .addVideoRequested)) { _ in
            model.showAddVideo = true
        }
        .sheet(isPresented: $model.showAddVideo) {
            AddVideoView(model: model)
        }
    }

    private var background: some View {
        ZStack {
            Theme.bg
            RadialGradient(colors: [Theme.bgGlow, .clear],
                           center: .topLeading, startRadius: 20, endRadius: 900)
            RadialGradient(colors: [Theme.accent.opacity(0.05), .clear],
                           center: .bottomTrailing, startRadius: 20, endRadius: 760)
        }
        .ignoresSafeArea()
    }

    private var divider: some View {
        Rectangle().fill(Theme.cardBorder.opacity(0.6)).frame(height: 1)
    }

    // MARK: header

    private func header(_ corpus: Corpus) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text((corpus.video.channel ?? "YOUTUBE").uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(Theme.accent)
                Text(corpus.video.title ?? "Comments")
                    .font(.system(size: 25, weight: .semibold, design: .serif))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let views = corpus.video.views { Text(views) }
                    if corpus.video.views != nil, corpus.video.date != nil { dot }
                    if let date = corpus.video.date { Text(date) }
                    if corpus.video.views != nil || corpus.video.date != nil { dot }
                    Text("captured \(shortDate(corpus.capturedAt))")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 10) {
                Button {
                    model.showAddVideo = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("Add video")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.accent))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(model.isFetching)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(Format.number(corpus.rootCount)) roots")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("\(Format.number(corpus.totalLikes)) likes")
                        .font(.system(size: 11.5, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("replies excluded")
                        .font(.system(size: 9.5, weight: .medium))
                        .tracking(0.4)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    private func shortDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: iso)
        }
        guard let date else { return String(iso.prefix(10)) }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.locale = Locale(identifier: "en_US")
        return out.string(from: date)
    }

    private var dot: some View {
        Circle().fill(.tertiary).frame(width: 3, height: 3)
    }

    // MARK: tiers

    private func tierBar(_ corpus: Corpus) -> some View {
        HStack(spacing: 12) {
            Text("ROOTS BY LIKES")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(.tertiary)
                .frame(width: 92, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(corpus.tiers) { tier in
                        tierPill(tier)
                    }
                }
            }

            Spacer(minLength: 0)

            if !model.roots.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("≈ \(model.tierReadingLabel)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                    Text("to read this tier")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.chip))
                .overlay(Capsule().strokeBorder(Theme.chipBorder))
                .help("Time to read all \(model.roots.count) root comments in this tier and their captured replies, at 200 words per minute")
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 13)
    }

    private func tierPill(_ tier: Tier) -> some View {
        let selected = tier.id == model.tierID
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { model.selectTier(tier.id) }
        } label: {
            HStack(spacing: 6) {
                Text(tier.label)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(tier.count)")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.7)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Capsule().fill(selected ? Theme.accent : Theme.chip))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.chipBorder, lineWidth: 1))
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: main reading area

    private var mainArea: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 16) {
                        if let root = model.focused {
                            commentCard(root)
                                .id("root")
                            repliesSection(root)
                        } else {
                            Text("No comments at this position.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(.top, 60)
                        }
                    }
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 22)
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
                .onChange(of: model.focused?.id) { _, _ in
                    proxy.scrollTo("root", anchor: .top)
                }
                .onChange(of: model.tierID) { _, _ in
                    proxy.scrollTo("root", anchor: .top)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func commentCard(_ c: Comment) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 13) {
                rankBadge
                Avatar(name: c.author, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(c.author)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        if c.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.reply)
                        }
                        if c.isCreator {
                            Text("CREATOR")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.8)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.accentSoft))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    HStack(spacing: 5) {
                        Text(c.published ?? "")
                        if c.hearted {
                            Text("·")
                            Image(systemName: "heart.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.like)
                            Text("hearted")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    StatPill(icon: "heart.fill", value: c.likesDisplay, label: "LIKES",
                             tint: Theme.like, background: Theme.likeSoft)
                    StatPill(icon: "bubble.left.fill", value: "\(c.repliesCount)", label: "REPLIES",
                             tint: Theme.reply, background: Theme.replySoft)
                }
            }

            Text(c.text.isEmpty ? "[no text]" : c.text)
                .font(.system(size: 16.5))
                .lineSpacing(5.5)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(Theme.cardBorder.opacity(0.55)).frame(height: 1)

            HStack(spacing: 10) {
                Label("Root comment", systemImage: "text.bubble")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !c.replies.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text("\(Format.number(c.replyBadgeCount)) replies below")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 1)
        )
    }

    private var rankBadge: some View {
        VStack(spacing: 0) {
            Text("#\(model.index + 1)")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("of \(model.roots.count)")
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
        }
        .frame(width: 56, height: 56)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.accentSoft))
        .foregroundStyle(Theme.accent)
    }

    // MARK: replies

    @ViewBuilder
    private func repliesSection(_ root: Comment) -> some View {
        if !root.replies.isEmpty {
            let limit = model.visibleReplyLimit(root.id)
            let visible = Array(root.replies.prefix(limit))
            let remaining = root.replies.count - visible.count

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("REPLIES")
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(.tertiary)
                    Text(replyCountText(root))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 6)

                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { pair in
                        ReplyNodeView(reply: pair.element, depth: 1, model: model)
                        if pair.offset < visible.count - 1 {
                            Rectangle()
                                .fill(Theme.cardBorder.opacity(0.45))
                                .frame(height: 1)
                                .padding(.leading, 40)
                        }
                    }
                }
                .padding(.leading, 44)
                .padding(.trailing, 22)
                .padding(.bottom, remaining > 0 ? 2 : 14)

                if remaining > 0 {
                    ShowMoreReplies(remaining: remaining) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            model.showMoreReplies(root.id, total: root.replies.count)
                        }
                    }
                    .padding(.leading, 44)
                    .padding(.top, 2)
                    .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.card.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Theme.cardBorder.opacity(0.75))
                    .frame(width: 1)
                    .padding(.leading, 26)
                    .padding(.top, 48)
                    .padding(.bottom, 34)
            }
        } else if root.repliesCount > 0 {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left")
                Text("\(root.repliesCount) replies were not captured for this comment.")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.chip.opacity(0.5)))
        }
    }

    private func replyCountText(_ root: Comment) -> String {
        let captured = root.descendantCount
        let shown = max(root.repliesCount, captured)
        if root.repliesCount > captured {
            return "\(Format.number(captured)) captured of \(Format.number(root.repliesCount))"
        }
        return "\(Format.number(shown)) \(shown == 1 ? "reply" : "replies")"
    }

    // MARK: navigation bar

    private var navigationBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                NavCircle(icon: "chevron.left", enabled: model.canPrevious) {
                    withAnimation(.easeOut(duration: 0.12)) { model.previous() }
                }

                Spacer()

                VStack(spacing: 3) {
                    Text(model.progressHeadline)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(model.progressCaption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                NavCircle(icon: "chevron.right", enabled: model.canNext) {
                    withAnimation(.easeOut(duration: 0.12)) { model.next() }
                }
            }
            .padding(.horizontal, 30)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.chip)
                    Capsule().fill(Theme.accent)
                        .frame(width: max(5, geo.size.width * model.progressFraction))
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 30)

            Text("← →  next root comment      scroll to read replies")
                .font(.system(size: 9.5, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 14)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial)
    }

    // MARK: empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(Theme.accentSoft).frame(width: 74, height: 74)
                Image(systemName: model.isLoading ? "hourglass" : "text.bubble.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.accent)
            }

            if model.isLoading {
                Text("Loading comments…")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                ProgressView().controlSize(.small)
            } else {
                VStack(spacing: 8) {
                    Text("Comment Reader")
                        .font(.system(size: 27, weight: .semibold, design: .serif))
                    Text("Paste a YouTube link and download every root comment and reply, then read them one at a time.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }

                AddVideoForm(model: model)
                    .frame(maxWidth: 560)
                    .padding(.top, 4)

                if let error = model.loadError, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }

                Button {
                    showImporter = true
                } label: {
                    Text("Or open a corpus.json file")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .underline()
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

// MARK: - Add video

struct AddVideoView: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add a video")
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                    Text("Download every root comment and reply.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.isFetching {
                    Button {
                        model.showAddVideo = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(7)
                            .background(Circle().fill(Theme.chip))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            AddVideoForm(model: model)

            if !model.isFetching {
                Text("The app crawls YouTube's public comment API: roots first, then every reply thread. A video with thousands of comments takes several minutes.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(26)
        .frame(width: 500)
    }
}

struct AddVideoForm: View {
    @ObservedObject var model: ReaderModel

    private var canFetch: Bool {
        !model.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isFetching
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isFetching {
                FetchProgressView(model: model)
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("https://www.youtube.com/watch?v=…", text: $model.urlText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit { if canFetch { model.startFetch() } }
                    if !model.urlText.isEmpty {
                        Button {
                            model.urlText = ""
                            model.fetchError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        model.startFetch()
                    } label: {
                        Text("Fetch")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(canFetch ? Theme.accent : Theme.chipBorder))
                            .foregroundStyle(canFetch ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canFetch)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.chip))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.chipBorder))

                if let error = model.fetchError, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct FetchProgressView: View {
    @ObservedObject var model: ReaderModel

    private func title(for stage: FetchStage) -> String {
        switch stage {
        case .connecting: return "Connecting to YouTube"
        case .roots: return "Downloading root comments"
        case .replies: return "Downloading replies"
        case .building: return "Processing comments"
        case .finished: return "Finishing up"
        }
    }

    var body: some View {
        let progress = model.fetchProgress ?? FetchProgress()
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text(title(for: progress.stage))
                    .font(.system(size: 13, weight: .semibold))
                if progress.stage == .connecting || progress.stage == .roots {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text("\(Int((progress.fraction * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: min(max(progress.fraction, 0), 1))
                .progressViewStyle(.linear)
                .tint(Theme.accent)

            Text(progress.detail.isEmpty ? "Starting…" : progress.detail)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack {
                Text("\(Format.number(progress.roots)) roots · \(Format.number(progress.replies)) replies")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { model.cancelFetch() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.chip.opacity(0.55)))
    }
}

// MARK: - Components

struct Avatar: View {
    let name: String
    var size: CGFloat = 36

    var body: some View {
        let seed = abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        let hue = Double(seed % 360) / 360.0
        let initial = name.hasPrefix("@")
            ? (name.dropFirst().first.map { String($0).uppercased() } ?? "?")
            : (name.first.map { String($0).uppercased() } ?? "?")

        Text(initial)
            .font(.system(size: size * 0.37, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Color(hue: hue, saturation: 0.5, brightness: 0.82),
                                        Color(hue: (hue + 0.07).truncatingRemainder(dividingBy: 1),
                                              saturation: 0.55, brightness: 0.62)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(Circle())
    }
}

struct ReplyRow: View {
    let reply: Comment
    @State private var expanded = false

    private var isLong: Bool { reply.text.count > 700 }

    private var displayText: String {
        guard isLong, !expanded else { return reply.text }
        let cutoff = reply.text.index(reply.text.startIndex, offsetBy: 620)
        return String(reply.text[..<cutoff]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: reply.author, size: 30)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(reply.author)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if reply.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.reply)
                    }
                    if reply.isCreator {
                        Text("CREATOR")
                            .font(.system(size: 7.5, weight: .bold))
                            .tracking(0.7)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Theme.accentSoft))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(reply.published ?? "")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(displayText.isEmpty ? "[no text]" : displayText)
                    .font(.system(size: 14.5))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if isLong {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        Text(expanded ? "Show less" : "Read more")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 14) {
                    Label(reply.likesDisplay, systemImage: "heart.fill")
                    if reply.replyBadgeCount > 0 {
                        Label("\(reply.replyBadgeCount)", systemImage: "bubble.left.fill")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.top, 1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
    }
}

struct ReplyNodeView: View {
    let reply: Comment
    let depth: Int
    @ObservedObject var model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReplyRow(reply: reply)

            if !reply.replies.isEmpty {
                let limit = model.visibleReplyLimit(reply.id)
                let visible = Array(reply.replies.prefix(limit))
                let remaining = reply.replies.count - visible.count

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { pair in
                        ReplyNodeView(reply: pair.element, depth: depth + 1, model: model)
                        if pair.offset < visible.count - 1 {
                            Rectangle()
                                .fill(Theme.cardBorder.opacity(0.4))
                                .frame(height: 1)
                                .padding(.leading, 24)
                        }
                    }
                    if remaining > 0 {
                        ShowMoreReplies(remaining: remaining) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                model.showMoreReplies(reply.id, total: reply.replies.count)
                            }
                        }
                        .padding(.bottom, 2)
                    }
                }
                .padding(.leading, 26)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.cardBorder.opacity(0.65))
                        .frame(width: 1)
                        .padding(.leading, 9)
                        .padding(.vertical, 4)
                }
            }
        }
    }
}

struct ShowMoreReplies: View {
    let remaining: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                Text("Show more replies")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(remaining) left")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.accent)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StatPill: View {
    let icon: String
    let value: String
    let label: String
    let tint: Color
    let background: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background))
    }
}

struct NavCircle: View {
    let icon: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(enabled ? Theme.card : Theme.chip.opacity(0.4)))
                .overlay(Circle().strokeBorder(Theme.cardBorder))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.35))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
