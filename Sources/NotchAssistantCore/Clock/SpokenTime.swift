import Foundation

/// A transcript split into words for time parsing. Unlike
/// `AppNameMatcher.normalize`, keeps "7:30" and "1.5" whole, and folds
/// "a.m." into "am" and "o'clock" into "oclock". `raw` keeps the user's
/// capitalisation (for a reminder's text); `lower` is for matching.
struct SpokenWords: Equatable {
    let raw: [String]
    let lower: [String]

    init(_ text: String) {
        let chars = Array(text.replacingOccurrences(of: "’", with: "'"))
        var cleaned = ""
        for (index, char) in chars.enumerated() {
            let between = index > 0 && index + 1 < chars.count && chars[index - 1].isNumber && chars[index + 1].isNumber
            if char.isLetter || char.isNumber {
                cleaned.append(char)
            } else if (char == "." || char == ":") && between {
                cleaned.append(char)
            } else if char == "'" {
                continue // "o'clock" → "oclock", "I'm" → "Im"
            } else {
                cleaned.append(" ")
            }
        }
        var raw: [String] = []
        for word in cleaned.split(separator: " ").map(String.init) {
            let lower = word.lowercased()
            // "7 a m" (from "7 a.m.") → "7 am".
            if lower == "m", let last = raw.last?.lowercased(), last == "a" || last == "p",
               raw.count >= 2, Self.isNumeric(raw[raw.count - 2]) {
                raw[raw.count - 1] = last + "m"
                continue
            }
            // "7am", "7:30pm" → "7", "am".
            if lower.count > 2, lower.hasSuffix("am") || lower.hasSuffix("pm"), Self.isNumeric(String(lower.dropLast(2))) {
                raw.append(String(word.dropLast(2)))
                raw.append(String(lower.suffix(2)))
                continue
            }
            raw.append(word)
        }
        // "o clock" → "oclock"; "stop watch" → "stopwatch".
        var merged: [String] = []
        for word in raw {
            let lower = word.lowercased()
            if lower == "clock", merged.last?.lowercased() == "o" {
                merged[merged.count - 1] = "oclock"
            } else if lower == "watch", merged.last?.lowercased() == "stop" {
                merged[merged.count - 1] = "stopwatch"
            } else {
                merged.append(word)
            }
        }
        self.raw = merged
        self.lower = merged.map { $0.lowercased() }
    }

    var count: Int { lower.count }

    func contains(_ word: String) -> Bool { lower.contains(word) }

    func containsAny(_ words: Set<String>) -> Bool { lower.contains { words.contains($0) } }

    /// The raw words at these positions, in order.
    func text(_ indices: some Sequence<Int>) -> String {
        indices.sorted().map { raw[$0] }.joined(separator: " ")
    }

    static func isNumeric(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" } && word.first!.isNumber
    }

    // MARK: Numbers

    private static let ones: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let numberWords = Set(ones.keys).union(tens.keys)

    /// A number starting at `index`: "10", "1.5", "twenty five", "seven".
    /// Returns its value and how many words it used.
    func number(at index: Int) -> (value: Double, length: Int)? {
        guard index < count else { return nil }
        let word = lower[index]
        if let value = Double(word) { return (value, 1) }
        if let value = Self.ones[word] { return (Double(value), 1) }
        if let value = Self.tens[word] {
            if index + 1 < count, let unit = Self.ones[lower[index + 1]], (1...9).contains(unit) {
                return (Double(value + unit), 2)
            }
            return (Double(value), 1)
        }
        return nil
    }
}

/// Lengths of time as people say them: "10 minutes", "an hour and a half",
/// "half an hour", "1 hour 30 minutes", "ninety seconds", "1.5 hours".
public enum SpokenDuration {
    static func unit(_ word: String) -> Double? {
        switch word {
        case "hour", "hours", "hr", "hrs": 3600
        case "minute", "minutes", "min", "mins": 60
        case "second", "seconds", "sec", "secs": 1
        default: nil
        }
    }

    static let unitWords: Set<String> = ["hour", "hours", "hr", "hrs", "minute", "minutes", "min", "mins", "second", "seconds", "sec", "secs"]

    /// Parses a duration said on its own ("10 minutes").
    public static func parse(_ text: String) -> TimeInterval? {
        find(in: SpokenWords(text))?.seconds
    }

