import Foundation

public struct DailyJournalPlaceVisit: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let shortLabel: String
    public let startTimestamp: Double
    public let endTimestamp: Double?
    public let latitude: Double?
    public let longitude: Double?
    public let isLiveLocation: Bool

    public init(
        id: String,
        name: String,
        shortLabel: String? = nil,
        startTimestamp: Double,
        endTimestamp: Double? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        isLiveLocation: Bool = true
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.name = trimmedName
        self.shortLabel = shortLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? shortLabel!.trimmingCharacters(in: .whitespacesAndNewlines)
            : Self.shorten(trimmedName)
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.latitude = latitude
        self.longitude = longitude
        self.isLiveLocation = isLiveLocation
    }

    public static func shorten(_ raw: String) -> String {
        let parts = raw
            .components(separatedBy: CharacterSet(charactersIn: " ·,，/"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "" }
        if let last = parts.last, parts.count >= 2 {
            let prev = parts[parts.count - 2]
                .replacingOccurrences(of: "市", with: "")
                .replacingOccurrences(of: "区", with: "")
                .replacingOccurrences(of: "县", with: "")
            if last.count <= 6, !prev.isEmpty, prev != last, (prev.count + last.count + 3) <= 11 {
                return "\(prev) · \(last)"
            }
            return String(last.prefix(10))
        }

        var single = parts[0]
        for pattern in [
            #"^中国"#,
            #"^[\u4e00-\u9fa5]{2,6}(?:省|自治区|特别行政区)"#,
            #"^[\u4e00-\u9fa5]{2,5}市"#
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let ns = single as NSString
                let range = NSRange(location: 0, length: ns.length)
                single = regex.stringByReplacingMatches(in: single, range: range, withTemplate: "")
            }
        }
        if let districtRegex = try? NSRegularExpression(pattern: #"^([\u4e00-\u9fa5]{1,4})(?:区|县)(.+)$"#),
           let match = districtRegex.firstMatch(in: single, range: NSRange(location: 0, length: (single as NSString).length)),
           match.numberOfRanges == 3 {
            let ns = single as NSString
            let district = ns.substring(with: match.range(at: 1))
            let landmark = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !landmark.isEmpty {
                if landmark.count <= 6, (district.count + landmark.count + 3) <= 11 {
                    return "\(district) · \(landmark)"
                }
                return String(landmark.prefix(10))
            }
        }
        return String(single.prefix(10))
    }
}

public enum DailyJournalIntervalOption: Int, Codable, CaseIterable, Identifiable, Sendable {
    case twoHours = 2
    case threeHours = 3
    case fourHours = 4
    case sixHours = 6
    case fullDay = 24

    public static let defaultOption: Self = .threeHours
    public static let defaultsKey = "momo.dailyJournal.intervalHours"

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .twoHours: String(localized: "每 2 小时", bundle: AppLanguage.resourceBundle)
        case .threeHours: String(localized: "每 3 小时", bundle: AppLanguage.resourceBundle)
        case .fourHours: String(localized: "每 4 小时", bundle: AppLanguage.resourceBundle)
        case .sixHours: String(localized: "每 6 小时", bundle: AppLanguage.resourceBundle)
        case .fullDay: String(localized: "全天单幅", bundle: AppLanguage.resourceBundle)
        }
    }

    public var shortTitle: String {
        switch self {
        case .twoHours: "2h"
        case .threeHours: "3h"
        case .fourHours: "4h"
        case .sixHours: "6h"
        case .fullDay: String(localized: "全天", bundle: AppLanguage.resourceBundle)
        }
    }

    public static func current(defaults: UserDefaults? = .standard) -> Self {
        guard let raw = defaults?.object(forKey: defaultsKey) as? Int,
              let option = Self(rawValue: raw) else {
            return defaultOption
        }
        return option
    }

    public static func setCurrent(_ value: Self, defaults: UserDefaults? = .standard) {
        defaults?.set(value.rawValue, forKey: defaultsKey)
    }
}

public struct DailyJournalSegment: Codable, Equatable, Sendable {
    public let hour: Int
    public let duration: Double
    public let text: String
    public let isSummary: Bool
    public let timestamp: Double?

    public init(
        hour: Int,
        duration: Double,
        text: String,
        isSummary: Bool = false,
        timestamp: Double? = nil
    ) {
        self.hour = ((hour % 24) + 24) % 24
        self.duration = max(0, duration)
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isSummary = isSummary
        self.timestamp = timestamp
    }
}

public struct DailyJournalInput: Equatable, Sendable {
    public let dayKey: String
    public let dateLabel: String
    public let dayStartHour: Int
    public let placeLabel: String?
    public let timeSlotLabel: String?
    public let segments: [DailyJournalSegment]

