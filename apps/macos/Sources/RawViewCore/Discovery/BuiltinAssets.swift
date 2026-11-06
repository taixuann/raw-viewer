import Foundation

public enum BuiltinAssets {
    public static let defaultConfigYAML: String = """
schema_version: 1
data_root: "data/raw"
default_view: "tree"
default_preset: "nature-single"
grammar:
  id: standard-scientific
  name: Standard Filename Pattern
  template: "{date}_{device}.{application-mode}_[{device-id}]_{library}.{study}_r.[{remarks}]_f.[{flags}]_{index}"
  fields:
    - name: date
      role: datetime
      type: datetime
      format: DDMMYY-HHmmSS
      optional: false
    - name: device
      role: instrument
      type: string
      optional: false
    - name: application-mode
      role: mode
      type: string
      optional: false
    - name: device-id
      role: device
      type: string
      optional: false
    - name: library
      role: library
      type: string
      optional: false
    - name: study
      role: category
      type: string
      optional: false
    - name: remarks
      role: remarks
      type: string
      optional: true
    - name: flags
      role: flags
      type: string
      optional: true
    - name: index
      role: batch
      type: number
      format: "001"
      optional: true
"""

    public static let keithley2400YAML: String = """
schema_version: 4
id: usth/keithley-2400
revision: 1
instrument:
  id: keithley-2400
  name: Keithley 2400 SourceMeter
  vendor: Keithley Instruments
  model: "2400"
variants:
  dual-sweep:
    when:
      content_contains_any:
        - LabVIEW Measurement
        - Untitled
        - Untitled 1
    format:
      kind: tabular
      extensions: [".txt", ".lvm", ".csv"]
      delimiter: "\\t"
      encoding: [utf-8, windows-1252, iso-8859-1]
    rows:
      names_prefix: X_Value
      data_prefix: ""
    metadata:
      - row: 10
        key: Date
        type: string
      - row: 11
        key: Time
        type: string
    columns:
      voltage:
        role: channel
        header: Untitled
        quantity: voltage
        unit: V
        label: Voltage
      current:
        role: channel
        header: "Untitled 1"
        quantity: current
        unit: A
        label: Current
      timestamp:
        role: progression
        type: time
        behavior: continuous
        header: "Untitled 2"
        quantity: time
        unit: s
        label: Time
    plot:
      x: voltage
      y: [current]
"""

    public static let autolabUsthYAML: String = """
schema_version: 4
id: usth/autolab-usth
revision: 1
instrument:
  id: autolab-usth
  name: Autolab USTH
variants:
  cv:
    when:
      content_contains_any:
        - Potential applied (V)
        - Potential_applied_(V)
        - Potential_applied(V)
      filename_contains_all:
        - autolab-usth
        - .cv_
    format:
      kind: first-row-header
      extensions: [".txt"]
      delimiter: ";"
      decimal: ","
      encoding: [utf-8, windows-1252, iso-8859-1]
    rows:
      header: 1
      data_start: 2
    metadata: []
    columns:
      applied_voltage:
        role: skip
        header: Potential applied (V)
        aliases: ["Potential_applied_(V)", "Potential_applied(V)"]
        quantity: voltage
        unit: V
      time:
        role: skip
        header: Time (s)
        aliases: ["Time_(s)"]
        quantity: time
        unit: s
      current:
        role: channel
        header: WE(1).Current (A)
        aliases: ["WE(1)_Current(A)", "WE(1).Current(A)", "WE(1)_Current (A)"]
        quantity: current
        unit: A
        label: Current
      electrode_potential:
        role: channel
        header: WE(1).Potential (V)
        aliases: ["WE(1)_Potential(V)", "WE(1).Potential(V)", "WE(1)_Potential (V)"]
        quantity: voltage
        unit: V
        label: Potential
      scan:
        role: progression
        type: custom
        behavior: discrete
        header: Scan
        quantity: index
        unit: ""
        label: Scan
      index:
        role: skip
        header: Index
        quantity: index
        unit: ""
      q_plus:
        role: skip
        header: Q+
        quantity: charge
        unit: C
      q_minus:
        role: skip
        header: Q-
        quantity: charge
        unit: C
      current_range:
        role: skip
        header: Current range
        quantity: current
        unit: A
    plot:
      x: electrode_potential
      y: [current]
  ca:
    when:
      content_contains_any:
        - Time (s)
        - Time_(s)
      filename_contains_all:
        - autolab-usth
        - .ca_
    format:
      kind: first-row-header
      extensions: [".txt"]
      delimiter: ";"
      encoding: [utf-8, windows-1252, iso-8859-1]
    rows:
      header: 1
      data_start: 2
    metadata: []
    columns:
      time:
        role: channel
        header: Time (s)
        aliases: ["Time_(s)"]
        quantity: time
        unit: s
        label: Time
      electrode_potential:
        role: skip
        header: WE(1).Potential (V)
        aliases: ["WE(1)_Potential(V)", "WE(1).Potential(V)"]
        quantity: voltage
        unit: V
      current:
        role: channel
        header: WE(1).Current (A)
        aliases: ["WE(1)_Current(A)", "WE(1).Current(A)"]
        quantity: current
        unit: A
        label: Current
      corrected_time:
        role: skip
        header: Corrected time (s)
        aliases: ["Corrected_time_(s)"]
        quantity: time
        unit: s
      index:
        role: skip
        header: Index
        quantity: index
        unit: ""
      current_range:
        role: skip
        header: Current range
        quantity: current
        unit: A
      overload:
        role: skip
        header: Overload
        quantity: flag
        unit: ""
    plot:
      x: time
      y: [current]
  eis:
    when:
      content_contains_any:
        - Frequency (Hz)
      filename_contains_all:
        - autolab-usth
        - .eis_
    format:
      kind: first-row-header
      extensions: [".txt"]
      delimiter: ";"
      decimal: ","
      encoding: [utf-8, windows-1252, iso-8859-1]
    rows:
      header: 1
      data_start: 2
    metadata: []
    columns:
      index:
        role: skip
        header: Index
        quantity: index
        unit: ""
      frequency:
        role: channel
        header: Frequency (Hz)
        aliases: ["Frequency_(Hz)"]
        quantity: frequency
        unit: Hz
        label: Frequency
      z_prime:
        role: channel
        header: Z' (Ω)
        aliases: ["Z'_(Ω)", "Z'_(\\u03a9)"]
        quantity: impedance_real
        unit: ohm
        label: Z'
      z_double_prime:
        role: channel
        header: -Z'' (Ω)
        aliases: ["-Z''_(Ω)", "-Z''_(\\u03a9)"]
        quantity: impedance
        unit: ohm
        label: -Z''
      z_magnitude:
        role: channel
        header: Z (Ω)
        aliases: ["Z_(Ω)", "Z_(\\u03a9)"]
        quantity: impedance
        unit: ohm
        label: |Z|
      phase:
        role: channel
        header: -Phase (°)
        aliases: ["-Phase_(°)", "-Phase_(\\u00b0)"]
        quantity: phase
        unit: deg
        label: -Phase
      time:
        role: skip
        header: Time (s)
        aliases: ["Time_(s)"]
        quantity: time
        unit: s
    plot:
      x: z_prime
      y: [z_double_prime]
  cv_2col:
    when:
      content_contains_any:
        - WE(1)_potential(V)
        - WE(1)_current(A)
      filename_contains_all:
        - autolab-usth
        - .cv_
    format:
      kind: first-row-header
      extensions: [".txt"]
      delimiter: ";"
      encoding: [utf-8, windows-1252, iso-8859-1]
    rows:
      header: 1
      data_start: 2
    metadata: []
    columns:
      electrode_potential:
        role: channel
        header: WE(1)_potential(V)
        aliases: ["WE(1).Potential (V)", "WE(1).Potential(V)"]
        quantity: voltage
        unit: V
        label: Potential
      current:
        role: channel
        header: WE(1)_current(A)
        aliases: ["WE(1).Current (A)", "WE(1).Current(A)"]
        quantity: current
        unit: A
        label: Current
    plot:
      x: electrode_potential
      y: [current]
"""