    /// Every duration said, in order: "one of 10 seconds, one of 20" → [10, 20].
    static func all(in text: String) -> [TimeInterval] {
        let words = SpokenWords(text)
        var found: [TimeInterval] = []
        var start = 0
        while let (seconds, range) = find(in: words, from: start) {
            found.append(seconds)
            start = range.upperBound
        }
        return found
    }

    /// The first duration in the words, and where it is.
    static func find(in words: SpokenWords, from start: Int = 0) -> (seconds: TimeInterval, range: Range<Int>)? {
        guard start < words.count else { return nil }
        for index in start..<words.count {
            if let found = duration(in: words, at: index) { return found }
        }
        return nil
    }

    /// A duration starting exactly at `index`.
    static func duration(in words: SpokenWords, at index: Int) -> (seconds: TimeInterval, range: Range<Int>)? {
        var total: TimeInterval = 0
        var position = index
        var matched = false
        while let (seconds, next) = component(in: words, at: position) {
            total += seconds
            matched = true
            position = next
            // "1 hour and 30 minutes", "1 hour, 30 minutes".
            if position < words.count, words.lower[position] == "and", component(in: words, at: position + 1) != nil {
                position += 1
            }
        }
        return matched ? (total, index..<position) : nil
    }

    /// One "<number> <unit>" piece, with its halves and quarters.
    private static func component(in words: SpokenWords, at index: Int) -> (TimeInterval, Int)? {
        let w = words.lower
        func word(_ offset: Int) -> String? { index + offset < w.count ? w[index + offset] : nil }

        // "half an hour", "half a minute".
        if word(0) == "half", ["a", "an"].contains(word(1) ?? ""), let unit = word(2).flatMap(unit) {
            return (unit / 2, index + 3)
        }
        // "a half hour", "a quarter hour", "quarter of an hour".
        if ["a", "an"].contains(word(0) ?? ""), let fraction = word(1).flatMap(fraction), let unit = word(2).flatMap(unit) {
            return (unit * fraction, index + 3)
        }
        if word(0) == "quarter", word(1) == "of", ["a", "an"].contains(word(2) ?? ""), let unit = word(3).flatMap(unit) {
            return (unit / 4, index + 4)
        }
        if word(0) == "a", word(1) == "quarter", word(2) == "of", ["a", "an"].contains(word(3) ?? ""), let unit = word(4).flatMap(unit) {
            return (unit / 4, index + 5)
        }

        // "10 minutes", "an hour", "one and a half hours".
        var value: Double
        var position: Int
        if let (number, length) = words.number(at: index) {
            value = number
            position = index + length
        } else if ["a", "an"].contains(word(0) ?? ""), word(1).flatMap(unit) != nil {
            value = 1
            position = index + 1
        } else {
            return nil
        }
        if let half = andAHalf(in: words, at: position) {
            value += 0.5
            position = half
        }
        guard position < w.count, let unit = unit(w[position]) else { return nil }
        position += 1
        var seconds = value * unit
        // "an hour and a half".
        if let half = andAHalf(in: words, at: position) {
            seconds += unit / 2
            position = half
        }
        return (seconds, position)
    }

    private static func fraction(_ word: String) -> Double? {
        switch word {
        case "half": 0.5
        case "quarter": 0.25
        default: nil
        }
    }

    /// "and a half" at `index`: returns the position after it.
    private static func andAHalf(in words: SpokenWords, at index: Int) -> Int? {
        let w = words.lower
        if index + 2 < w.count, w[index] == "and", w[index + 1] == "a", w[index + 2] == "half" { return index + 3 }
        if index + 1 < w.count, w[index] == "and", w[index + 1] == "half" { return index + 2 }
        return nil
    }
}

/// A point in time as people say it: "7 am", "tomorrow at 6:30", "half
/// past 5", "noon", "in 20 minutes", "Monday at 9", "tonight at 8".
public struct SpokenWhen: Equatable, Sendable {
    public let date: Date
    /// False for a day with no time ("tomorrow"): a date-only reminder.
    public let hasTime: Bool
    /// False for a time with no day ("at 3"): the next 3 o'clock was chosen.
    public var hasDay = true
    /// The words that said it, including "at", "on" and "in".
    let consumed: Set<Int>

    /// Parses a time said on its own ("7:30 am tomorrow").
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> SpokenWhen? {
        find(in: SpokenWords(text), now: now, calendar: calendar)
    }