    public init(
        dayKey: String,
        dateLabel: String,
        dayStartHour: Int = DayStartBoundary.defaultHour,
        placeLabel: String? = nil,
        timeSlotLabel: String? = nil,
        segments: [DailyJournalSegment]
    ) {
        self.dayKey = dayKey
        self.dateLabel = dateLabel
        self.dayStartHour = DayStartBoundary.clamp(dayStartHour)
        let trimmedPlace = placeLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.placeLabel = (trimmedPlace?.isEmpty == false) ? trimmedPlace : nil
        let trimmedSlot = timeSlotLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timeSlotLabel = (trimmedSlot?.isEmpty == false) ? trimmedSlot : nil
        self.segments = segments.filter { !$0.text.isEmpty || $0.duration > 0 }
    }

    public var hasReadableContent: Bool {
        segments.contains { !$0.text.isEmpty }
    }

    public var totalDuration: Double {
        segments.reduce(0) { $0 + $1.duration }
    }

    public var fingerprint: String {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
            hash ^= 0xff
            hash &*= 0x100000001b3
        }
        mix(dayKey)
        mix(String(dayStartHour))
        mix(placeLabel ?? "")
        mix(timeSlotLabel ?? "")
        for seg in segments {
            mix(String(seg.hour))
            mix(seg.isSummary ? "S" : "T")
            mix(String(seg.text.prefix(240)))
        }
        return String(format: "%016llx", hash)
    }

    public var deterministicSeed: UInt64 {
        UInt64(fingerprint, radix: 16) ?? 0x9e3779b97f4a7c15
    }

    /// Normalized 24-hour voice activity bins ordered starting at `dayStartHour` (e.g. 08:00 -> 07:00).
    public var wakingHourBins: [Double] {
        var buckets = [Double](repeating: 0, count: 24)
        for seg in segments {
            let index = (seg.hour - dayStartHour + 24) % 24
            let weight = max(25.0, seg.duration > 0 ? seg.duration : Double(min(seg.text.count, 300)) * 0.8)
            buckets[index] += weight
        }
        let peak = buckets.max() ?? 0
        guard peak > 0 else { return buckets }
        return buckets.map { min(1.0, max(0.0, $0 / peak)) }
    }
}

public struct DailyJournalChapter: Identifiable, Equatable, Sendable {
    public let id: String
    public let slotIndex: Int
    public let startHour: Int
    public let endHour: Int
    public let timeRangeLabel: String
    public let place: DailyJournalPlaceVisit?
    public let chapterInput: DailyJournalInput

    public init(
        id: String,
        slotIndex: Int,
        startHour: Int,
        endHour: Int,
        timeRangeLabel: String,
        place: DailyJournalPlaceVisit?,
        chapterInput: DailyJournalInput
    ) {
        self.id = id
        self.slotIndex = slotIndex
        self.startHour = startHour
        self.endHour = endHour
        self.timeRangeLabel = timeRangeLabel
        self.place = place
        self.chapterInput = chapterInput
    }
}

public enum DailyJournalChapterBuilder {
    public static func buildChapters(
        from dayInput: DailyJournalInput,
        interval: DailyJournalIntervalOption,
        visits: [DailyJournalPlaceVisit] = []
    ) -> [DailyJournalChapter] {
        guard dayInput.hasReadableContent else { return [] }

        if interval == .fullDay {
            let matchedPlace = resolvePlace(for: dayInput.segments, visits: visits)
            let enriched = DailyJournalInput(
                dayKey: dayInput.dayKey,
                dateLabel: dayInput.dateLabel,
                dayStartHour: dayInput.dayStartHour,
                placeLabel: matchedPlace?.shortLabel ?? dayInput.placeLabel,
                timeSlotLabel: nil,
                segments: dayInput.segments
            )
            return [
                DailyJournalChapter(
                    id: "\(dayInput.dayKey)#full",
                    slotIndex: 0,
                    startHour: dayInput.dayStartHour,
                    endHour: dayInput.dayStartHour,
                    timeRangeLabel: String(localized: "全天手账", bundle: AppLanguage.resourceBundle),
                    place: matchedPlace,
                    chapterInput: enriched
                )
            ]
        }

        let step = max(1, interval.rawValue)
        let bucketCount = (24 + step - 1) / step
        var grouped: [Int: [DailyJournalSegment]] = [:]
        for seg in dayInput.segments {
            let offset = (seg.hour - dayInput.dayStartHour + 24) % 24
            let slot = min(bucketCount - 1, offset / step)
            grouped[slot, default: []].append(seg)
        }

        var chapters: [DailyJournalChapter] = []
        for slot in grouped.keys.sorted() {
            guard let slotSegments = grouped[slot], slotSegments.contains(where: { !$0.text.isEmpty }) else {
                continue
            }
            let startOffset = slot * step
            let endOffset = min(24, (slot + 1) * step)
            let startHour = (dayInput.dayStartHour + startOffset) % 24
            let endHour = (dayInput.dayStartHour + endOffset) % 24
            let rangeLabel = "\(String(format: "%02d:00", startHour))–\(String(format: "%02d:00", endHour))"
            let matchedPlace = resolvePlace(for: slotSegments, visits: visits)
            let chapterKey = "\(dayInput.dayKey)-h\(step)-s\(slot)"
            let chapterInput = DailyJournalInput(
                dayKey: chapterKey,
                dateLabel: "\(dayInput.dateLabel) · \(rangeLabel)",
                dayStartHour: dayInput.dayStartHour,
                placeLabel: matchedPlace?.shortLabel,
                timeSlotLabel: rangeLabel,
                segments: slotSegments
            )
            chapters.append(
                DailyJournalChapter(
                    id: chapterKey,
                    slotIndex: slot,
                    startHour: startHour,
                    endHour: endHour,
                    timeRangeLabel: rangeLabel,
                    place: matchedPlace,
                    chapterInput: chapterInput
                )
            )
        }
        return chapters
    }

