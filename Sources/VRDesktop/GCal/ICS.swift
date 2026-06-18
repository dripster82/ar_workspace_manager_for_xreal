import Foundation

/// Minimal iCalendar (.ics) parser that produces concrete `CalEvent`s within a time window,
/// expanding recurring events (RRULE) for the common DAILY / WEEKLY(+BYDAY) / MONTHLY cases,
/// honouring INTERVAL / UNTIL / COUNT, EXDATE exclusions, and RECURRENCE-ID overrides.
enum ICS {
    /// Calendar display name from X-WR-CALNAME, if present.
    static func calendarName(_ text: String) -> String? {
        for line in unfold(text) where line.hasPrefix("X-WR-CALNAME") {
            return line.split(separator: ":", maxSplits: 1).last.map(String.init)
        }
        return nil
    }

    static func parseEvents(_ text: String, windowStart: Date, windowEnd: Date) -> [CalEvent] {
        let lines = unfold(text)
        var blocks: [[String]] = []
        var current: [String]?
        for line in lines {
            if line == "BEGIN:VEVENT" { current = [] }
            else if line == "END:VEVENT" { if let c = current { blocks.append(c) }; current = nil }
            else { current?.append(line) }
        }

        // Overrides (RECURRENCE-ID) replace a single instance of their UID at the original start.
        var overrides: Set<String> = []   // "UID@<epoch>" keys to suppress in the parent expansion
        var singles: [CalEvent] = []
        var recurring: [(block: [String: (params: [String: String], value: String)], uid: String)] = []

        for block in blocks {
            let props = properties(block)
            guard let dtstart = props["DTSTART"] else { continue }
            let uid = props["UID"]?.value ?? UUID().uuidString
            let title = decode(props["SUMMARY"]?.value ?? "(no title)")
            guard let (start, allDay) = parseDate(dtstart.value, params: dtstart.params) else { continue }
            let end = props["DTEND"].flatMap { parseDate($0.value, params: $0.params)?.0 }
                ?? start.addingTimeInterval(allDay ? 86400 : 3600)

            if let recID = props["RECURRENCE-ID"], let (orig, _) = parseDate(recID.value, params: recID.params) {
                overrides.insert("\(uid)@\(Int(orig.timeIntervalSinceReferenceDate))")
            }

            if props["RRULE"] != nil {
                recurring.append((props, uid))
            } else if end > windowStart && start < windowEnd {
                singles.append(CalEvent(id: "\(uid)-\(Int(start.timeIntervalSince1970))",
                                        title: title, start: start, end: end, allDay: allDay))
            }
        }

        var result = singles
        for (props, uid) in recurring {
            guard let dtstart = props["DTSTART"],
                  let (start, allDay) = parseDate(dtstart.value, params: dtstart.params),
                  let rrule = props["RRULE"]?.value else { continue }
            let end = props["DTEND"].flatMap { parseDate($0.value, params: $0.params)?.0 } ?? start.addingTimeInterval(3600)
            let duration = end.timeIntervalSince(start)
            let tz = timeZone(for: dtstart.params)
            let exdates = exDates(props, tz: tz)
            let title = decode(props["SUMMARY"]?.value ?? "(no title)")

            for occ in expand(start: start, rule: parseRRULE(rrule), tz: tz,
                              windowStart: windowStart, windowEnd: windowEnd) {
                let key = "\(uid)@\(Int(occ.timeIntervalSinceReferenceDate))"
                if overrides.contains(key) { continue }
                if exdates.contains(where: { abs($0.timeIntervalSince(occ)) < 60 }) { continue }
                let oEnd = occ.addingTimeInterval(duration)
                guard oEnd > windowStart, occ < windowEnd else { continue }
                result.append(CalEvent(id: "\(uid)-\(Int(occ.timeIntervalSince1970))",
                                       title: title, start: occ, end: oEnd, allDay: allDay))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    // MARK: Parsing helpers

    /// Unfold RFC 5545 line continuations (a CRLF/LF followed by space or tab) and split into lines.
    private static func unfold(_ text: String) -> [String] {
        let joined = text
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
        return joined.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).map(String.init)
    }

    private static func properties(_ block: [String]) -> [String: (params: [String: String], value: String)] {
        var out: [String: (params: [String: String], value: String)] = [:]
        for line in block {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let left = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            let parts = left.split(separator: ";").map(String.init)
            guard let name = parts.first else { continue }
            var params: [String: String] = [:]
            for p in parts.dropFirst() {
                let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { params[kv[0].uppercased()] = kv[1] }
            }
            // Keep the first occurrence except for multi-valued ones handled separately (EXDATE).
            if out[name] == nil { out[name] = (params, value) }
        }
        return out
    }

    private static func timeZone(for params: [String: String]) -> TimeZone {
        if let tzid = params["TZID"], let tz = TimeZone(identifier: tzid) { return tz }
        return .current
    }

    /// Parse an iCal date/date-time value. Returns the instant and whether it's an all-day date.
    static func parseDate(_ value: String, params: [String: String]) -> (Date, Bool)? {
        if params["VALUE"] == "DATE" || (value.count == 8 && !value.contains("T")) {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd"; f.timeZone = .current
            return f.date(from: value).map { ($0, true) }
        }
        let utc = value.hasSuffix("Z")
        let clean = utc ? String(value.dropLast()) : value
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = utc ? TimeZone(identifier: "UTC") : timeZone(for: params)
        return f.date(from: clean).map { ($0, false) }
    }

    private static func exDates(_ props: [String: (params: [String: String], value: String)], tz: TimeZone) -> [Date] {
        // properties() collapses duplicates, so EXDATE with multiple values is handled via its
        // comma-separated value; multiple EXDATE lines fold into one here (best-effort).
        guard let ex = props["EXDATE"] else { return [] }
        return ex.value.split(separator: ",").compactMap { parseDate(String($0), params: ex.params)?.0 }
    }

    // MARK: RRULE

    private static func parseRRULE(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0].uppercased()] = kv[1] }
        }
        return out
    }

    private static let weekdayMap: [String: Int] = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    private static func expand(start: Date, rule: [String: String], tz: TimeZone,
                               windowStart: Date, windowEnd: Date) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        cal.firstWeekday = 2 // ICS weeks start Monday (WKST default)

        let freq = rule["FREQ"] ?? "DAILY"
        let interval = max(1, Int(rule["INTERVAL"] ?? "1") ?? 1)
        let count = rule["COUNT"].flatMap { Int($0) }
        let until = rule["UNTIL"].flatMap { parseDate($0, params: [:])?.0 }
        var results: [Date] = []
        var emitted = 0
        let cap = 3000

        func consider(_ date: Date) -> Bool { // returns false to stop
            if let until, date > until { return false }
            if let count, emitted >= count { return false }
            emitted += 1
            if date >= windowStart && date < windowEnd { results.append(date) }
            return date <= windowEnd
        }

        if freq == "WEEKLY", let byday = rule["BYDAY"] {
            let comps = cal.dateComponents([.hour, .minute, .second], from: start)
            // Day offsets from Monday (MO=0 … SU=6) for each BYDAY weekday.
            let offsets = byday.split(separator: ",").compactMap { s -> Int? in
                guard let wd = weekdayMap[String(s.suffix(2))] else { return nil }
                return (wd + 5) % 7
            }.sorted()
            let startWeekday = cal.component(.weekday, from: start)
            let daysSinceMon = (startWeekday + 5) % 7
            guard var weekMonday = cal.date(byAdding: .day, value: -daysSinceMon, to: cal.startOfDay(for: start))
            else { return results }
            for _ in 0..<cap {
                for off in offsets {
                    guard let day = cal.date(byAdding: .day, value: off, to: weekMonday) else { continue }
                    var dc = cal.dateComponents([.year, .month, .day], from: day)
                    dc.hour = comps.hour; dc.minute = comps.minute; dc.second = comps.second
                    guard let occ = cal.date(from: dc), occ >= start else { continue }
                    if !consider(occ) { return results }
                }
                guard let next = cal.date(byAdding: .day, value: 7 * interval, to: weekMonday) else { break }
                weekMonday = next
                if weekMonday > windowEnd.addingTimeInterval(8 * 86400) { break }
            }
            return results
        }

        let component: Calendar.Component = freq == "DAILY" ? .day : (freq == "WEEKLY" ? .weekOfYear
            : (freq == "MONTHLY" ? .month : (freq == "YEARLY" ? .year : .day)))
        var date = start
        for _ in 0..<cap {
            if !consider(date) { break }
            guard let next = cal.date(byAdding: component, value: interval, to: date) else { break }
            date = next
            if date > windowEnd { break }
        }
        return results
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