    static func find(in words: SpokenWords, now: Date, calendar: Calendar, from start: Int = 0) -> SpokenWhen? {
        let w = words.lower
        guard start < w.count else { return nil }

        // Relative: "in 20 minutes", "20 minutes from now".
        for index in start..<w.count {
            if w[index] == "in", let (seconds, range) = SpokenDuration.duration(in: words, at: index + 1) {
                return SpokenWhen(date: now.addingTimeInterval(seconds), hasTime: true, consumed: Set(index..<range.upperBound))
            }
            if let (seconds, range) = SpokenDuration.duration(in: words, at: index),
               range.upperBound + 1 < w.count, w[range.upperBound] == "from", w[range.upperBound + 1] == "now" {
                return SpokenWhen(date: now.addingTimeInterval(seconds), hasTime: true, consumed: Set(range.lowerBound..<range.upperBound + 2))
            }
        }

        var consumed = Set<Int>()
        let day = Self.day(in: words, from: start, now: now, calendar: calendar, consumed: &consumed)
        let time = Self.time(in: words, from: start, excluding: consumed)
        if let time { consumed.formUnion(time.consumed) }
        guard day != nil || time != nil else { return nil }

        var hint = time?.meridiem ?? day?.meridiem
        guard let time else {
            // A day with no time.
            let date = calendar.startOfDay(for: day!.date)
            return SpokenWhen(date: date, hasTime: false, consumed: consumed)
        }
        var hour = time.hour
        let minute = time.minute
        if time.meridiem == nil, day?.meridiem == .pm, hour < 12 { hint = .pm }
        switch hint {
        case .am?: if hour == 12 { hour = 0 }
        case .pm?: if hour < 12 { hour += 12 }
        case nil: break
        }

        if let day {
            // "tomorrow at 7": the hour as said (7 am) unless a hint says pm.
            guard let date = calendar.date(bySettingHour: hour % 24, minute: minute, second: 0, of: day.date) else { return nil }
            return SpokenWhen(date: date, hasTime: true, consumed: consumed)
        }
        // No day: the next time that hour comes round. "7" at 10 pm is 7 am
        // tomorrow; at 10 am it is 7 pm today.
        var hours = [hour % 24]
        if hint == nil, hour >= 1, hour <= 12 { hours = [hour % 12, hour % 12 + 12] }
        let candidates = hours.compactMap { next(hour: $0, minute: minute, after: now, calendar: calendar) }
        guard let date = candidates.min() else { return nil }
        return SpokenWhen(date: date, hasTime: true, hasDay: false, consumed: consumed)
    }

    enum Meridiem { case am, pm }

    /// Every time of day said, as (hour, minute, whether am/pm was said):
    /// "seven on weekdays and eight on weekends" → [(7, 0), (8, 0)]. Hours
    /// are 0–23 when am/pm was said, else as spoken.
    static func clockTimes(in text: String) -> [(hour: Int, minute: Int, exact: Bool)] {
        let words = SpokenWords(text)
        var times: [(hour: Int, minute: Int, exact: Bool)] = []
        var index = 0
        while index < words.count {
            // Bare numbers count here ("seven on weekdays"): the model
            // restated them, so they only need to match, not stand alone.
            if let found = timeOfDay(in: words, at: index) {
                var hour = found.hour
                switch found.meridiem {
                case .pm?: if hour < 12 { hour += 12 }
                case .am?: if hour == 12 { hour = 0 }
                case nil: break
                }
                times.append((hour, found.minute, found.meridiem != nil))
                index = max(index + 1, found.consumed.max().map { $0 + 1 } ?? index + 1)
            } else {
                index += 1
            }
        }
        return times
    }

    /// True when a time the model gave was among those the user said.
    static func wasSaid(_ date: Date, in text: String, calendar: Calendar = .current) -> Bool {
        let clock = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = clock.hour, let minute = clock.minute else { return false }
        return clockTimes(in: text).contains { said in
            said.minute == minute && (said.exact ? said.hour == hour : said.hour % 12 == hour % 12)
        }
    }