    public static let horibaLabramYAML: String = """
schema_version: 4
id: usth/horiba-labram
revision: 1
instrument:
  id: horiba-labram
  name: Horiba LabRAM HR Evolution Raman Spectrometer
variants:
  raman:
    when:
      content_contains_any:
        - raman_shift;intensity
        - Raman_shift;intensity
      filename_contains_all:
        - horiba-labram
    format:
      kind: first-row-header
      extensions: [".txt"]
      delimiter: ";"
      encoding: [utf-8, windows-1252, iso-8859-1]
    rows:
      header: 1
      data_start: 2
    metadata: []
    columns:
      wavenumber:
        role: channel
        header: Raman_shift
        aliases: [raman_shift]
        quantity: wavenumber
        unit: cm-1
        label: Raman shift
      intensity:
        role: channel
        header: intensity
        quantity: intensity
        unit: counts
        label: Intensity
    plot:
      x: wavenumber
      y: [intensity]
"""

    public static let iopHanoiYAML: String = """
schema_version: 4
id: usth/iop-hanoi
revision: 1
instrument:
  id: iop-hanoi
  name: IOP Hanoi UV-Vis
variants:
  uv-vis:
    when:
      content_contains_any:
        - Wavelength_nm
        - wavelength (nm)
        - T%
        - "%t"
        - transmission (%)
      filename_contains_all:
        - iop-hanoi.uv-vis_
    format:
      kind: first-row-header
      extensions: [".txt", ".csv"]
      delimiter: ","
      encoding: [utf-8, windows-1252, iso-8859-1]
    rows:
      header: 1
      data_start: 2
    metadata: []
    columns:
      wavelength:
        role: channel
        header: Wavelength_nm
        aliases: ["wavelength (nm)"]
        quantity: wavelength
        unit: nm
        label: Wavelength
      transmittance:
        role: channel
        header: T%
        aliases: ["%t", "transmission (%)"]
        quantity: transmittance
        unit: "%"
        label: Transmittance
    plot:
      x: wavelength
      y: [transmittance]
"""

    public static let builtinProfiles: [(id: String, relativePath: String, yaml: String)] = [
        ("usth/keithley-2400", "profiles/usth/keithley-2400.yaml", keithley2400YAML),
        ("usth/autolab-usth", "profiles/usth/autolab-usth.yaml", autolabUsthYAML),
        ("usth/horiba-labram", "profiles/usth/horiba-labram.yaml", horibaLabramYAML),
        ("usth/iop-hanoi", "profiles/usth/iop-hanoi.yaml", iopHanoiYAML),
    ]

    public static func defaultGrammarCatalog() -> FilenameGrammarCatalog {
        guard let node = try? YAMLParser.parse(defaultConfigYAML, allowIndentlessSequences: false),
              let grammarNode = node.value(for: "grammar"),
              let grammar = try? FilenameGrammarEngine.parseSingleGrammar(node: grammarNode) else {
            fatalError("bundled default-config.yaml grammar is valid")
        }
        return FilenameGrammarCatalog(grammars: [grammar])
    }
}
