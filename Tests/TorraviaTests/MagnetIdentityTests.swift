@testable import TorraviaSearchCore
import AppKit
import Foundation
import Testing
@testable import Torravia



@MainActor
struct MagnetIdentityTests {
    @Test func canonicalMagnetIdentityUsesInfoHashNotDisplayMetadata() throws {
        let first = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=First&tr=udp%3A%2F%2Ftracker.example%3A80"
        let second = " magnet:?xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567&dn=Second&tr=http%3A%2F%2Ftracker.example%2Fannounce "

        #expect(DownloadsViewModel.isValidMagnetLink(first))
        #expect(DownloadsViewModel.canonicalMagnetIdentity(first) == DownloadsViewModel.canonicalMagnetIdentity(second))
    }

    @Test func validatesV2MagnetMultihash() throws {
        let hash = String(repeating: "a", count: 64)
        let magnet = "magnet:?xt=urn:btmh:1220\(hash)"

        #expect(DownloadsViewModel.isValidMagnetLink(magnet))
        #expect(DownloadsViewModel.canonicalMagnetIdentity(magnet) == "btmh:1220\(hash)")
        #expect(!DownloadsViewModel.isValidMagnetLink("magnet:?xt=urn:btmh:invalid"))
    }
}
