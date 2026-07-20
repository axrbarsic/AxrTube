import Foundation

// MARK: - SearchFilter
//
// Mirrors Android SearchPresenter's filter options:
//   uploadDate | duration | type | features | sorting
//
// The `params` field sent to InnerTube search is a base64-encoded
// protobuf (manually encoded — no proto dependency required).
//
// Outer message:
//   field 1 (sort):   varint — SortOrder raw value
//   field 2 (filter): LEN    — nested Filter message
//
// Inner Filter message:
//   field 1 (uploadDate): varint — UploadDate raw value (0 = omit)
//   field 2 (type):       varint — VideoType raw value  (0 = omit)
//   field 3 (duration):   varint — Duration raw value   (0 = omit)

public struct SearchFilter: Sendable, Equatable {

    // MARK: - Nested enums (mirror Android Constants)

    public enum SortOrder: Int, CaseIterable, Sendable {
        case relevance  = 0   // default — no param emitted
        case rating     = 1
        case uploadDate = 2
        case viewCount  = 3

        public var label: String {
            switch self {
            case .relevance:  return "Relevance"
            case .rating:     return "Rating"
            case .uploadDate: return "Upload date"
            case .viewCount:  return "View count"
            }
        }
    }

    public enum UploadDate: Int, CaseIterable, Sendable {
        case anytime   = 0   // default — no param emitted
        case lastHour  = 1
        case today     = 2
        case thisWeek  = 3
        case thisMonth = 4
        case thisYear  = 5

        public var label: String {
            switch self {
            case .anytime:   return "Anytime"
            case .lastHour:  return "Last hour"
            case .today:     return "Today"
            case .thisWeek:  return "This week"
            case .thisMonth: return "This month"
            case .thisYear:  return "This year"
            }
        }
    }

    public enum VideoType: Int, CaseIterable, Sendable {
        case any      = 0   // default — no param emitted
        case video    = 1
        case channel  = 2
        case playlist = 3
        case movie    = 4

        public var label: String {
            switch self {
            case .any:      return "Any type"
            case .video:    return "Video"
            case .channel:  return "Channel"
            case .playlist: return "Playlist"
            case .movie:    return "Movie"
            }
        }
    }

    public enum Duration: Int, CaseIterable, Sendable {
        case any    = 0   // default — no param emitted
        case short  = 1   // < 4 min
        case medium = 2   // 4 – 20 min
        case long   = 3   // > 20 min

        public var label: String {
            switch self {
            case .any:    return "Any duration"
            case .short:  return "Under 4 minutes"
            case .medium: return "4 – 20 minutes"
            case .long:   return "Over 20 minutes"
            }
        }
    }

    // MARK: - Properties

    public var sortOrder: SortOrder  = .relevance
    public var uploadDate: UploadDate = .anytime
    public var type: VideoType       = .any
    public var duration: Duration    = .any

    public static let `default` = SearchFilter()

    public var isDefault: Bool {
        self == .default
    }

    // MARK: - Init

    public init(
        sortOrder: SortOrder  = .relevance,
        uploadDate: UploadDate = .anytime,
        type: VideoType       = .any,
        duration: Duration    = .any
    ) {
        self.sortOrder  = sortOrder
        self.uploadDate = uploadDate
        self.type       = type
        self.duration   = duration
    }

    // MARK: - Params encoding
    //
    // Produces the base64-encoded protobuf string consumed by
    // InnerTube's `params` search field.
    // Returns nil when no filters are active (avoids sending an empty param).

    public func encodedParams() -> String? {
        var outer = Data()

        // field 1 — sort order (varint), only when non-default
        if sortOrder != .relevance {
            outer.appendVarintField(fieldNumber: 1, value: sortOrder.rawValue)
        }

        // field 2 — inner filter message (length-delimited)
        var inner = Data()
        if uploadDate != .anytime {
            inner.appendVarintField(fieldNumber: 1, value: uploadDate.rawValue)
        }
        if type != .any {
            inner.appendVarintField(fieldNumber: 2, value: type.rawValue)
        }
        if duration != .any {
            inner.appendVarintField(fieldNumber: 3, value: duration.rawValue)
        }

        if !inner.isEmpty {
            outer.appendLenField(fieldNumber: 2, value: inner)
        }

        guard !outer.isEmpty else { return nil }
        return outer.base64EncodedString()
    }
}

// MARK: - Protobuf encoding helpers (minimal, private to this file)

private extension Data {
    /// Encode a varint tag + varint value: `(fieldNumber << 3) | 0`, then the value.
    mutating func appendVarintField(fieldNumber: Int, value: Int) {
        appendVarint(UInt64((fieldNumber << 3) | 0))  // wire type 0 = varint
        appendVarint(UInt64(value))
    }

    /// Encode a length-delimited tag + embedded bytes: `(fieldNumber << 3) | 2`, length, bytes.
    mutating func appendLenField(fieldNumber: Int, value: Data) {
        appendVarint(UInt64((fieldNumber << 3) | 2))  // wire type 2 = length-delimited
        appendVarint(UInt64(value.count))
        append(value)
    }

    /// Append a base-128 (LEB128) varint.
    mutating func appendVarint(_ value: UInt64) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            append(byte)
        } while v != 0
    }
}
