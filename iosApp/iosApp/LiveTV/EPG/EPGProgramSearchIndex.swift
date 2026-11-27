import Foundation

struct EPGProgramSearchIndex: Sendable {
    struct Identity: Hashable, Sendable {
        let providerID: UUID
        let catalogRevision: Int
        let guideGeneration: Int
    }

    enum MatchQuality: Int, Comparable, Sendable {
        case titlePrefix = 0, titleWordPrefix, titleSubstring, subtitle
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Match: Equatable, Sendable {
        let programID: String
        let channelKey: String
        let channelID: String
        let channelName: String
        let channelOrdinal: Int
        let title: String
        let subtitle: String?
        let start: Date
        let end: Date
        let isLive: Bool
        let quality: MatchQuality
    }

    static let minimumQueryLength = 2
    static let defaultResultLimit = 300
    let identity: Identity
    let localeIdentifier: String
    let programCount: Int
    let uniqueTextCount: Int
    let estimatedStorageBytes: Int

    private struct Text: Sendable {
        let original: String
        let folded: String
        let isASCII: Bool
    }
    private struct Posting: Sendable {
        let titleText: Int32
        let subtitleText: Int32
        let channel: Int32
        let start: TimeInterval
        let end: TimeInterval
        let id: String
    }
    private struct Channel: Sendable {
        let key: String
        let id: String
        let name: String
        let ordinal: Int
    }
    private let locale: Locale
    private let texts: [Text]
    private let postings: [Posting]
    private let channelSlots: [Channel]
    private let textPostings: [[Int]]

    private init?(identity: Identity, guide: EPGIndex, channels: [LiveTVChannel], now: Date,
                  locale: Locale) {
        guard !guide.isSQLiteBacked else { return nil }
        self.identity = identity
        self.locale = locale
        localeIdentifier = locale.identifier
        var channelByKey: [String: Int] = [:]
        var builtChannels: [Channel] = []
        for (ordinal, channel) in channels.enumerated() {
            if ordinal.isMultiple(of: 256), Task.isCancelled { return nil }
            guard let key = guide.channelKey(guideID: channel.guideID, name: channel.name),
                  channelByKey[key] == nil else { continue }
            channelByKey[key] = builtChannels.count
            builtChannels.append(Channel(key: key, id: channel.id, name: channel.name, ordinal: ordinal))
        }

        var builtTexts: [Text] = []
        var textIDs: [String: Int] = [:]
        var builtPostings: [Posting] = []
        var postingLists: [[Int]] = []
        func intern(_ value: String) -> Int {
            let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            let key = value + "\u{0}" + folded
            if let existing = textIDs[key] { return existing }
            let index = builtTexts.count
            textIDs[key] = index
            builtTexts.append(Text(original: value, folded: folded,
                                   isASCII: value.unicodeScalars.allSatisfy { $0.value < 128 }))
            postingLists.append([])
            return index
        }
        for (slot, channel) in builtChannels.enumerated() {
            guard let programs = guide.programsByChannel[channel.key] else { continue }
            for (offset, program) in programs.enumerated() {
                if offset.isMultiple(of: 256), Task.isCancelled { return nil }
                guard program.end > now else { continue }
                let title = intern(program.title)
                let subtitle = program.subtitle.map(intern) ?? -1
                let index = builtPostings.count
                builtPostings.append(Posting(titleText: Int32(title), subtitleText: Int32(subtitle),
                                             channel: Int32(slot), start: program.start.timeIntervalSince1970,
                                             end: program.end.timeIntervalSince1970, id: program.id))
                postingLists[title].append(index)
                if subtitle >= 0 { postingLists[subtitle].append(index) }
            }
        }
        texts = builtTexts
        postings = builtPostings
        channelSlots = builtChannels
        textPostings = postingLists
        programCount = builtPostings.count
        uniqueTextCount = builtTexts.count
        estimatedStorageBytes = builtTexts.reduce(MemoryLayout<Text>.stride * builtTexts.count) {
            $0 + $1.original.utf8.count + $1.folded.utf8.count
        } + builtPostings.count * MemoryLayout<Posting>.stride
            + builtChannels.reduce(MemoryLayout<Channel>.stride * builtChannels.count) {
                $0 + $1.key.utf8.count + $1.id.utf8.count + $1.name.utf8.count
            }
    }

