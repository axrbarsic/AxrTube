import Foundation
import Testing
@testable import iPocketTubeCore

// MARK: - SearchFilterUITests
//
// Tests the SearchFilter model that directly drives the search filter sheet UI:
//   • The filter badge (active indicator) shows when !filter.isDefault
//   • Each option cell shows its .label string
//   • Resetting restores the default state (badge disappears)
//   • Active filters produce a non-nil encodedParams() sent with the request

@Suite("Search Filter UI")
struct SearchFilterUITests {

    // MARK: Badge visibility

    @Test("Default filter shows no badge")
    func defaultFilterIsDefault() {
        #expect(SearchFilter.default.isDefault)
    }

    @Test("Changing sort order activates the filter badge")
    func sortOrderActivatesBadge() {
        var filter = SearchFilter()
        filter.sortOrder = .viewCount
        #expect(!filter.isDefault)
    }

    @Test("Changing upload date activates the filter badge")
    func uploadDateActivatesBadge() {
        var filter = SearchFilter()
        filter.uploadDate = .thisWeek
        #expect(!filter.isDefault)
    }

    @Test("Changing video type activates the filter badge")
    func videoTypeActivatesBadge() {
        var filter = SearchFilter()
        filter.type = .playlist
        #expect(!filter.isDefault)
    }

    @Test("Changing duration activates the filter badge")
    func durationActivatesBadge() {
        var filter = SearchFilter()
        filter.duration = .long
        #expect(!filter.isDefault)
    }

    @Test("Resetting all fields hides the badge")
    func resetHidesBadge() {
        var filter = SearchFilter()
        filter.sortOrder  = .uploadDate
        filter.uploadDate = .today
        filter.type       = .video
        filter.duration   = .short
        #expect(!filter.isDefault)

        filter = .default
        #expect(filter.isDefault)
    }

    // MARK: Params encoding (sent with search request)

    @Test("Default filter encodes to nil — no extra param sent")
    func defaultFilterEncodesNil() {
        #expect(SearchFilter.default.encodedParams() == nil)
    }

    @Test("Active filter encodes to a non-nil, non-empty string")
    func activeFilterEncodesParams() {
        var filter = SearchFilter()
        filter.sortOrder = .rating
        let params = filter.encodedParams()
        #expect(params != nil)
        #expect(params?.isEmpty == false)
    }

    @Test("Two different filters produce different encoded params")
    func distinctFiltersProduceDifferentParams() {
        var f1 = SearchFilter()
        f1.sortOrder = .rating

        var f2 = SearchFilter()
        f2.sortOrder = .viewCount

        #expect(f1.encodedParams() != f2.encodedParams())
    }

    // MARK: Display labels (shown in filter sheet cells)

    @Test("All SortOrder options have non-empty labels")
    func sortOrderLabels() {
        for option in SearchFilter.SortOrder.allCases {
            #expect(!option.label.isEmpty, "SortOrder.\(option) has an empty label")
        }
    }

    @Test("All UploadDate options have non-empty labels")
    func uploadDateLabels() {
        for option in SearchFilter.UploadDate.allCases {
            #expect(!option.label.isEmpty, "UploadDate.\(option) has an empty label")
        }
    }

    @Test("All VideoType options have non-empty labels")
    func videoTypeLabels() {
        for option in SearchFilter.VideoType.allCases {
            #expect(!option.label.isEmpty, "VideoType.\(option) has an empty label")
        }
    }

    @Test("All Duration options have non-empty labels")
    func durationLabels() {
        for option in SearchFilter.Duration.allCases {
            #expect(!option.label.isEmpty, "Duration.\(option) has an empty label")
        }
    }
}

// MARK: - SearchFilterCombinedParamsTests

@Suite("Search Filter Combined Params")
struct SearchFilterCombinedParamsTests {

    @Test("Setting all fields produces non-nil params")
    func allFieldsSetProducesParams() {
        var filter = SearchFilter()
        filter.sortOrder  = .viewCount
        filter.uploadDate = .thisWeek
        filter.type       = .video
        filter.duration   = .long
        #expect(filter.encodedParams() != nil)
    }

    @Test("Encoded params are valid base64")
    func encodedParamsAreBase64() throws {
        var filter = SearchFilter()
        filter.sortOrder = .rating
        let params = try #require(filter.encodedParams())
        let data = Data(base64Encoded: params, options: .ignoreUnknownCharacters)
        #expect(data != nil, "encodedParams() must produce a valid base64 string")
    }

    @Test("Only uploadDate set changes params relative to default")
    func uploadDateOnlyChangesParams() {
        var filter = SearchFilter()
        filter.uploadDate = .today
        #expect(filter.encodedParams() != SearchFilter.default.encodedParams())
    }

    @Test("Only duration set produces non-nil params")
    func durationOnlyProducesParams() {
        var filter = SearchFilter()
        filter.duration = .short
        #expect(filter.encodedParams() != nil)
    }

    @Test("Only type set produces non-nil params")
    func typeOnlyProducesParams() {
        var filter = SearchFilter()
        filter.type = .channel
        #expect(filter.encodedParams() != nil)
    }

    @Test("Each non-default SortOrder produces different params")
    func sortOrdersProduceDifferentParams() {
        let nonDefault = SearchFilter.SortOrder.allCases.filter { $0 != .relevance }
        var seen: Set<String> = []
        for order in nonDefault {
            var filter = SearchFilter()
            filter.sortOrder = order
            if let p = filter.encodedParams() {
                seen.insert(p)
            }
        }
        #expect(seen.count == nonDefault.count, "Each sort order should produce unique params")
    }
}
