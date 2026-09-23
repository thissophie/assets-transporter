import Foundation
import Testing
@testable import AssetsTransporter

/// Pins `ClipRow.formatDuration`: m:ss with hours deliberately rolling into
/// minutes (per spec — clip rows favor a compact single format over h:mm:ss).
struct ClipDurationFormatTests {
    @Test func formatsMinutesAndSeconds() {
        #expect(ClipRow.formatDuration(83.4) == "1:23")
    }

    @Test func hoursRollIntoMinutes() {
        #expect(ClipRow.formatDuration(3661) == "61:01")
    }

    @Test func zeroAndRounding() {
        #expect(ClipRow.formatDuration(0) == "0:00")
        #expect(ClipRow.formatDuration(59.6) == "1:00")
    }
}
