import Testing
@testable import RawViewCore

// Issue #113: token color comes from type and role, never from the token name.

@Test func datetimeTokenIsTimeFamilyWhateverItsRole() {
    #expect(GrammarTokenFamily(role: "Date", type: .datetime) == .time)
    #expect(GrammarTokenFamily(role: nil, type: .datetime) == .time)
}

@Test func instrumentAndDeviceRolesShareTheInstrumentFamily() {
    #expect(GrammarTokenFamily(role: "instrument", type: .string) == .instrument)
    #expect(GrammarTokenFamily(role: "Device", type: .string) == .instrument)
}

@Test func modeAndCategoryRolesShareTheMethodFamily() {
    #expect(GrammarTokenFamily(role: "mode", type: .string) == .method)
    #expect(GrammarTokenFamily(role: "application-mode", type: .string) == .method)
    #expect(GrammarTokenFamily(role: "Category", type: .string) == .method)
}

@Test func batchRoleAndNumberTypeShareTheSampleFamily() {
    #expect(GrammarTokenFamily(role: "batch", type: .number) == .sample)
    #expect(GrammarTokenFamily(role: nil, type: .number) == .sample)
}

@Test func remarksRoleIsItsOwnFamily() {
    #expect(GrammarTokenFamily(role: "remarks", type: .string) == .remarks)
}

@Test func unknownRoleAndStringTypeIsNeutral() {
    #expect(GrammarTokenFamily(role: "Lot", type: .string) == .neutral)
    #expect(GrammarTokenFamily(role: nil, type: .string) == .neutral)
}
