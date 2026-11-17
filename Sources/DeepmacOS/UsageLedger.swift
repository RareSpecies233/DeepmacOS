import Combine
import Foundation

/// 一次回复的用量记录
struct UsageRecord: Codable, Identifiable {
    var id = UUID()
    var t: Double
    var model: String
    /// 未命中缓存的输入 Token
    var input: Int
    /// 写入缓存的输入 Token（按未命中价计）
    var cacheWrite: Int
    /// 命中缓存的输入 Token
    var cacheRead: Int
    var output: Int
    /// 本轮服务端搜索次数
    var searches: Int

    enum CodingKeys: String, CodingKey { case t, model, input, cacheWrite, cacheRead, output, searches }

    init(t: Double, model: String, input: Int, cacheWrite: Int, cacheRead: Int, output: Int, searches: Int) {
        self.t = t
        self.model = model
        self.input = input
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
        self.searches = searches
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t)
        model = try c.decode(String.self, forKey: .model)
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        cacheWrite = try c.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        searches = try c.decodeIfPresent(Int.self, forKey: .searches) ?? 0
    }
}

/// 官方价目（USD / 1M tokens）。peak 时段翻倍，见 API 文档。
enum Pricing {
    static let searchPerRequest = 0.00075

    static func rates(model: String) -> (miss: Double, hit: Double, output: Double) {
        if model.contains("pro") {
            return (0.66, 0.022, 1.98)
        }
        return (0.15, 0.003, 0.6)
    }

    /// peak：周一至周五 UTC 01:00–04:00、06:00–10:00（北京时间 09:00–12:00、14:00–18:00）
    static func isPeak(_ date: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return false }
        cal.timeZone = utc
        let weekday = cal.component(.weekday, from: date) // 1 = 周日
        let hour = cal.component(.hour, from: date)
        guard (2 ... 6).contains(weekday) else { return false }
        return (1 ..< 4).contains(hour) || (6 ..< 10).contains(hour)
    }

    static func cost(_ record: UsageRecord) -> Double {
        let r = rates(model: record.model)
        let multiplier = isPeak(Date(timeIntervalSince1970: record.t)) ? 2.0 : 1.0
        let tokens = Double(record.input + record.cacheWrite) * r.miss
            + Double(record.cacheRead) * r.hit
            + Double(record.output) * r.output
        return (tokens / 1_000_000) * multiplier + Double(record.searches) * searchPerRequest
    }
}

/// 本地账本：JSONL 追加写，内存里保留最近若干条用于聚合。
@MainActor
final class UsageLedger: ObservableObject {
    @Published private(set) var records: [UsageRecord] = []

    private let fileURL: URL
    private let maxRecords = 20_000

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("DeepmacOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("usage.jsonl")
        records = Self.load(from: fileURL, limit: maxRecords)
    }

    private static func load(from url: URL, limit: Int) -> [UsageRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var out: [UsageRecord] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(UsageRecord.self, from: data) else { continue }
            out.append(record)
        }
        return Array(out.suffix(limit))
    }

    func append(_ record: UsageRecord) {
        records.append(record)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(record),
              let line = String(data: data, encoding: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try? Data((line + "\n").utf8).write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - 聚合

    private func calendar() -> Calendar {
        var cal = Calendar.current
        cal.firstWeekday = 2
        return cal
    }

    private func isSameDay(_ a: Date, _ b: Date) -> Bool {
        calendar().isDate(a, inSameDayAs: b)
    }

    private func isSameMonth(_ a: Date, _ b: Date) -> Bool {
        let cal = calendar()
        return cal.component(.year, from: a) == cal.component(.year, from: b)
            && cal.component(.month, from: a) == cal.component(.month, from: b)
    }

    var todayCost: Double {
        let now = Date()
        return records.filter { isSameDay(Date(timeIntervalSince1970: $0.t), now) }
            .reduce(0) { $0 + Pricing.cost($1) }
    }

    var monthCost: Double {
        let now = Date()
        return records.filter { isSameMonth(Date(timeIntervalSince1970: $0.t), now) }
            .reduce(0) { $0 + Pricing.cost($1) }
    }

    var todayTokens: (input: Int, output: Int) {
        let now = Date()
        let today = records.filter { isSameDay(Date(timeIntervalSince1970: $0.t), now) }
        return (today.reduce(0) { $0 + $1.input + $1.cacheWrite + $1.cacheRead },
                today.reduce(0) { $0 + $1.output })
    }

    var monthSearches: Int {
        let now = Date()
        return records.filter { isSameMonth(Date(timeIntervalSince1970: $0.t), now) }
            .reduce(0) { $0 + $1.searches }
    }

    /// 最近 7 天按天聚合（用于面板上的小柱状图）
    var lastSevenDays: [(day: Date, cost: Double)] {
        let cal = calendar()
        let today = cal.startOfDay(for: Date())
        return (0 ..< 7).reversed().map { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else {
                return (today, 0)
            }
            let cost = records
                .filter { cal.isDate(Date(timeIntervalSince1970: $0.t), inSameDayAs: day) }
                .reduce(0) { $0 + Pricing.cost($1) }
            return (day, cost)
        }
    }

    var recent: [UsageRecord] { Array(records.suffix(20).reversed()) }
}
