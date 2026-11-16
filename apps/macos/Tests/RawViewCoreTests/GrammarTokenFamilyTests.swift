import Testing
@testable import RawViewCore

// Issue #113: token color comes from type and role, never from the token name.
// Roles use the labels the engine stores, such as "Device ID" from the standard grammar.

@Test func datetimeTokenIsTimeFamilyWhateverItsRole() {
    #expect(GrammarTokenFamily(role: "Date & Time", type: .datetime) == .time)
    #expect(GrammarTokenFamily(role: nil, type: .datetime) == .time)
}

@Test func instrumentRoleIsInstrumentFamily() {
    #expect(GrammarTokenFamily(role: "Instrument", type: .string) == .instrument)
}

@Test func deviceRoleLabelIsDeviceFamily() {
    #expect(GrammarTokenFamily(role: "Device ID", type: .string) == .device)
    #expect(GrammarTokenFamily(role: "device", type: .string) == .device)
}

@Test func modeRoleIsModeFamilyIncludingApplicationMode() {
    #expect(GrammarTokenFamily(role: "Mode", type: .string) == .mode)
    #expect(GrammarTokenFamily(role: "application-mode", type: .string) == .mode)
}

@Test func categoryRoleIsCategoryFamily() {
    #expect(GrammarTokenFamily(role: "Category", type: .string) == .category)
}

@Test func batchRoleAndNumberTypeShareTheBatchFamily() {
    #expect(GrammarTokenFamily(role: "Batch", type: .number) == .batch)
    #expect(GrammarTokenFamily(role: nil, type: .number) == .batch)
}

@Test func remarksRoleIsRemarksFamily() {
    #expect(GrammarTokenFamily(role: "Remarks", type: .string) == .remarks)
}

@Test func unknownRoleAndStringTypeIsNeutral() {
    #expect(GrammarTokenFamily(role: "Study", type: .string) == .neutral)
    #expect(GrammarTokenFamily(role: "flags", type: .string) == .neutral)
    #expect(GrammarTokenFamily(role: nil, type: .string) == .neutral)
}