    private static func next(hour: Int, minute: Int, after now: Date, calendar: Calendar) -> Date? {
        guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    // MARK: Day

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    private static func day(in words: SpokenWords, from start: Int, now: Date, calendar: Calendar, consumed: inout Set<Int>) -> (date: Date, meridiem: Meridiem?)? {
        let w = words.lower
        for index in start..<w.count {
            let word = w[index]
            func take(_ range: ClosedRange<Int>) {
                consumed.formUnion(range)
                // "on Monday", "by tomorrow".
                if range.lowerBound > start, ["on", "by", "for"].contains(w[range.lowerBound - 1]) { consumed.insert(range.lowerBound - 1) }
            }
            if word == "tomorrow" {
                // "the day after tomorrow".
                if index >= 2, w[index - 1] == "after", w[index - 2] == "day" {
                    let first = index >= 3 && w[index - 3] == "the" ? index - 3 : index - 2
                    take(first...index)
                    return (calendar.date(byAdding: .day, value: 2, to: now)!, nil)
                }
                take(index...index)
                return (calendar.date(byAdding: .day, value: 1, to: now)!, meridiem(after: index, in: w, consumed: &consumed))
            }
            if word == "tonight" {
                take(index...index)
                return (now, .pm)
            }
            if word == "today" {
                take(index...index)
                return (now, nil)
            }
            if word == "this", index + 1 < w.count, let meridiem = partOfDay(w[index + 1]) {
                take(index...index + 1)
                return (now, meridiem)
            }
            if let weekday = weekdays.firstIndex(of: word) {
                // "next Monday" and "this Monday" both mean the coming one.
                let first = index > 0 && ["next", "this"].contains(w[index - 1]) ? index - 1 : index
                take(first...index)
                let today = calendar.component(.weekday, from: now) - 1
                var ahead = (weekday - today + 7) % 7
                if ahead == 0 { ahead = 7 }
                return (calendar.date(byAdding: .day, value: ahead, to: now)!, meridiem(after: index, in: w, consumed: &consumed))
            }
        }
        return nil
    }

    /// "tomorrow morning", "Monday evening".
    private static func meridiem(after index: Int, in w: [String], consumed: inout Set<Int>) -> Meridiem? {
        guard index + 1 < w.count, let meridiem = partOfDay(w[index + 1]) else { return nil }
        consumed.insert(index + 1)
        return meridiem
    }

    private static func partOfDay(_ word: String) -> Meridiem? {
        switch word {
        case "morning": .am
        case "afternoon", "evening", "night": .pm
        default: nil
        }
    }

    // MARK: Time of day

    struct TimeOfDay {
        var hour: Int
        var minute: Int
        var meridiem: Meridiem?
        var consumed: Set<Int>
        /// How sure: a meridiem or "7:30" beats "at 7", which beats "for 7".
        var score: Int
    }

    private static let prefixes: [String: Int] = ["at": 2, "for": 1, "by": 1, "around": 1, "till": 1, "until": 1]

    static func time(in words: SpokenWords, from start: Int, excluding: Set<Int>) -> TimeOfDay? {
        let w = words.lower
        var best: TimeOfDay?
        var index = start
        while index < w.count {
            defer { index += 1 }
            guard !excluding.contains(index), let found = timeOfDay(in: words, at: index), found.score > 0 else { continue }
            if best == nil || found.score >= best!.score { best = found }
        }
        return best
    }

    private static func timeOfDay(in words: SpokenWords, at index: Int) -> TimeOfDay? {
        let w = words.lower
        var hour: Int
        var minute = 0
        var position: Int
        var score = 0
        var first = index

        switch w[index] {
        case "noon", "midday", "midnight":
            var consumed: Set<Int> = [index]
            if index > 0, prefixes[w[index - 1]] != nil { consumed.insert(index - 1) }
            let noon = w[index] != "midnight"
            return TimeOfDay(hour: noon ? 12 : 0, minute: 0, meridiem: noon ? .pm : .am, consumed: consumed, score: 3)
        case "half", "quarter":
            // "half past 7", "quarter to 8".
            guard index + 2 < w.count, ["past", "to"].contains(w[index + 1]), let (value, length) = words.number(at: index + 2),
                  value == value.rounded(), (1...12).contains(Int(value)) else { return nil }
            let offset = w[index] == "half" ? 30 : 15
            if w[index + 1] == "past" {
                hour = Int(value); minute = offset
            } else {
                hour = Int(value) - 1; minute = 60 - offset
                if hour == 0 { hour = 12 }
            }
            position = index + 2 + length; score = 2
        default:
            let word = w[index]
            if word.contains(":") {
                let parts = word.split(separator: ":")
                guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
                hour = h; minute = m; position = index + 1; score = 2
            } else if word.count >= 3, word.count <= 4, let digits = Int(word), !word.contains(".") {
                // "730", "1930".
                let h = digits / 100, m = digits % 100
                guard (0...23).contains(h), (0...59).contains(m) else { return nil }
                hour = h; minute = m; position = index + 1; score = 1
            } else if let (value, length) = words.number(at: index), value == value.rounded() {
                let n = Int(value)
                position = index + length
                if position + 1 < w.count, ["past", "to"].contains(w[position]), (1...30).contains(n),
                   let (h, l) = words.number(at: position + 1), h == h.rounded(), (1...12).contains(Int(h)) {
                    // "25 past 7", "10 to 8".
                    let before = w[position] == "to"
                    hour = before ? Int(h) - 1 : Int(h)
                    if hour == 0 { hour = 12 }
                    minute = before ? 60 - n : n
                    position += 1 + l; score = 2
                } else {
                    guard (0...24).contains(n) else { return nil }
                    hour = n % 24
                    // "seven thirty", "7 45", "seven oh five".
                    if position < w.count, SpokenDuration.unit(w[position]) == nil {
                        if w[position] == "oh", let (m, l) = words.number(at: position + 1), (1...9).contains(Int(m)) {
                            minute = Int(m); position += 1 + l; score = 1
                        } else if let (m, l) = words.number(at: position), m == m.rounded(), (10...59).contains(Int(m)) {
                            minute = Int(m); position += l; score = 1
                        }
                    }
                    // "10 minutes" is a duration, not a time.
                    if position < w.count, SpokenDuration.unit(w[position]) != nil { return nil }
                }
            } else {
                return nil
            }
        }

        if position < w.count, w[position] == "oclock" { position += 1; score = max(score, 2) }
        var meridiem: Meridiem?
        if position < w.count {
            switch w[position] {
            case "am": meridiem = .am; position += 1
            case "pm": meridiem = .pm; position += 1
            case "in" where position + 2 < w.count && w[position + 1] == "the":
                if let m = partOfDay(w[position + 2]) { meridiem = m; position += 3 }
            case "at" where position + 1 < w.count && w[position + 1] == "night":
                meridiem = .pm; position += 2
            case "tonight":
                meridiem = .pm; position += 1
            default: break
            }
        }
        if meridiem != nil { score = 3 }
        if index > 0, let prefix = prefixes[w[index - 1]] {
            score += prefix
            first = index - 1
        }
        guard hour <= 23 else { return nil }
        if meridiem != nil, hour > 12 { meridiem = nil }
        return TimeOfDay(hour: hour, minute: minute, meridiem: meridiem, consumed: Set(first..<position), score: score)
    }
}

/// How times and lengths are said back.
public enum ClockFormat {
    /// "1 hour 30 minutes", "9 minutes 41 seconds", "45 seconds". Seconds
    /// are dropped from an hour or more.
    public static func spoken(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append(plural(hours, "hour")) }
        if minutes > 0 { parts.append(plural(minutes, "minute")) }
        if seconds > 0, hours == 0 { parts.append(plural(seconds, "second")) }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }

