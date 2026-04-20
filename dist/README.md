# ExportSIE

A tool for exporting [SIE](https://github.com/efollman/libsie-zig) data files to HDF5, ASCII, CSV, or Excel.

## Supported Output Formats

| Extension | Format |
|---|---|
| `.h5` / `.hdf5` | HDF5 |
| `.txt` | ASCII text (tab-separated) |
| `.csv` | CSV |
| `.xlsx` | Excel 2007+ |

The output format is chosen automatically from the output file extension.

## CLI Usage

```
exportsie <input.sie> <output.[h5|txt|csv|xlsx]>
```

Examples:

```
exportsie recording.sie recording.h5
exportsie recording.sie recording.txt
exportsie recording.sie recording.csv
exportsie recording.sie recording.xlsx
```

## GUI Usage (Windows only)

Launch `exportsie-gui.exe`. The GUI provides:

- Drag-and-drop or browse for `.sie` input files
- Output file selection with all four export formats
- Automatic Windows light/dark theme detection
- Export status display

## Author

Evan Follman

## Source Code

https://github.com/efollman/ExportSIE

## License

MIT — see `LICENSE`.
