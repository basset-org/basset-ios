import BassetECS
import Testing

struct MenuTests {
    /// A caller reads this markdown to learn what a `-i name:key=value` token can set.
    @Test func aConfigurableInstrumentsMenuEntryListsItsSchema() {
        let entry = InstrumentID.mainThreadHang.menuEntry
        let rendered = entry.markdown()

        #expect(rendered.contains("**Config**"))
        #expect(rendered.contains("`thresholdMs` (int 100...60000)"))
    }

    /// Nothing to set — the plain, common case reads as prose alone, no empty table.
    @Test func aPlainInstrumentsMenuEntryHasNoConfigSection() {
        let entry = InstrumentID.deviceInfo.menuEntry
        #expect(!entry.markdown().contains("**Config**"))
    }
}