    public static func resolvePlace(
        for segments: [DailyJournalSegment],
        visits: [DailyJournalPlaceVisit]
    ) -> DailyJournalPlaceVisit? {
        let timestamps = segments.compactMap(\.timestamp)
        if !timestamps.isEmpty, !visits.isEmpty {
            let segStart = (timestamps.min() ?? 0) - 2_700
            let segEnd = (timestamps.max() ?? 0) + 2_700
            let segMid = ((timestamps.min() ?? 0) + (timestamps.max() ?? 0)) * 0.5
            let overlapping = visits.filter { visit in
                guard !visit.shortLabel.isEmpty else { return false }
                let vStart = visit.startTimestamp
                let vEnd = visit.endTimestamp ?? (vStart + 5_400)
                return vStart <= segEnd && vEnd >= segStart
            }
            if let best = overlapping.min(by: { lhs, rhs in
                let lMid = (lhs.startTimestamp + (lhs.endTimestamp ?? lhs.startTimestamp)) * 0.5
                let rMid = (rhs.startTimestamp + (rhs.endTimestamp ?? rhs.startTimestamp)) * 0.5
                return abs(lMid - segMid) < abs(rMid - segMid)
            }) {
                return best
            }
        }
        // Fallback: infer concrete place mentioned in the transcript text itself
        let combined = segments.map(\.text).joined(separator: " ")
        if let inferred = DailyJournalConceptExtractor.inferPlaceFromText(combined) {
            return DailyJournalPlaceVisit(
                id: "inferred-\(inferred)",
                name: inferred,
                shortLabel: inferred,
                startTimestamp: timestamps.first ?? 0,
                isLiveLocation: false
            )
        }
        return nil
    }
}

public enum DailyJournalPalette: String, Codable, CaseIterable, Sendable {
    case morningAmber
    case studioSage
    case breezeSky
    case twilightApricot
    case lampNight
}

public enum DailyJournalMotif: String, Codable, CaseIterable, Sendable {
    case coffee
    case laptop
    case notebook
    case sparkles
    case leaf
    case calendar
    case moon
    case sun
}

public enum DailyJournalStyleChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case chiikawa
    case illustration
    case sketch
    case animation

    public static let defaultStyle: Self = .chiikawa

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chiikawa: String(localized: "吉伊软萌", bundle: AppLanguage.resourceBundle)
        case .illustration: String(localized: "水彩绘本", bundle: AppLanguage.resourceBundle)
        case .sketch: String(localized: "素描手稿", bundle: AppLanguage.resourceBundle)
        case .animation: String(localized: "灵动立体", bundle: AppLanguage.resourceBundle)
        }
    }
}

public enum DailyJournalArtworkSource: String, Codable, Equatable, Sendable {
    case appleImageCreator
    case appleImagePlaygroundSheet
    case proceduralHandDrawn
}

public struct DailyJournalBrief: Codable, Equatable, Sendable {
    public var headline: String
    public var note: String
    public var tags: [String]
    public var sceneConcepts: [String]
    public var safeExtractionSummary: String
    public var palette: DailyJournalPalette
    public var motifs: [DailyJournalMotif]
    public var placeLabel: String?
    public var distilledByOnDeviceLLM: Bool