    static func build(identity: Identity, guide: EPGIndex, channels: [LiveTVChannel], now: Date,
                      locale: Locale = .current) async -> Self? {
        let worker: Task<Self?, Never> = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            return Self(identity: identity, guide: guide, channels: channels, now: now, locale: locale)
        }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: {
            worker.cancel()
        })
    }

    func search(query: String, now: Date, limit: Int = defaultResultLimit) async -> [Match]? {
        let worker = Task.detached(priority: .userInitiated) { self.searchSync(query: query, now: now, limit: limit) }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: {
            worker.cancel()
        })
    }

    private func searchSync(query: String, now: Date, limit: Int) -> [Match]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else { return [] }
        let asciiQuery = trimmed.unicodeScalars.allSatisfy { $0.value < 128 }
        let foldedQuery = Self.fold(trimmed, locale: locale)
        let language = locale.identifier.split { $0 == "_" || $0 == "-" }.first?.lowercased()
        let fastAllowed = asciiQuery && language != "tr" && language != "az"
        var qualities: [Int: MatchQuality] = [:]
        for (textIndex, text) in texts.enumerated() {
            if textIndex.isMultiple(of: 256), Task.isCancelled { return nil }
            let matched: Bool
            let qualityForTitle: MatchQuality?
            if fastAllowed && text.isASCII {
                guard text.folded.contains(foldedQuery) else { continue }
                qualityForTitle = Self.titleQuality(text.folded, query: foldedQuery)
                matched = true
            } else {
                guard text.original.localizedStandardContains(trimmed) else { continue }
                qualityForTitle = Self.titleQualitySlow(text.original, query: trimmed, locale: locale)
                matched = true
            }
            guard matched else { continue }
            for (offset, postingIndex) in textPostings[textIndex].enumerated() {
                if offset.isMultiple(of: 256), Task.isCancelled { return nil }
                let posting = postings[postingIndex]
                let quality: MatchQuality = posting.titleText == Int32(textIndex)
                    ? (qualityForTitle ?? .titleSubstring) : .subtitle
                if let old = qualities[postingIndex], old <= quality { continue }
                qualities[postingIndex] = quality
            }
        }
        var matches: [Match] = []
        matches.reserveCapacity(qualities.count)
        for (offset, item) in qualities.enumerated() {
            if offset.isMultiple(of: 256), Task.isCancelled { return nil }
            let posting = postings[item.key]
            guard posting.end > now.timeIntervalSince1970 else { continue }
            let channel = channelSlots[Int(posting.channel)]
            matches.append(Match(programID: posting.id, channelKey: channel.key, channelID: channel.id,
                                 channelName: channel.name, channelOrdinal: channel.ordinal,
                                 title: texts[Int(posting.titleText)].original,
                                 subtitle: posting.subtitleText >= 0 ? texts[Int(posting.subtitleText)].original : nil,
                                 start: Date(timeIntervalSince1970: posting.start),
                                 end: Date(timeIntervalSince1970: posting.end), isLive: posting.start <= now.timeIntervalSince1970,
                                 quality: item.value))
        }
        matches.sort {
            if $0.isLive != $1.isLive { return $0.isLive }
            if $0.isLive {
                return ($0.quality, $0.channelOrdinal, $0.start, $0.programID)
                    < ($1.quality, $1.channelOrdinal, $1.start, $1.programID)
            }
            return ($0.start, $0.quality, $0.channelOrdinal, $0.programID)
                < ($1.start, $1.quality, $1.channelOrdinal, $1.programID)
        }
        return Array(matches.prefix(max(0, limit)))
    }

    private static func fold(_ text: String, locale: Locale) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }
    private static func isWord(_ character: Character) -> Bool {
        character.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) })
    }
    private static func titleQuality(_ text: String, query: String) -> MatchQuality {
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: query, range: start..<text.endIndex) {
            if range.lowerBound == text.startIndex { return .titlePrefix }
            if text[..<range.lowerBound].last.map(isWord) != true { return .titleWordPrefix }
            start = range.upperBound
        }
        return .titleSubstring
    }
    private static func titleQualitySlow(_ text: String, query: String, locale: Locale) -> MatchQuality? {
        var start = text.startIndex
        var foundWord = false
        while start < text.endIndex, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                                              range: start..<text.endIndex, locale: locale) {
            if range.lowerBound == text.startIndex { return .titlePrefix }
            if text[..<range.lowerBound].last.map(isWord) != true { foundWord = true }
            start = range.upperBound
        }
        return foundWord ? .titleWordPrefix : .titleSubstring
    }
}

