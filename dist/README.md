# ConvertSIE

A tool for converting [SIE](https://github.com/efollman/libsie-zig) data files to HDF5, ASCII, CSV, Excel, Vector-style ASCII, or J1939 CAN-error CSV.

## Supported Output Formats

| Extension | Format |
|---|---|
| `.h5` / `.hdf5` | HDF5 |
| `.txt` | ASCII text (tab-separated) |
| `.csv` | CSV |
| `.xlsx` | Excel 2007+ |
| `.asc` | Vector-style CAN ASCII (raw CAN channels only) |
| `.csv` (`--can-err`) | J1939 DM1 active-DTC extraction (raw CAN channels only) |

The output format is chosen automatically from the file extension. Use
`--vector-asc` or `--can-err` to disambiguate when the extension alone is not
enough.

## CLI Usage

```
convertsie [--vector-asc | --can-err] <input.sie> <output.[h5|txt|csv|xlsx|asc]>
```

Examples:

```
convertsie recording.sie recording.h5
convertsie recording.sie recording.txt
convertsie recording.sie recording.csv
convertsie recording.sie recording.xlsx
convertsie recording.sie recording.asc
convertsie --can-err recording.sie CANErr-recording.csv
```

## GUI Usage (Windows only)

Launch `convertsie-gui.exe`. The GUI provides:

- Drag-and-drop or browse for `.sie` input files
- Six format checkboxes (H5, TXT, CSV, XLSX, Vector Style ASCII, J1939 CAN Errors)
- Automatic output filenames (`Vector-<name>.asc`, `CANErr-<name>.csv`, …)
- Persisted selections in `%APPDATA%\ConvertSIE\config.bin`
- Automatic Windows light/dark theme detection
- Opt-in UTF-8 debug console (bottom-right link)

## Author

Evan Follman

## Source Code

https://github.com/efollman/ConvertSIE

## License

MIT — see `LICENSE`.