    public init(
        headline: String,
        note: String,
        tags: [String],
        sceneConcepts: [String],
        safeExtractionSummary: String,
        palette: DailyJournalPalette,
        motifs: [DailyJournalMotif],
        placeLabel: String? = nil,
        distilledByOnDeviceLLM: Bool = false
    ) {
        self.headline = headline
        self.note = note
        self.tags = tags
        self.sceneConcepts = sceneConcepts
        self.safeExtractionSummary = safeExtractionSummary
        self.palette = palette
        self.motifs = motifs
        self.placeLabel = placeLabel
        self.distilledByOnDeviceLLM = distilledByOnDeviceLLM
    }
}

public struct DailyJournalStoredCover: Codable, Equatable, Sendable {
    public var dayKey: String
    public var fingerprint: String
    public var style: DailyJournalStyleChoice
    public var source: DailyJournalArtworkSource
    public var brief: DailyJournalBrief
    public var variationIndex: Int
    public var updatedAt: Date

    public init(
        dayKey: String,
        fingerprint: String,
        style: DailyJournalStyleChoice,
        source: DailyJournalArtworkSource,
        brief: DailyJournalBrief,
        variationIndex: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.dayKey = dayKey
        self.fingerprint = fingerprint
        self.style = style
        self.source = source
        self.brief = brief
        self.variationIndex = variationIndex
        self.updatedAt = updatedAt
    }

    public func isFresh(for input: DailyJournalInput) -> Bool {
        if source == .appleImagePlaygroundSheet { return true }
        return fingerprint == input.fingerprint
    }
}

public enum DailyJournalConceptExtractor {
    private struct ThemeRule {
        let tag: String
        let motif: DailyJournalMotif
        let sceneConcept: String
        let chiikawaConcept: String
        let keywords: [String]
    }

    private static let rules: [ThemeRule] = [
        ThemeRule(
            tag: "代码与架构",
            motif: .laptop,
            sceneConcept: "warm wooden desk with glowing laptop, clean blueprint sketches, and small desk plant",
            chiikawaConcept: "adorable tiny chubby white marshmallow hamster-bear mascot tapping a miniature pastel laptop on a low wooden table, cute sparkle and effort droplet",
            keywords: [
                "代码", "架构", "接口", "模型", "测试", "部署", "数据库", "算法", "网关", "编译",
                "github", "action", "benchmark", "agent", "api", "bug", "pr", "commit", "swift", "python"
            ]
        ),
        ThemeRule(
            tag: "灵感与产品",
            motif: .sparkles,
            sceneConcept: "cozy creative studio table with fountain pen, colorful memo cards, and warm brass lamp",
            chiikawaConcept: "cute tiny round white mochi creature pal holding a big pastel crayon beside colorful doodle cards and floating four-point stars",
            keywords: [
                "产品", "设计", "灵感", "脑暴", "体验", "交互", "原型", "创业", "功能", "定位",
                "插画", "手账", "页面", "视觉", "创意", "design", "product", "idea"
            ]
        ),
        ThemeRule(
            tag: "方案与推进",
            motif: .notebook,
            sceneConcept: "stitched cream paper journal open beside brass paperclip and neat handwritten notes",
            chiikawaConcept: "two tiny round pastel kawaii mascot pals reading an oversized open stitched cream notebook with cute star stickers",
            keywords: [
                "方案", "评审", "合同", "报价", "项目", "采购", "调研", "总结", "复盘", "对齐",
                "客户", "商务", "推进", "报告", "文档", "纪要", "评测"
            ]
        ),
        ThemeRule(
            tag: "日程与待办",
            motif: .calendar,
            sceneConcept: "minimalist desk calendar card with warm washi tape, wooden pencil, and tidy checklist",
            chiikawaConcept: "tiny round kawaii marshmallow creature checking off a cute pastel checklist board with little ribbon and clover",
            keywords: [
                "日程", "待办", "安排", "周会", "会议", "排期", "明天", "下周", "周五", "提醒",
                "todo", "截止", "计划", "时间表"
            ]
        ),
        ThemeRule(
            tag: "咖啡与闲叙",
            motif: .coffee,
            sceneConcept: "steaming ceramic pour-over coffee cup and warm pastry on soft linen tablecloth",
            chiikawaConcept: "happy tiny chubby white mochi creature pal with rosy pink cheeks holding a warm steaming cafe mug and sweet pudding with musical notes",
            keywords: [
                "咖啡", "拿铁", "美式", "奶茶", "喝茶", "午饭", "晚饭", "吃饭", "餐厅", "汉堡",
                "拉面", "火锅", "周末", "休息", "下午茶", "烘焙", "聊天"
            ]
        ),
        ThemeRule(
            tag: "步履与风物",
            motif: .leaf,
            sceneConcept: "sunlit garden path with gentle autumn leaves, canvas tote bag, and dappled light",
            chiikawaConcept: "tiny chubby round kawaii mascot pal wearing a miniature pink crossbody pouch strolling along a clover path beside a wooden signpost",
            keywords: [
                "散步", "徒步", "公园", "户外", "天气", "出差", "旅行", "航班", "高铁", "北京",
                "上海", "杭州", "深圳", "骑行", "跑步", "运动", "阳光"
            ]
        ),
    ]

