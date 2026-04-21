# Architecture

This document describes the project structure, module responsibilities, and data flow of ConvertSIE.

## Project Structure

```
ConvertSIE/
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
│   ├── main.zig              # CLI entry point (dispatches by extension / flag)
│   ├── gui.zig               # Windows GUI application (raylib/raygui)
│   ├── root.zig              # Library module — re-exports all exporters
│   ├── common.zig            # Shared SIE reading and data structures
│   ├── hdf5.zig              # Zig bindings for the HDF5 C API
│   ├── hdf5_export.zig       # HDF5 export (two-pass pipeline)
│   ├── ascii_export.zig      # ASCII text export (tags + tab-separated data)
│   ├── csv_export.zig        # CSV export (side-by-side channel tables)
│   ├── xlsx_export.zig       # XLSX export (pure Zig ZIP writer + Open XML)
│   ├── vector_asc_export.zig # Vector-style CAN ASCII export (CAN channels only)
│   ├── can_err.zig           # J1939 DM1 DTC parser (ported from CanErrFindr-Zig, MIT)
│   └── can_err_export.zig    # SIE→CANErr CSV wrapper
└── test/
    └── data/                 # Test SIE files
```

## Modules

### `src/main.zig` — CLI Entry Point

Parses command-line arguments
(`[--vector-asc | --can-err] <input.sie> <output.[h5|txt|csv|xlsx|asc]>`),
determines the export format from the file extension (or force flag), and
dispatches to the corresponding exporter module. Reports errors to stderr.

### `src/gui.zig` — Windows GUI (raylib/raygui)

Windows-only graphical interface built with raylib and raygui. Provides:
- Input file selection (browse dialog or drag-and-drop)
- Six format checkboxes (H5, TXT, CSV, XLSX, Vector ASC, J1939 CAN Errors) with
  auto-generated output filenames (`Vector-<name>.asc`, `CANErr-<name>.csv`, …)
- Persistent selection state in `%APPDATA%\ConvertSIE\config.bin`
- Export button with status display
- Automatic Windows light/dark theme detection
- System font loading with fallbacks (Segoe UI → Tahoma → Arial)
- Opt-in UTF-8 debug console (bottom-right corner link); compiled with the
  Windows subsystem so no console appears by default

### `src/root.zig` — Library Module

Re-exports all exporter modules as `ConvertSIE`: `hdf5_export`, `ascii_export`,
`csv_export`, `xlsx_export`, `vector_asc_export`, `can_err_export`, `can_err`,
and `common`. This is the named module used by both `main.zig` and `gui.zig`.

### `src/common.zig` — Shared Data Reader

Provides `ExportData` (an in-memory representation of all SIE channel data) and
`readSieFile()` which opens a SIE file via libsie, extracts metadata tags, and
reads all channel dimension data into memory. Used by CSV and XLSX exporters.

### `src/hdf5_export.zig` — HDF5 Export

Two-pass HDF5 conversion pipeline:

**Pass 1 — Structure:** Creates HDF5 groups (tests, channels) with tag attributes and chunked datasets for each dimension.

**Pass 2 — Data:** Streams data through spigots and appends float64 data to datasets.

### `src/ascii_export.zig` — ASCII Export

Writes all SIE metadata (file, test, channel, dimension tags) followed by tab-separated channel data. Streams data directly to the output file.

### `src/csv_export.zig` — CSV Export

Reads all channel data into memory via `common.readSieFile()`, then writes
test-info rows, per-channel header rows (name, units, sample rate), a dimension
name row, and side-by-side data blocks separated by blank columns.

### `src/xlsx_export.zig` — XLSX Export

Same layout as CSV but in Excel 2007+ format. Contains a minimal pure-Zig ZIP
writer (STORE method, no compression), Open XML generation, cell-reference
helpers, and bold-style header support. Splits across multiple sheets when row
count exceeds Excel's 1,048,576-row limit.

### `src/vector_asc_export.zig` — Vector-Style CAN ASCII

CAN-only exporter. Iterates tests and channels, filters to raw-CAN channels
(`data_type` / `somat:data_format` = `message_can`), and emits a Vector
CANalyzer-compatible text log of timestamped frames. Skips file creation when
no CAN channels are present.

### `src/can_err.zig` — J1939 DM1 Parser

Parses J1939 DM1 (PGN 0xFECA) messages from raw CAN streams and yields active
DTC records (SPN / FMI / OC). Adapted from
[CanErrFindr-Zig](https://github.com/efollman/CanErrFindr-Zig) (MIT,
attribution preserved in the file header). Exposes `parseCan`, `canErrFindr`,
`writeCsv`, and `writeMultiChannelCsv`.

### `src/can_err_export.zig` — J1939 CAN Errors CSV

Thin SIE→CSV wrapper around `can_err.zig`. Follows the same filter/stream
pattern as `vector_asc_export.zig`. Produces one combined CSV across multiple
CAN channels (with a channel column); skips output entirely when no CAN
channels exist.

### `src/hdf5.zig` — HDF5 C Bindings

Zig-idiomatic wrappers around the HDF5 C API via manual `extern` declarations (no `@cImport`).

## Data Flow

```
                         ┌───────────┐
                         │ .sie file │
                         └─────┬─────┘
                               │ libsie
                         ┌─────▼─────┐
                         │  SieFile  │
                         └─────┬─────┘
        ┌─────────┬───────┬────┴───┬──────────────┬──────────────┐
        │         │       │        │              │              │
   ┌────▼───┐ ┌───▼──┐ ┌──▼──┐ ┌───▼───┐ ┌────────▼───────┐ ┌────▼─────┐
   │  HDF5  │ │ ASCII│ │ CSV │ │ XLSX  │ │ Vector-ASC CAN │ │ J1939 DM1│
   │ export │ │export│ │exprt│ │export │ │    export      │ │  export  │
   └────┬───┘ └──┬───┘ └──┬──┘ └───┬───┘ └────────┬───────┘ └────┬─────┘
        │        │        │        │              │              │
   ┌────▼───┐ ┌──▼──┐ ┌──▼──┐ ┌────▼───┐ ┌────────▼───────┐ ┌────▼─────┐
   │  .h5   │ │.txt │ │.csv │ │ .xlsx  │ │ Vector-*.asc   │ │CANErr-*.csv│
   └────────┘ └─────┘ └─────┘ └────────┘ └────────────────┘ └──────────┘
```

## Build System

The `ConvertSIE` named module (root: `src/root.zig`) is shared by both the CLI
executable (`convertsie`) and the Windows GUI (`convertsie-gui`). HDF5 is
compiled from C source and linked statically into the final binaries. The
raylib dependency is lazy — only fetched when building the GUI on Windows. The
GUI executable uses the Windows subsystem so no console window opens at
startup; a debug console can be toggled on demand from the UI.
