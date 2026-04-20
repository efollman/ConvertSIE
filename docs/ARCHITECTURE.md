# Architecture

This document describes the project structure, module responsibilities, and data flow of ExportSIE.

## Project Structure

```
ExportSIE/
├── build.zig                 # Build system configuration
├── build.zig.zon             # Package manifest and dependencies
├── docs/                     # Documentation
│   ├── ARCHITECTURE.md       # This file
│   ├── HDF5_BUILD.md
│   └── CROSS_COMPILATION.md
├── hdf5_config/              # Custom HDF5 build configuration
│   ├── H5pubconf.h           # Cross-platform config header
│   └── H5build_settings.c    # Stub for H5build_settings[] symbol
├── src/
│   ├── main.zig              # CLI entry point (dispatches by output extension)
│   ├── gui.zig               # Windows GUI application (raylib/raygui)
│   ├── root.zig              # Library module — re-exports all exporters
│   ├── common.zig            # Shared SIE reading and data structures
│   ├── hdf5.zig              # Zig bindings for the HDF5 C API
│   ├── hdf5_export.zig       # HDF5 export (two-pass pipeline)
│   ├── ascii_export.zig      # ASCII text export (tags + tab-separated data)
│   ├── csv_export.zig        # CSV export (side-by-side channel tables)
│   └── xlsx_export.zig       # XLSX export (pure Zig ZIP writer + Open XML)
└── test/
    └── data/                 # Test SIE files
```

## Modules

### `src/main.zig` — CLI Entry Point

Parses command-line arguments (`<input.sie> <output.[h5|txt|csv|xlsx]>`), determines the export format from the output file extension, and dispatches to the corresponding exporter module. Reports errors to stderr.

### `src/gui.zig` — Windows GUI (raylib/raygui)

Windows-only graphical interface built with raylib and raygui. Provides:
- Input file selection (browse dialog or drag-and-drop)
- Output file selection (save dialog with format filters)
- Export button with status display
- Automatic Windows light/dark theme detection
- System font loading with fallbacks (Segoe UI → Tahoma → Arial)

### `src/root.zig` — Library Module

Re-exports all exporter modules as `ExportSIE`. This is the named module used by both `main.zig` and `gui.zig`.

### `src/common.zig` — Shared Data Reader

Provides `ExportData` (an in-memory representation of all SIE channel data) and `readSieFile()` which opens a SIE file via libsie, extracts metadata tags, and reads all channel dimension data into memory. Used by CSV and XLSX exporters.

### `src/hdf5_export.zig` — HDF5 Export

Implements the two-pass HDF5 conversion pipeline:

**Pass 1 — Structure:** Creates HDF5 groups (tests, channels) with tag attributes and chunked datasets for each dimension.

**Pass 2 — Data:** Streams data through spigots and appends float64 data to datasets.

### `src/ascii_export.zig` — ASCII Export

Writes all SIE metadata (file, test, channel, dimension tags) followed by tab-separated channel data. Streams data directly to the output file.

### `src/csv_export.zig` — CSV Export

Reads all channel data into memory via `common.readSieFile()`, then writes:
1. General test info rows (test name, start time)
2. Per-channel header rows (name, units, sample rate)
3. Dimension name row (column headers)
4. Data rows with channels as side-by-side tables separated by blank columns

### `src/xlsx_export.zig` — XLSX Export

Same layout as CSV but in Excel 2007+ format. Contains:
- A minimal ZIP writer (STORE method, no compression) for producing the `.xlsx` package
- XML generation for Open XML Spreadsheet markup
- Cell reference helpers (column index → Excel letter: A, B, …, Z, AA, …)
- Bold style support for header cells

### `src/hdf5.zig` — HDF5 C Bindings

Zig-idiomatic wrappers around the HDF5 C API via manual `extern` declarations (no `@cImport`).

## Data Flow

```
                    ┌──────────┐
                    │ .sie file │
                    └────┬─────┘
                         │ libsie
                    ┌────▼─────┐
                    │  SieFile  │
                    └────┬─────┘
           ┌─────────┬──┴──┬─────────┐
           │         │     │         │
     ┌─────▼───┐ ┌───▼──┐ ┌▼────┐ ┌──▼───┐
     │ HDF5    │ │ ASCII│ │ CSV │ │ XLSX │
     │ export  │ │export│ │exprt│ │export│
     └────┬────┘ └──┬───┘ └──┬──┘ └──┬───┘
          │         │        │       │
     ┌────▼───┐  ┌──▼──┐ ┌──▼──┐ ┌──▼───┐
     │ .h5    │  │.txt │ │.csv │ │.xlsx │
     └────────┘  └─────┘ └─────┘ └──────┘
```

## Build System

The `ExportSIE` named module (root: `src/root.zig`) is shared by both the CLI executable and the Windows GUI. HDF5 is compiled from C source and linked statically into the final binaries. The raylib dependency is lazy — only fetched when building the GUI on Windows.