actor EPGProgramSearchIndexStore {
    static let shared = EPGProgramSearchIndexStore()
    struct Input: Sendable {
        let identity: EPGProgramSearchIndex.Identity
        let guide: EPGIndex?
        let channels: [LiveTVChannel]
    }
    enum Outcome: Equatable, Sendable {
        case results([EPGProgramSearchIndex.Match]), queryTooShort, noGuide, unsupportedStorage
    }
    private var identity: EPGProgramSearchIndex.Identity?
    private var index: EPGProgramSearchIndex?
    private var catalogGeneration = 0
    private var queryGeneration = 0
    private var buildWorker: Task<EPGProgramSearchIndex?, Never>?
    private var searchWorker: Task<[EPGProgramSearchIndex.Match]?, Never>?
    #if DEBUG
    private var buildCount = 0
    var buildCountForTesting: Int { buildCount }
    #endif
    var currentIdentity: EPGProgramSearchIndex.Identity? { identity }

    func search(query: String, input: Input, now: Date = .now,
                limit: Int = EPGProgramSearchIndex.defaultResultLimit) async -> Outcome? {
        queryGeneration += 1
        let generation = queryGeneration
        searchWorker?.cancel(); searchWorker = nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= EPGProgramSearchIndex.minimumQueryLength else { return .queryTooShort }
        let expected = input.identity
        if identity != expected {
            catalogGeneration += 1
            buildWorker?.cancel(); buildWorker = nil
            index = nil; identity = expected
        }
        let catalog = catalogGeneration
        guard let guide = input.guide else { return .noGuide }
        if guide.isSQLiteBacked { return .unsupportedStorage }
        let source: EPGProgramSearchIndex
        if let index, index.identity == expected { source = index }
        else {
            if buildWorker == nil {
                #if DEBUG
                buildCount += 1
                #endif
                let worker = Task { await EPGProgramSearchIndex.build(identity: expected, guide: guide, channels: input.channels, now: now) }
                buildWorker = worker
            }
            guard let worker = buildWorker,
                  let built = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: {
                      worker.cancel()
                  }), !Task.isCancelled,
                  catalog == catalogGeneration, identity == expected, built.identity == expected else { return nil }
            index = built; buildWorker = nil; source = built
        }
        let worker = Task { await source.search(query: query, now: now, limit: limit) }
        searchWorker = worker
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: {
            worker.cancel()
        })
        guard !Task.isCancelled, generation == queryGeneration, catalog == catalogGeneration,
              identity == expected, index?.identity == expected, let result else { return nil }
        searchWorker = nil
        return .results(result)
    }

    func invalidate(providerID: UUID? = nil) {
        guard providerID == nil || identity?.providerID == providerID else { return }
        catalogGeneration += 1; queryGeneration += 1
        buildWorker?.cancel(); searchWorker?.cancel()
        buildWorker = nil; searchWorker = nil; identity = nil; index = nil
    }
}
