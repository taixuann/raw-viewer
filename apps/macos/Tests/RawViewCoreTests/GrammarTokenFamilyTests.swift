import Testing
@testable import RawViewCore

// Issue #113: token color comes from type and role, never from the token name.
// Roles use the labels the engine stores, such as "Device ID" from the standard grammar.

@Test(.globalConfigIsolated) func datetimeTokenIsTimeFamilyWhateverItsRole() {
    #expect(GrammarTokenFamily(role: "Date & Time", type: .datetime) == .time)
    #expect(GrammarTokenFamily(role: nil, type: .datetime) == .time)
}

@Test(.globalConfigIsolated) func instrumentRoleIsInstrumentFamily() {
    #expect(GrammarTokenFamily(role: "Instrument", type: .string) == .instrument)
}

@Test(.globalConfigIsolated) func deviceRoleLabelIsDeviceFamily() {
    #expect(GrammarTokenFamily(role: "Device ID", type: .string) == .device)
    #expect(GrammarTokenFamily(role: "device", type: .string) == .device)
}

@Test(.globalConfigIsolated) func modeRoleIsModeFamilyIncludingApplicationMode() {
    #expect(GrammarTokenFamily(role: "Mode", type: .string) == .mode)
    #expect(GrammarTokenFamily(role: "application-mode", type: .string) == .mode)
}

@Test(.globalConfigIsolated) func categoryRoleIsCategoryFamily() {
    #expect(GrammarTokenFamily(role: "Category", type: .string) == .category)
}

@Test(.globalConfigIsolated) func batchRoleAndNumberTypeShareTheBatchFamily() {
    #expect(GrammarTokenFamily(role: "Batch", type: .number) == .batch)
    #expect(GrammarTokenFamily(role: nil, type: .number) == .batch)
}

@Test(.globalConfigIsolated) func remarksRoleIsRemarksFamily() {
    #expect(GrammarTokenFamily(role: "Remarks", type: .string) == .remarks)
}

@Test(.globalConfigIsolated) func unknownRoleAndStringTypeIsNeutral() {
    #expect(GrammarTokenFamily(role: "Study", type: .string) == .neutral)
    #expect(GrammarTokenFamily(role: "flags", type: .string) == .neutral)
    #expect(GrammarTokenFamily(role: nil, type: .string) == .neutral)
}
