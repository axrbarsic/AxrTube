import Foundation
import Testing
@testable import iPocketTubeCore

@Suite("HLS audio-only extraction")
struct HLSAudioExtractionTests {
    private let base = URL(string: "https://manifest.googlevideo.com/master.m3u8")!

    private let master = """
    #EXTM3U
    #EXT-X-MEDIA:URI="https://m.example/itag/233/a.m3u8",TYPE=AUDIO,GROUP-ID="233",NAME="Default",DEFAULT=YES
    #EXT-X-MEDIA:URI="https://m.example/itag/234/a.m3u8",TYPE=AUDIO,GROUP-ID="234",NAME="Default",DEFAULT=YES
    #EXT-X-MEDIA:URI="https://m.example/vtt",TYPE=SUBTITLES,GROUP-ID="vtt",NAME="en"
    #EXT-X-STREAM-INF:BANDWIDTH=313238,CODECS="avc1.4D4015,mp4a.40.5",AUDIO="233"
    https://m.example/v/240.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=4688833,CODECS="avc1.640028,mp4a.40.2",AUDIO="234"
    https://m.example/v/1080.m3u8
    """

    @Test func picksAudioGroupOfHighestBandwidthVariant() {
        let url = HLSAudioExtraction.bestAudioPlaylistURL(masterText: master, masterURL: base)
        #expect(url?.absoluteString == "https://m.example/itag/234/a.m3u8")
    }

    @Test func returnsNilWithoutAudioRenditions() {
        let plain = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8\n"
        #expect(HLSAudioExtraction.bestAudioPlaylistURL(masterText: plain, masterURL: base) == nil)
    }

    @Test func resolvesSegmentURLsRelativeToPlaylist() {
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:8
        #EXTINF:3.1,
        seg/1.ts
        #EXTINF:5.0,
        https://cdn.example/seg/2.ts
        #EXT-X-ENDLIST
        """
        let urls = HLSAudioExtraction.segmentURLs(
            playlistText: playlist,
            playlistURL: URL(string: "https://m.example/itag/234/a.m3u8")!
        )
        #expect(urls.map(\.absoluteString) == [
            "https://m.example/itag/234/seg/1.ts",
            "https://cdn.example/seg/2.ts",
        ])
    }

    @Test func stripsLeadingID3TagFromPackedAudio() {
        // ID3v2 header with syncsafe size 4, then 4 tag bytes, then ADTS sync word.
        let id3: [UInt8] = [0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 1, 2, 3, 4]
        let adts: [UInt8] = [0xFF, 0xF1, 0x50, 0x80]
        #expect(HLSAudioExtraction.stripID3(Data(id3 + adts)) == Data(adts))
        #expect(HLSAudioExtraction.stripID3(Data(adts)) == Data(adts))
    }
}