    private static let knownScenePlaces: [String] = [
        "三里屯", "望京", "中关村", "国贸", "西二旗", "后厂村", "五道口", "陆家嘴", "静安寺", "徐家汇",
        "西溪", "未来科技城", "西湖", "南山", "科技园", "前海", "珠江新城", "琶洲",
        "星巴克", "Manner", "瑞幸", "咖啡馆", "茶室", "会议室", "办公室", "书房", "工位",
        "公园", "机场", "高铁站", "高铁上", "地铁", "家里"
    ]

    private static let personWordRegex = try! NSRegularExpression(
        pattern: #"(?:\b(?:person|people|man|woman|men|women|boy|girl|human|portrait|selfie|face|faces|crowd|colleague|colleagues|businessman|businesswoman)\b|人像|人物|肖像|人脸|男人|女人|男孩|女孩|同事们)"#,
        options: [.caseInsensitive]
    )

    private static let stopPhrases: [String] = [
        "本次讨论主要", "录音主要讨论", "主要讨论了", "这段录音", "主要围绕", "重点讨论",
        "第一段", "第二段", "第三段", "测试录音", "用于验证",
        "然后", "就是", "这个", "那个", "我们", "你们", "他们", "可以", "觉得", "因为", "所以"
    ]

    private static let speakerPrefixRegex = try! NSRegularExpression(pattern: #"^\[[^\]]{1,24}\]\s*"#, options: [.anchorsMatchLines])
    private static let termRegex = try! NSRegularExpression(
        pattern: #"(?:[A-Za-z][A-Za-z0-9.+-]{2,18}(?:\s+[A-Za-z][A-Za-z0-9.+-]{2,14})?)|(?:(?:(?![的了在把和与及对向从被让跟是就都要去到第])[\u4e00-\u9fa5]){2,5}(?:系统|方案|评测|架构|模型|设计|计划|接口|工具|市场|项目|合同|纪要|手账|插画|播放|时间线))"#,
        options: []
    )

    public static func inferPlaceFromText(_ text: String) -> String? {
        for place in knownScenePlaces {
            if text.localizedCaseInsensitiveContains(place) {
                return place
            }
        }
        return nil
    }

    public static func sanitizeSceneConcepts(
        _ rawConcepts: [String],
        fallbackPalette: DailyJournalPalette,
        style: DailyJournalStyleChoice = .chiikawa
    ) -> [String] {
        var cleaned: [String] = []
        for item in rawConcepts {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3 else { continue }
            let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if personWordRegex.firstMatch(in: trimmed, options: [], range: nsRange) != nil { continue }
            if !cleaned.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                cleaned.append(String(trimmed.prefix(150)))
            }
            if cleaned.count >= 4 { break }
        }
        if cleaned.count < 2 {
            let fallback = style == .chiikawa
                ? chiikawaAtmosphereConcepts(for: fallbackPalette)
                : atmosphereConcepts(for: fallbackPalette)
            cleaned.append(contentsOf: fallback.prefix(3 - cleaned.count))
        }
        return Array(cleaned.prefix(4))
    }

