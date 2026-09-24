import Foundation
import Testing
@testable import AssetsTransporter

/// Pins the browsing context title (macOS window title / projects column):
/// "Client – Server", degrading gracefully when either half is missing.
struct BrowseTitleTests {
    @Test func clientAndServerAreJoined() {
        #expect(BrowseTitle.clientAndServer(client: "Acme", serverName: "Studio NAS")
            == "Acme – Studio NAS")
    }

    @Test func serverAloneBeforeAClientIsPicked() {
        #expect(BrowseTitle.clientAndServer(client: nil, serverName: "Studio NAS")
            == "Studio NAS")
    }

    @Test func blankServerNameLeavesNoStrayDash() {
        #expect(BrowseTitle.clientAndServer(client: "Acme", serverName: "") == "Acme")
    }

    @Test func bothMissingIsEmpty() {
        #expect(BrowseTitle.clientAndServer(client: nil, serverName: nil).isEmpty)
    }
}
