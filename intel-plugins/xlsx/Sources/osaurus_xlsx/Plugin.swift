import Foundation
import OsaurusPluginABI
import OsaurusPluginKit

// MARK: - Plugin Context

private class PluginContext: @unchecked Sendable {
  var workbooks: [String: Workbook] = [:]

  // Tools
  let readXlsx = ReadXlsxTool()
  let getCellValue = GetCellValueTool()
  let listSheets = ListSheetsTool()
  let describeWorkbook = XlsxDescribeWorkbookTool()
  let createXlsx = CreateXlsxTool()
  let writeCells = WriteCellsTool()
  let saveXlsx = SaveXlsxTool()
  let xlsxToCsv = XlsxToCsvTool()
  let csvToXlsx = CsvToXlsxTool()
  let modifyXlsx = ModifyXlsxTool()
}

// MARK: - API Implementation

nonisolated(unsafe) var pluginAPI = PluginEntry.makeAPI(
  version: OsrABIVersion.v2,
  init: {
    let ctx = PluginContext()
    return Unmanaged.passRetained(ctx).toOpaque()
  },
  destroy: { ctxPtr in
    guard let ctxPtr = ctxPtr else { return }
    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
  },
  getManifest: { _ in
    osrMakeCString(xlsxManifestJSON)
  },
  invoke: { ctxPtr, typePtr, idPtr, payloadPtr in
    guard let ctxPtr = ctxPtr,
      let typePtr = typePtr,
      let idPtr = idPtr,
      let payloadPtr = payloadPtr
    else { return nil }

    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let type = String(cString: typePtr)
    let id = String(cString: idPtr)
    let payload = String(cString: payloadPtr)

    guard type == "tool" else {
      return osrMakeCString(Envelope.failure(.invalidArgs, "Unknown capability type: \(type)"))
    }

    let result: String
    switch id {
    case ctx.readXlsx.name:
      result = ctx.readXlsx.run(args: payload, workbooks: &ctx.workbooks)
    case ctx.getCellValue.name:
      result = ctx.getCellValue.run(args: payload, workbooks: &ctx.workbooks)
    case ctx.listSheets.name:
      result = ctx.listSheets.run(args: payload, workbooks: &ctx.workbooks)
    case ctx.describeWorkbook.name:
      result = ctx.describeWorkbook.run(args: payload, workbooks: &ctx.workbooks)
    case ctx.createXlsx.name:
      result = ctx.createXlsx.run(args: payload, workbooks: &ctx.workbooks)
    case ctx.writeCells.name:
      result = ctx.writeCells.run(args: payload, workbooks: &ctx.workbooks)
    case ctx.saveXlsx.name:
      result = ctx.saveXlsx.run(args: payload, workbooks: &ctx.workbooks)
    case ctx.xlsxToCsv.name:
      result = ctx.xlsxToCsv.run(args: payload, workbooks: &ctx.workbooks)
    case ctx.csvToXlsx.name:
      result = ctx.csvToXlsx.run(args: payload, workbooks: &ctx.workbooks)
    case ctx.modifyXlsx.name:
      result = ctx.modifyXlsx.run(args: payload, workbooks: &ctx.workbooks)
    default:
      result = Envelope.failure(.notFound, "Unknown tool: \(id)")
    }

    return osrMakeCString(result)
  }
)

// MARK: - Embedded Manifest