    public static func extract(
        from input: DailyJournalInput,
        style: DailyJournalStyleChoice = .chiikawa
    ) -> DailyJournalBrief {
        let cleanTexts = input.segments.map { cleanSegmentText($0.text) }.filter { !$0.isEmpty }
        let joined = cleanTexts.joined(separator: "\n")
        let lowerJoined = joined.lowercased()
        let resolvedPlace = input.placeLabel ?? inferPlaceFromText(joined)

        let palette = dominantPalette(for: input.segments)
        let timeMotif: DailyJournalMotif = switch palette {
        case .morningAmber: .sun
        case .lampNight, .twilightApricot: .moon
        case .studioSage, .breezeSky: .sparkles
        }

        var matchedRules: [(rule: ThemeRule, score: Int)] = []
        for rule in rules {
            let score = rule.keywords.reduce(0) { acc, kw in
                acc + (lowerJoined.contains(kw.lowercased()) ? 1 : 0)
            }
            if score > 0 {
                matchedRules.append((rule, score))
            }
        }
        matchedRules.sort { $0.score > $1.score }

        var motifs = matchedRules.prefix(2).map(\.rule.motif)
        if !motifs.contains(timeMotif) { motifs.append(timeMotif) }
        if motifs.isEmpty { motifs = [.notebook, .coffee, timeMotif] }

        var tags: [String] = []
        if let resolvedPlace, !resolvedPlace.isEmpty {
            tags.append("📍\(resolvedPlace)")
        }
        for term in extractSalientTerms(from: cleanTexts) where tags.count < 4 {
            if !tags.contains(term) { tags.append(term) }
        }
        for matched in matchedRules where tags.count < 4 {
            if !tags.contains(matched.rule.tag) {
                tags.append(matched.rule.tag)
            }
        }
        if tags.isEmpty {
            tags = [timePeriodLabel(for: palette), "吉伊风日常手记"]
        }
        tags = Array(tags.prefix(4))

        var rawConcepts: [String] = []
        if style == .chiikawa {
            rawConcepts.append(contentsOf: matchedRules.prefix(2).map(\.rule.chiikawaConcept))
            rawConcepts.append(contentsOf: chiikawaAtmosphereConcepts(for: palette))
        } else {
            rawConcepts.append(contentsOf: matchedRules.prefix(2).map(\.rule.sceneConcept))
            rawConcepts.append(contentsOf: atmosphereConcepts(for: palette))
        }
        if let resolvedPlace, !resolvedPlace.isEmpty {
            rawConcepts.append("cute wooden signpost beside cozy miniature nook inspired by \(resolvedPlace)")
        }
        let concepts = sanitizeSceneConcepts(rawConcepts, fallbackPalette: palette, style: style)

        let headline = buildHeadline(
            tags: tags,
            matchedRules: matchedRules.map(\.rule.tag),
            palette: palette,
            placeLabel: resolvedPlace
        )
        let note = buildWarmNote(
            input: input,
            cleanTexts: cleanTexts,
            tags: tags,
            palette: palette,
            placeLabel: resolvedPlace
        )
        let safeSummary = concepts.joined(separator: ", ")

        return DailyJournalBrief(
            headline: headline,
            note: note,
            tags: tags,
            sceneConcepts: concepts,
            safeExtractionSummary: safeSummary,
            palette: palette,
            motifs: Array(motifs.prefix(3)),
            placeLabel: resolvedPlace,
            distilledByOnDeviceLLM: false
        )
    }

