import Testing
@testable import RawViewCore

@Suite struct ScientificTypographyTests {

    @Test func convertsOhmAndMetricOhmShorthands() {
        #expect(ScientificTypography.format("ohm") == "Ω")
        #expect(ScientificTypography.format("\\ohm") == "Ω")
        #expect(ScientificTypography.format("kohm") == "kΩ")
        #expect(ScientificTypography.format("100 kohm") == "100 kΩ")
        #expect(ScientificTypography.format("Mohm") == "MΩ")
        #expect(ScientificTypography.format("mohm") == "mΩ")
        #expect(ScientificTypography.format("uohm") == "μΩ")
    }

    @Test func convertsMicroAndGreekLetters() {
        #expect(ScientificTypography.format("mu") == "μ")
        #expect(ScientificTypography.format("\\mu") == "μ")
        #expect(ScientificTypography.format("uA") == "μA")
        #expect(ScientificTypography.format("um") == "μm")
        #expect(ScientificTypography.format("us") == "μs")
        #expect(ScientificTypography.format("alpha") == "α")
        #expect(ScientificTypography.format("\\beta") == "β")
        #expect(ScientificTypography.format("gamma") == "γ")
        #expect(ScientificTypography.format("Delta") == "Δ")
        #expect(ScientificTypography.format("\\theta") == "θ")
    }

    @Test func convertsPowersAndSuperscripts() {
        #expect(ScientificTypography.format("cm^-1") == "cm⁻¹")
        #expect(ScientificTypography.format("mu cm^-1") == "μ cm⁻¹")
        #expect(ScientificTypography.format("mA/cm^2") == "mA/cm²")
        #expect(ScientificTypography.format("s^-1") == "s⁻¹")
        #expect(ScientificTypography.format("10^3") == "10³")
        #expect(ScientificTypography.format("m^2/s") == "m²/s")
        #expect(ScientificTypography.format("^{-2}") == "⁻²")
    }

    @Test func convertsSubscripts() {
        #expect(ScientificTypography.format("E_p") == "Eₚ")
        #expect(ScientificTypography.format("Delta E_p") == "Δ Eₚ")
        #expect(ScientificTypography.format("I_0") == "I₀")
        #expect(ScientificTypography.format("V_{1}") == "V₁")
    }

    @Test func convertsDegreesAndSpecialSymbols() {
        #expect(ScientificTypography.format("degC") == "°C")
        #expect(ScientificTypography.format("\\degC") == "°C")
        #expect(ScientificTypography.format("deg") == "°")
        #expect(ScientificTypography.format("Angstrom") == "Å")
        #expect(ScientificTypography.format("\\pm") == "±")
        #expect(ScientificTypography.format("\\times") == "×")
    }

    @Test func preservesUnrelatedWords() {
        #expect(ScientificTypography.format("counts") == "counts")
        #expect(ScientificTypography.format("column") == "column")
        #expect(ScientificTypography.format("amount") == "amount")
        #expect(ScientificTypography.format("cycle") == "cycle")
    }

    @Test func formatsCombinedAxisTitlesWithUnits() {
        #expect(ScientificTypography.format("Potential applied (V)") == "Potential applied (V)")
        #expect(ScientificTypography.format("Potential (muV)") == "Potential (μV)")
        #expect(ScientificTypography.format("Current (mA/cm^2)") == "Current (mA/cm²)")
        #expect(ScientificTypography.format("Resistance (ohm)") == "Resistance (Ω)")
        #expect(ScientificTypography.format("Wavenumber (cm^-1)") == "Wavenumber (cm⁻¹)")
    }

    @Test func unitCategoriesArePopulated() {
        #expect(!ScientificTypography.unitCategories.isEmpty)
        #expect(ScientificTypography.unitCategories.contains(where: { $0.category.contains("Electrical") }))
    }
}