let xlsxManifestJSON = """
  {
    "plugin_id": "osaurus.xlsx",
    "name": "XLSX",
    "version": "1.2.0",
        "description": "Read, create, and modify Excel spreadsheet (.xlsx) files. Supports reading cell data, creating workbooks with multiple sheets, writing cells, formulas, CSV/TSV conversion, and batch modifications.",
        "license": "MIT",
        "authors": [],
        "min_macos": "13.0",
        "min_osaurus": "0.5.0",
        "capabilities": {
          "tools": [
            {
              "id": "read_xlsx",
              "description": "Read an Excel (.xlsx) file and load it into memory. Returns structured cell data for all or a specific sheet. Use the returned workbook_id to reference this workbook in subsequent tool calls.",
              "parameters": {
                "type": "object",
                "properties": {
                  "path": {"type": "string", "description": "Path to the .xlsx file (relative to workspace or absolute)"},
                  "sheet_name": {"type": "string", "description": "Read only this sheet (optional, reads all sheets if omitted)"},
                  "range": {"type": "string", "description": "Read only this cell range, e.g. 'A1:D10' (optional, reads all cells if omitted)"}
                },
                "required": ["path"]
              },
              "requirements": [],
              "permission_policy": "auto"
            },
            {
              "id": "get_cell_value",
              "description": "Get the value of a specific cell or range from an already-loaded workbook. Use read_xlsx first to load the workbook.",
              "parameters": {
                "type": "object",
                "properties": {
                  "workbook_id": {"type": "string", "description": "Workbook ID from read_xlsx or create_xlsx"},
                  "sheet_name": {"type": "string", "description": "Sheet name to read from"},
                  "cell": {"type": "string", "description": "Cell reference, e.g. 'B5'"},
                  "range": {"type": "string", "description": "Range reference, e.g. 'A1:C3'"}
                },
                "required": ["workbook_id", "sheet_name"]
              },
              "requirements": [],
              "permission_policy": "auto"
            },
            {
              "id": "list_sheets",
              "description": "List all sheet names in an Excel (.xlsx) file without reading all cell data.",
              "parameters": {
                "type": "object",
                "properties": {
                  "path": {"type": "string", "description": "Path to the .xlsx file (relative to workspace or absolute)"}
                },
                "required": ["path"]
              },
              "requirements": [],
              "permission_policy": "auto"
            },
            {
              "id": "xlsx_describe_workbook",
              "description": "Describe an Excel (.xlsx) workbook without returning all cell data. Returns sheet names, visibility state, used ranges, row and column counts, formula counts, merged ranges, warnings, and a workbook_id for follow-up calls.",
              "parameters": {
                "type": "object",
                "properties": {
                  "path": {"type": "string", "description": "Path to the .xlsx file (relative to workspace or absolute)"}
                },
                "required": ["path"]
              },
              "requirements": [],
              "permission_policy": "auto"
            },
            {
              "id": "create_xlsx",
              "description": "Create a new workbook in memory with one or more sheets. Each sheet can have optional headers and rows of data. Values are auto-detected as numbers, booleans, or strings. Use save_xlsx to write the workbook to disk.",
              "parameters": {
                "type": "object",
                "properties": {
                  "sheets": {
                    "type": "array",
                    "items": {
                      "type": "object",
                      "properties": {
                        "name": {"type": "string", "description": "Sheet name"},
                        "headers": {"type": "array", "items": {"type": "string"}, "description": "Optional header row"},
                        "rows": {"type": "array", "items": {"type": "array", "items": {"type": "string"}}, "description": "Data rows (2D array of values as strings)"}
                      },
                      "required": ["name"]
                    },
                    "description": "Array of sheet definitions"
                  }
                },
                "required": ["sheets"]
              },
              "requirements": [],
              "permission_policy": "auto"
            },
            {
              "id": "write_cells",
              "description": "Write or update specific cells in a workbook that is already loaded in memory. If the sheet does not exist, it will be created. Invalid cells are skipped and reported in the errors field of the result. Use save_xlsx afterwards to persist changes to disk.",
              "parameters": {
                "type": "object",
                "properties": {
                  "workbook_id": {"type": "string", "description": "Workbook ID from read_xlsx or create_xlsx"},
                  "sheet_name": {"type": "string", "description": "Sheet name (created if it doesn't exist)"},
                  "cells": {
                    "type": "array",
                    "items": {
                      "type": "object",
                      "properties": {
                        "ref": {"type": "string", "description": "Cell reference, e.g. 'A1'"},
                        "value": {"type": "string", "description": "Cell value (auto-detected type, or use type parameter)"},
                        "type": {"type": "string", "description": "Force value type: string, number, boolean, formula"}
                      },
                      "required": ["ref", "value"]
                    },
                    "description": "Array of cells to write"
                  }
                },
                "required": ["workbook_id", "sheet_name", "cells"]
              },
              "requirements": [],
              "permission_policy": "ask"
            },
            {
              "id": "save_xlsx",
              "description": "Save a workbook from memory to an .xlsx file on disk. The .xlsx extension is added automatically if missing. Existing files require overwrite=true; dry_run=true reports the planned write without modifying disk.",
              "parameters": {
                "type": "object",
                "properties": {
                  "workbook_id": {"type": "string", "description": "Workbook ID from read_xlsx or create_xlsx"},
                  "path": {"type": "string", "description": "Output file path (relative to workspace or absolute)"},
                  "overwrite": {"type": "boolean", "description": "Required to replace an existing file. Defaults to false."},
                  "dry_run": {"type": "boolean", "description": "If true, validate and report the planned save without writing a file."}
                },
                "required": ["workbook_id", "path"]
              },
              "requirements": [],
              "permission_policy": "ask"
            },
            {
              "id": "xlsx_to_csv",
              "description": "Convert a sheet from an Excel (.xlsx) file to CSV or TSV text. Reads directly from disk.",
              "parameters": {
                "type": "object",
                "properties": {
                  "path": {"type": "string", "description": "Path to the .xlsx file"},
                  "sheet_name": {"type": "string", "description": "Sheet to export (defaults to first sheet)"},
                  "format": {"type": "string", "description": "Output format: 'csv' (default) or 'tsv'"}
                },
                "required": ["path"]
              },
              "requirements": [],
              "permission_policy": "auto"
            },
            {
              "id": "csv_to_xlsx",
              "description": "Import CSV or TSV text data into a new workbook in memory. Use save_xlsx to write to disk afterwards.",
              "parameters": {
                "type": "object",
                "properties": {
                  "csv_data": {"type": "string", "description": "CSV or TSV text data"},
                  "sheet_name": {"type": "string", "description": "Sheet name (default: Sheet1)"},
                  "has_header": {"type": "boolean", "description": "If true, first row is treated as headers (kept as strings). Default: false"},
                  "delimiter": {"type": "string", "description": "Field delimiter: ',' (default), 'tab', or any single character"}
                },
                "required": ["csv_data"]
              },
              "requirements": [],
              "permission_policy": "auto"
            },
            {
              "id": "modify_xlsx",
              "description": "Apply batch modifications to a workbook in memory. Supports setting cells, formulas, deleting rows/columns, renaming sheets, and adding sheets. Invalid operations are skipped and reported in the errors field of the result. Note: delete_row/delete_column shift cell values only; formula references and merged ranges are not adjusted. Use save_xlsx afterwards to persist.",
              "parameters": {
                "type": "object",
                "properties": {
                  "workbook_id": {"type": "string", "description": "Workbook ID from read_xlsx or create_xlsx"},
                  "sheet_name": {"type": "string", "description": "Target sheet name (required for cell/row/column operations)"},
                  "operations": {
                    "type": "array",
                    "items": {
                      "type": "object",
                      "properties": {
                        "type": {"type": "string", "description": "Operation type: set_cell, set_formula, delete_row, delete_column, rename_sheet, add_sheet"},
                        "ref": {"type": "string", "description": "Cell reference for set_cell/set_formula (e.g. 'A1')"},
                        "value": {"type": "string", "description": "Cell value for set_cell"},
                        "formula": {"type": "string", "description": "Formula for set_formula (e.g. '=SUM(A1:A10)')"},
                        "row": {"type": "integer", "description": "Row number for delete_row (1-based)"},
                        "column": {"type": "string", "description": "Column letter for delete_column (e.g. 'C')"},
                        "new_name": {"type": "string", "description": "New name for rename_sheet"},
                        "name": {"type": "string", "description": "Sheet name for add_sheet"}
                      },
                      "required": ["type"]
                    },
                    "description": "Array of operations to apply"
                  }
                },
                "required": ["workbook_id", "operations"]
              },
              "requirements": [],
              "permission_policy": "ask"
            }
          ]
        }
      }
  """

/// v2 entry point: captures the injected host API into `HostBridge.shared`
/// (the SDK's pinned v6 mirror replaces the previous hand-rolled mirror,
/// which was truncated at the v2 surface).
@_cdecl("osaurus_plugin_entry_v2")
public func osaurus_plugin_entry_v2(_ host: UnsafeRawPointer?) -> UnsafeRawPointer? {
  PluginEntry.enterV2(host, api: &pluginAPI)
}

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  PluginEntry.enterV1(api: &pluginAPI)
}