    private static func cleanSegmentText(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        var text = speakerPrefixRegex.stringByReplacingMatches(in: raw, options: [], range: range, withTemplate: "")
        text = text.replacingOccurrences(of: "\n", with: " ")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractSalientTerms(from texts: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var ordered: [String] = []
        for text in texts {
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in termRegex.matches(in: text, options: [], range: nsRange) {
                guard let r = Range(match.range, in: text) else { continue }
                let candidate = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard candidate.count >= 2, candidate.count <= 16 else { continue }
                if stopPhrases.contains(where: { candidate.contains($0) }) { continue }
                if counts[candidate] == nil { ordered.append(candidate) }
                counts[candidate, default: 0] += 1
            }
        }
        return ordered
            .sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
            .prefix(3)
            .map { $0 }
    }

    private static func dominantPalette(for segments: [DailyJournalSegment]) -> DailyJournalPalette {
        guard !segments.isEmpty else { return .morningAmber }
        var morning = 0.0, afternoon = 0.0, evening = 0.0, lateNight = 0.0
        for seg in segments {
            let w = max(1.0, seg.duration > 0 ? seg.duration / 60.0 : 2.0)
            switch seg.hour {
            case 6...11: morning += w
            case 12...16: afternoon += w
            case 17...20: evening += w
            default: lateNight += w
            }
        }
        let maxBucket = max(morning, afternoon, evening, lateNight)
        if maxBucket == lateNight && lateNight > 0 { return .lampNight }
        if maxBucket == evening && evening > 0 { return .twilightApricot }
        if maxBucket == afternoon && afternoon > 0 {
            return segments.count >= 3 ? .studioSage : .breezeSky
        }
        return .morningAmber
    }

    private static func timePeriodLabel(for palette: DailyJournalPalette) -> String {
        switch palette {
        case .morningAmber: "晨间拾音"
        case .studioSage: "午后专注"
        case .breezeSky: "晴昼随记"
        case .twilightApricot: "暮色复盘"
        case .lampNight: "夜灯长谈"
        }
    }

    private static func chiikawaAtmosphereConcepts(for palette: DailyJournalPalette) -> [String] {
        switch palette {
        case .morningAmber:
            return [
                "soft buttercream and sakura pink watercolor wash, adorable tiny chubby white marshmallow creature pal with rosy pink blush cheeks and gentle brown ink linework",
                "kawaii Japanese picture-book doodle illustration with warm morning sunshine, tiny clovers, and cozy breakfast cup"
            ]
        case .studioSage:
            return [
                "soft mint cream pastel doodle illustration, cute tiny round mochi mascot pals with dot eyes and rosy cheeks beside miniature desk and potted sprout",
                "gentle hand-drawn dark brown ink outlines on warm sketchbook paper with tiny floating sparkles"
            ]
        case .breezeSky:
            return [
                "airy pastel sky blue and cream kawaii doodle illustration, chubby round marshmallow mascot pal carrying a tiny pouch on a sunny stroll",
                "soft hand-painted watercolor blobs with minimal wobbly brown ink lines and cheerful music notes"
            ]
        case .twilightApricot:
            return [
                "pastel peach apricot and lavender sunset wash, two tiny chubby kawaii mochi pals sharing warm tea beside a little lantern",
                "cozy Japanese kawaii comic panel style with rosy cheek blushes and soft cream paper texture"
            ]
        case .lampNight:
            return [
                "dreamy pastel periwinkle night sky with cute yellow crescent moon and twinkling four-point stars, tiny round marshmallow pal beside warm glowing lamp",
                "gentle kawaii bedtime storybook doodle with soft cocoa ink outlines and cozy blanket warmth"
            ]
        }
    }

    private static func atmosphereConcepts(for palette: DailyJournalPalette) -> [String] {
        switch palette {
        case .morningAmber:
            return [
                "warm morning sunlight streaming across a wooden desk with ceramic mug and open notebook",
                "cozy storybook illustration in soft amber, cream paper, and terracotta tones"
            ]
        case .studioSage:
            return [
                "calm sunlit studio table with potted eucalyptus, sketchbook, and tidy desk organizer",
                "warm hand-drawn watercolor illustration in sage green and natural wood tones"
            ]
        case .breezeSky:
            return [
                "open window with gentle breeze, linen curtain, teacup, and crisp paper journal",
                "warm editorial illustration with airy sky blue and soft cream paper texture"
            ]
        case .twilightApricot:
            return [
                "golden hour sunset glow through window onto cozy desk with warm lamp and notebook",
                "hand-painted journal illustration in warm apricot, dusty rose, and twilight indigo"
            ]
        case .lampNight:
            return [
                "warm glowing desk lamp beside open journal and teacup under a quiet starry window",
                "cozy evening storybook illustration in amber lamplight and deep ink blue"
            ]
        }
    }

    private static func buildHeadline(
        tags: [String],
        matchedRules: [String],
        palette: DailyJournalPalette,
        placeLabel: String?
    ) -> String {
        let topicCore: String
        if let firstRule = matchedRules.first {
            if matchedRules.count >= 2 {
                let firstShort = String(firstRule.prefix(2))
                let secondShort = String(matchedRules[1].suffix(2))
                topicCore = "\(firstShort)与\(secondShort)"
            } else {
                topicCore = firstRule
            }
        } else if let nonPlaceTag = tags.first(where: { !$0.hasPrefix("📍") }) {
            topicCore = String(nonPlaceTag.prefix(8))
        } else {
            topicCore = timePeriodLabel(for: palette)
        }

        if let placeLabel, !placeLabel.isEmpty {
            let landmark = placeLabel
                .components(separatedBy: "·")
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? placeLabel
            let shortPlace = String((landmark.isEmpty ? placeLabel : landmark).prefix(8))
            return "\(shortPlace) · \(topicCore)"
        }
        let moodPrefix = switch palette {
        case .morningAmber: "晨光里的"
        case .studioSage: "午后小记："
        case .breezeSky: "晴日漫游："
        case .twilightApricot: "暮色时分的"
        case .lampNight: "夜灯下的"
        }
        return "\(moodPrefix)\(topicCore)"
    }

    private static func buildWarmNote(
        input: DailyJournalInput,
        cleanTexts: [String],
        tags: [String],
        palette: DailyJournalPalette,
        placeLabel: String?
    ) -> String {
        let count = max(1, input.segments.count)
        let totalMinutes = max(1, Int((input.totalDuration / 60.0).rounded()))
        let durationPhrase = input.totalDuration >= 60 ? "聊了约 \(totalMinutes) 分钟" : "记下了 \(count) 段声音"
        let wherePrefix: String = {
            if let slot = input.timeSlotLabel, let place = placeLabel, !place.isEmpty {
                return "\(slot) 在\(place)"
            } else if let place = placeLabel, !place.isEmpty {
                return "在\(place)"
            } else if let slot = input.timeSlotLabel {
                return "\(slot) 时段"
            }
            return "这一天"
        }()

        let firstSummary = input.segments.first(where: { $0.isSummary && !$0.text.isEmpty }).map { cleanSegmentText($0.text) }
        if let firstSummary, firstSummary.count >= 8 {
            let firstClause = firstSummary
                .split(whereSeparator: { "。！？；\n".contains($0) })
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !firstClause.isEmpty {
                let concise = firstClause.count > 30 ? String(firstClause.prefix(29)) + "…" : firstClause
                return "\(wherePrefix)\(durationPhrase)，\(concise)。"
            }
        }
        let topicJoined = tags.filter { !$0.hasPrefix("📍") }.prefix(2).joined(separator: "、")
        let closing = switch palette {
        case .morningAmber: "小家伙们把一早的心意暖暖收进了手账 ♪"
        case .studioSage: "一步一脚印把重要的事推进得稳稳当当 ✦"
        case .breezeSky: "零散的日常拼起来，也是软乎乎的好时光 ♪"
        case .twilightApricot: "傍晚回看时，今天也好好努力过了呢 ✦"
        case .lampNight: "夜深收尾啦，把思绪轻轻叠好放进枕边手账 ♪"
        }
        if !topicJoined.isEmpty {
            return "\(wherePrefix)围绕\(topicJoined)\(durationPhrase)，\(closing)"
        }
        return "\(wherePrefix)\(durationPhrase)，\(closing)"
    }
}

public struct DailyJournalPlaceStore: Sendable {
    public let fileURL: URL