    /// "10 minute", "1 hour 30 minute": for "a 10 minute timer".
    public static func adjective(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour") }
        if minutes > 0 { parts.append("\(minutes) minute") }
        if seconds > 0, hours == 0 { parts.append("\(seconds) second") }
        return parts.joined(separator: " ")
    }

    /// "9:41", "1:02:03": for the menu bar.
    public static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// "1:23.4": a stopwatch reading.
    public static func stopwatch(_ interval: TimeInterval) -> String {
        let tenths = Int((interval * 10).rounded(.down))
        let total = tenths / 10
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d.%d", hours, minutes, seconds, tenths % 10)
            : String(format: "%d:%02d.%d", minutes, seconds, tenths % 10)
    }

    /// "7:00 AM", "tomorrow at 7:00 AM", "Monday at 7:00 AM", "3 October at 7:00 AM".
    public static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current, hasTime: Bool = true) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let day: String?
        if calendar.isDate(date, inSameDayAs: now) {
            day = hasTime ? nil : "today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            day = "tomorrow"
        } else if let week = calendar.date(byAdding: .day, value: 6, to: now), date < week {
            day = date.formatted(.dateTime.weekday(.wide))
        } else {
            day = date.formatted(.dateTime.day().month(.wide))
        }
        guard hasTime else { return day ?? "today" }
        return day.map { "\($0) at \(time)" } ?? time
    }

    private static func plural(_ count: Int, _ unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
}
