import Foundation

@main
struct GenericTableReaderTests {
    static func main() {
        print("Running GenericTableReaderTests...")

        let enduranceURL = URL(fileURLWithPath: "/Users/tai/research-projects/active-projects/test/data/raw/sample_endurance.csv")
        let ramanURL = URL(fileURLWithPath: "/Users/tai/research-projects/active-projects/test/data/raw/sample_raman.txt")

        // 1. Test CSV inspection
        do {
            let enduranceInspection = try GenericTableReader.inspect(url: enduranceURL)
            assert(enduranceInspection.delimiter == ",", "Expected comma delimiter, got \(enduranceInspection.delimiter)")
            assert(enduranceInspection.decimalSeparator == ".", "Expected dot decimal separator, got \(enduranceInspection.decimalSeparator)")
            assert(enduranceInspection.columnNames.count >= 2, "Expected at least 2 columns, got \(enduranceInspection.columnNames.count)")
            assert(enduranceInspection.columnNames[0] == "cycle", "Expected first column 'cycle', got \(enduranceInspection.columnNames[0])")
            assert(enduranceInspection.totalRows > 10, "Expected >10 rows, got \(enduranceInspection.totalRows)")
            print("✓ CSV inspection passed (\(enduranceInspection.columnNames.count) cols, \(enduranceInspection.totalRows) rows)")

            // Test CSV load measurement
            let measurement = try GenericTableReader.loadMeasurement(url: enduranceURL, sourceID: "sample_endurance.csv", xColumnIndex: 0, yColumnIndex: 1)
            let xChannel = measurement.channel(named: measurement.view.x ?? "")
            let yChannel = measurement.channel(named: measurement.view.y?.first ?? "")
            assert(xChannel != nil && yChannel != nil, "Expected X and Y channels present")
            assert(xChannel?.values.count == enduranceInspection.totalRows, "Point count mismatch: \(xChannel?.values.count ?? 0) vs \(enduranceInspection.totalRows)")
            assert(xChannel?.label == "cycle", "Expected X label cycle, got \(xChannel?.label ?? "")")
            print("✓ CSV loadMeasurement passed (\(xChannel?.values.count ?? 0) rows)")
        } catch {
            fatalError("Failed CSV inspection: \(error)")
        }

        // 2. Test Raman TSV with decimal comma and # comments
        do {
            let ramanInspection = try GenericTableReader.inspect(url: ramanURL)
            assert(ramanInspection.delimiter == "\t", "Expected tab delimiter, got \(ramanInspection.delimiter)")
            assert(ramanInspection.decimalSeparator == ",", "Expected comma decimal separator, got \(ramanInspection.decimalSeparator)")
            assert(ramanInspection.columnNames.count == 2, "Expected 2 columns for Raman, got \(ramanInspection.columnNames.count)")
            assert(ramanInspection.totalRows > 100, "Expected >100 rows, got \(ramanInspection.totalRows)")
            print("✓ Raman TSV inspection passed (\(ramanInspection.totalRows) rows)")

            // Test Raman load measurement
            let measurement = try GenericTableReader.loadMeasurement(url: ramanURL, sourceID: "sample_raman.txt", xColumnIndex: 0, yColumnIndex: 1)
            let xChannel = measurement.channel(named: measurement.view.x ?? "")
            let yChannel = measurement.channel(named: measurement.view.y?.first ?? "")
            assert(xChannel != nil && yChannel != nil, "Expected X and Y channels present")
            assert(xChannel?.values.count == ramanInspection.totalRows, "Point count mismatch")
            if let firstX = xChannel?.values.first, let val = firstX {
                assert(val > 800.0, "Expected first x > 800, got \(val)")
                print("✓ Raman loadMeasurement passed (\(xChannel?.values.count ?? 0) rows, first x=\(val))")
            } else {
                fatalError("Missing first x value")
            }
        } catch {
            fatalError("Failed Raman inspection: \(error)")
        }

        print("All GenericTableReaderTests passed successfully!")
    }
}