    public init(directory: URL? = nil) {
        let baseDir: URL
        if let directory {
            baseDir = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            baseDir = base
                .appendingPathComponent("MoMoAgent", isDirectory: true)
                .appendingPathComponent("DailyJournalCovers", isDirectory: true)
        }
        self.fileURL = baseDir.appendingPathComponent("journal-places.json")
    }

    public func load(retainingDays: Int = 14, now: Double = Date().timeIntervalSince1970) -> [DailyJournalPlaceVisit] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DailyJournalPlaceVisit].self, from: data) else {
            return []
        }
        let cutoff = now - Double(max(1, retainingDays)) * 86_400
        return decoded.filter { ($0.endTimestamp ?? $0.startTimestamp) >= cutoff }
    }

    public func upsert(_ visit: DailyJournalPlaceVisit, retainingDays: Int = 14) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var current = load(retainingDays: retainingDays)
        current.removeAll { $0.id == visit.id }
        current.append(visit)
        current.sort { $0.startTimestamp < $1.startTimestamp }
        let data = try JSONEncoder().encode(current)
        try data.write(to: fileURL, options: .atomic)
    }
}

public struct DailyJournalCoverStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base
                .appendingPathComponent("MoMoAgent", isDirectory: true)
                .appendingPathComponent("DailyJournalCovers", isDirectory: true)
        }
    }

    private func sanitizedStem(dayKey: String, style: DailyJournalStyleChoice) -> String {
        let safeDay = dayKey.replacingOccurrences(
            of: #"[^A-Za-z0-9_-]"#,
            with: "_",
            options: .regularExpression
        )
        return "\(safeDay)-\(style.rawValue)"
    }

    public func imageURL(dayKey: String, style: DailyJournalStyleChoice) -> URL {
        directory.appendingPathComponent(sanitizedStem(dayKey: dayKey, style: style) + ".png")
    }

    public func metadataURL(dayKey: String, style: DailyJournalStyleChoice) -> URL {
        directory.appendingPathComponent(sanitizedStem(dayKey: dayKey, style: style) + ".json")
    }

    public func load(dayKey: String, style: DailyJournalStyleChoice) -> (metadata: DailyJournalStoredCover, imageData: Data?)? {
        let metaURL = metadataURL(dayKey: dayKey, style: style)
        guard let metaData = try? Data(contentsOf: metaURL),
              let decoded = try? JSONDecoder().decode(DailyJournalStoredCover.self, from: metaData) else {
            return nil
        }
        let imgURL = imageURL(dayKey: dayKey, style: style)
        let imgData = try? Data(contentsOf: imgURL)
        if decoded.source != .proceduralHandDrawn && (imgData == nil || imgData?.isEmpty == true) {
            return nil
        }
        return (decoded, imgData)
    }

    public func save(metadata: DailyJournalStoredCover, pngData: Data?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imgURL = imageURL(dayKey: metadata.dayKey, style: metadata.style)
        if let pngData, !pngData.isEmpty {
            try pngData.write(to: imgURL, options: .atomic)
        } else if metadata.source == .proceduralHandDrawn {
            try? FileManager.default.removeItem(at: imgURL)
        }
        let encoded = try JSONEncoder().encode(metadata)
        try encoded.write(to: metadataURL(dayKey: metadata.dayKey, style: metadata.style), options: .atomic)
    }
}
