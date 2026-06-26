#!/usr/bin/env python3
"""Upsert Ansible host rows into a Google Sheets tab."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


COLUMNS = [
    {"key": "host", "label": "Сервер"},
    {"key": "public_ip", "label": "Публичный IP"},
    {"key": "os", "label": "ОС"},
    {"key": "kernel", "label": "Ядро"},
    {"key": "cpu_vcpus", "label": "vCPU"},
    {"key": "memory_mb", "label": "RAM, MB"},
    {"key": "root_disk_total", "label": "Диск /"},
    {"key": "speedtest_status", "label": "Speedtest"},
    {"key": "speedtest_download_mbps", "label": "Download, Mbps"},
    {"key": "speedtest_upload_mbps", "label": "Upload, Mbps"},
    {"key": "speedtest_ping_ms", "label": "Ping, ms"},
    {"key": "zsh_done", "label": "ZSH", "checkbox": True},
    {"key": "ssh_done", "label": "SSH", "checkbox": True},
    {"key": "remnanode_done", "label": "RemnaNode", "checkbox": True},
    {"key": "monitoring_done", "label": "Monitoring", "checkbox": True},
]

HEADERS = [column["label"] for column in COLUMNS]
CHECKBOX_COLUMN_INDEXES = [
    index for index, column in enumerate(COLUMNS) if column.get("checkbox")
]
NUMERIC_COLUMN_KEYS = {
    "speedtest_download_mbps",
    "speedtest_upload_mbps",
    "speedtest_ping_ms",
}

SCOPES = ["https://www.googleapis.com/auth/spreadsheets"]

WOW_COLORS = {
    "navy": {"red": 0.0196, "green": 0.0549, "blue": 0.1020},
    "card": {"red": 0.0392, "green": 0.0941, "blue": 0.1647},
    "gold": {"red": 0.8392, "green": 0.6980, "blue": 0.4314},
    "mint": {"red": 0.6235, "green": 0.8392, "blue": 0.7451},
    "blue": {"red": 0.3765, "green": 0.6471, "blue": 0.9804},
    "header_blue": {"red": 0.1451, "green": 0.3882, "blue": 0.9216},
    "danger": {"red": 0.9725, "green": 0.4431, "blue": 0.4431},
    "soft_red": {"red": 1.0, "green": 0.7804, "blue": 0.7804},
    "orange": {"red": 0.9922, "green": 0.6863, "blue": 0.3098},
    "soft_green": {"red": 0.8000, "green": 0.9294, "blue": 0.8353},
    "green": {"red": 0.3529, "green": 0.7804, "blue": 0.4824},
    "bright_green": {"red": 0.1333, "green": 0.8275, "blue": 0.3765},
    "white": {"red": 0.9176, "green": 0.9490, "blue": 1.0},
    "muted": {"red": 0.6627, "green": 0.7255, "blue": 0.8275},
    "row": {"red": 0.9686, "green": 0.9804, "blue": 0.9922},
    "row_alt": {"red": 0.9412, "green": 0.9608, "blue": 0.9843},
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--credentials", required=True)
    parser.add_argument("--spreadsheet-id", required=True)
    parser.add_argument("--worksheet", default="ansible_inventory")
    parser.add_argument("--rows-file", required=True)
    return parser.parse_args()


def load_rows(path: Path) -> list[dict[str, object]]:
    if str(path) == "-":
        data = json.load(sys.stdin)
    else:
        with path.open("r", encoding="utf-8") as file_obj:
            data = json.load(file_obj)
    if not isinstance(data, list):
        raise ValueError(f"{path} must contain a JSON list")
    return data


def get_sheets_service(credentials_path: Path):
    try:
        from google.oauth2 import service_account
        from googleapiclient.discovery import build
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "Google API Python packages are missing. Install them with:\n"
            "  python3 -m pip install -r requirements-google-sheets.txt"
        ) from exc

    credentials = service_account.Credentials.from_service_account_file(
        str(credentials_path),
        scopes=SCOPES,
    )
    return build("sheets", "v4", credentials=credentials, cache_discovery=False)


def get_worksheet_metadata(service, spreadsheet_id: str, worksheet: str) -> dict:
    metadata = service.spreadsheets().get(spreadsheetId=spreadsheet_id).execute()
    for sheet in metadata.get("sheets", []):
        if sheet["properties"]["title"] == worksheet:
            return sheet
    return {}


def ensure_worksheet(service, spreadsheet_id: str, worksheet: str) -> int:
    sheet = get_worksheet_metadata(service, spreadsheet_id, worksheet)
    if sheet:
        return int(sheet["properties"]["sheetId"])

    response = service.spreadsheets().batchUpdate(
        spreadsheetId=spreadsheet_id,
        body={
            "requests": [
                {
                    "addSheet": {
                        "properties": {
                            "title": worksheet,
                            "gridProperties": {
                                "rowCount": 1000,
                                "columnCount": len(COLUMNS),
                            },
                        }
                    }
                }
            ]
        },
    ).execute()
    try:
        sheet_id = response["replies"][0]["addSheet"]["properties"]["sheetId"]
    except (KeyError, IndexError, TypeError) as exc:
        raise RuntimeError(f"Google Sheets did not return created worksheet id: {response}") from exc

    print(f"Created worksheet: {worksheet}")
    return int(sheet_id)


def clear_existing_format_rules(service, spreadsheet_id: str, worksheet: str) -> None:
    sheet = get_worksheet_metadata(service, spreadsheet_id, worksheet)
    sheet_id = int(sheet["properties"]["sheetId"])
    rules = sheet.get("conditionalFormats", [])
    banded_ranges = sheet.get("bandedRanges", [])
    requests = []

    if sheet.get("basicFilter"):
        requests.append({"clearBasicFilter": {"sheetId": sheet_id}})

    for index in reversed(range(len(rules))):
        requests.append(
            {
                "deleteConditionalFormatRule": {
                    "sheetId": sheet_id,
                    "index": index,
                }
            }
        )

    for banding in banded_ranges:
        requests.append(
            {
                "deleteBanding": {
                    "bandedRangeId": banding["bandedRangeId"],
                }
            }
        )

    if requests:
        service.spreadsheets().batchUpdate(
            spreadsheetId=spreadsheet_id,
            body={"requests": requests},
        ).execute()


def apply_wowsecure_format(
    service,
    spreadsheet_id: str,
    sheet_id: int,
    row_count: int,
    col_count: int,
) -> None:
    widths = {
        0: 150,
        1: 130,
        2: 170,
        3: 170,
        7: 150,
        8: 180,
        9: 170,
        10: 150,
        11: 90,
        12: 90,
        13: 130,
        14: 130,
    }
    width_requests = [
        {
            "updateDimensionProperties": {
                "range": {
                    "sheetId": sheet_id,
                    "dimension": "COLUMNS",
                    "startIndex": index,
                    "endIndex": index + 1,
                },
                "properties": {"pixelSize": width},
                "fields": "pixelSize",
            }
        }
        for index, width in widths.items()
    ]

    requests = [
        {
            "updateSheetProperties": {
                "properties": {
                    "sheetId": sheet_id,
                    "gridProperties": {
                        "frozenRowCount": 1,
                        "rowCount": max(row_count + 20, 1000),
                        "columnCount": col_count,
                    },
                    "tabColor": WOW_COLORS["header_blue"],
                },
                "fields": "gridProperties.frozenRowCount,gridProperties.rowCount,gridProperties.columnCount,tabColor",
            }
        },
        {
            "repeatCell": {
                "range": {
                    "sheetId": sheet_id,
                    "startRowIndex": 0,
                    "endRowIndex": 1,
                    "startColumnIndex": 0,
                    "endColumnIndex": col_count,
                },
                "cell": {
                    "userEnteredFormat": {
                        "backgroundColor": WOW_COLORS["header_blue"],
                        "horizontalAlignment": "CENTER",
                        "verticalAlignment": "MIDDLE",
                        "textFormat": {
                            "foregroundColor": WOW_COLORS["white"],
                            "fontFamily": "Manrope",
                            "fontSize": 12,
                            "bold": True,
                        },
                        "borders": {
                            "bottom": {
                                "style": "SOLID",
                                "color": WOW_COLORS["header_blue"],
                            }
                        },
                    }
                },
                "fields": "userEnteredFormat(backgroundColor,horizontalAlignment,verticalAlignment,textFormat,borders)",
            }
        },
        {
            "repeatCell": {
                "range": {
                    "sheetId": sheet_id,
                    "startRowIndex": 1,
                    "endRowIndex": max(row_count, 2),
                    "startColumnIndex": 0,
                    "endColumnIndex": col_count,
                },
                "cell": {
                    "userEnteredFormat": {
                        "backgroundColor": WOW_COLORS["row"],
                        "verticalAlignment": "MIDDLE",
                        "wrapStrategy": "WRAP",
                        "textFormat": {
                            "foregroundColor": WOW_COLORS["navy"],
                            "fontFamily": "Manrope",
                            "fontSize": 12,
                        },
                    }
                },
                "fields": "userEnteredFormat(backgroundColor,verticalAlignment,wrapStrategy,textFormat)",
            }
        },
        {
            "addBanding": {
                "bandedRange": {
                    "range": {
                        "sheetId": sheet_id,
                        "startRowIndex": 0,
                        "endRowIndex": max(row_count, 2),
                        "startColumnIndex": 0,
                        "endColumnIndex": col_count,
                    },
                    "rowProperties": {
                        "headerColor": WOW_COLORS["header_blue"],
                        "firstBandColor": WOW_COLORS["row"],
                        "secondBandColor": WOW_COLORS["row_alt"],
                    },
                }
            }
        },
        {
            "setBasicFilter": {
                "filter": {
                    "range": {
                        "sheetId": sheet_id,
                        "startRowIndex": 0,
                        "endRowIndex": max(row_count, 2),
                        "startColumnIndex": 0,
                        "endColumnIndex": col_count,
                    }
                }
            }
        },
        {
            "addConditionalFormatRule": {
                "rule": {
                    "ranges": [
                        {
                            "sheetId": sheet_id,
                            "startRowIndex": 1,
                            "endRowIndex": max(row_count, 2),
                            "startColumnIndex": 8,
                            "endColumnIndex": 10,
                        }
                    ],
                    "gradientRule": {
                        "minpoint": {
                            "type": "NUMBER",
                            "value": "300",
                            "color": WOW_COLORS["danger"],
                        },
                        "midpoint": {
                            "type": "NUMBER",
                            "value": "700",
                            "color": WOW_COLORS["orange"],
                        },
                        "maxpoint": {
                            "type": "NUMBER",
                            "value": "1500",
                            "color": WOW_COLORS["bright_green"],
                        },
                    },
                },
                "index": 2,
            }
        },
        {
            "addConditionalFormatRule": {
                "rule": {
                    "ranges": [
                        {
                            "sheetId": sheet_id,
                            "startRowIndex": 1,
                            "endRowIndex": max(row_count, 2),
                            "startColumnIndex": 7,
                            "endColumnIndex": 8,
                        }
                    ],
                    "booleanRule": {
                        "condition": {
                            "type": "TEXT_EQ",
                            "values": [{"userEnteredValue": "ok"}],
                        },
                        "format": {
                            "backgroundColor": WOW_COLORS["mint"],
                            "textFormat": {
                                "foregroundColor": WOW_COLORS["navy"],
                                "bold": True,
                            },
                        },
                    },
                },
                "index": 0,
            }
        },
        {
            "addConditionalFormatRule": {
                "rule": {
                    "ranges": [
                        {
                            "sheetId": sheet_id,
                            "startRowIndex": 1,
                            "endRowIndex": max(row_count, 2),
                            "startColumnIndex": 7,
                            "endColumnIndex": 8,
                        }
                    ],
                    "booleanRule": {
                        "condition": {
                            "type": "TEXT_CONTAINS",
                            "values": [{"userEnteredValue": "failed"}],
                        },
                        "format": {
                            "backgroundColor": WOW_COLORS["danger"],
                            "textFormat": {
                                "foregroundColor": WOW_COLORS["white"],
                                "bold": True,
                            },
                        },
                    },
                },
                "index": 1,
            }
        },
        {
            "addConditionalFormatRule": {
                "rule": {
                    "ranges": [
                        {
                            "sheetId": sheet_id,
                            "startRowIndex": 1,
                            "endRowIndex": max(row_count, 2),
                            "startColumnIndex": 10,
                            "endColumnIndex": 11,
                        }
                    ],
                    "gradientRule": {
                        "minpoint": {
                            "type": "NUMBER",
                            "value": "1",
                            "color": WOW_COLORS["mint"],
                        },
                        "midpoint": {
                            "type": "NUMBER",
                            "value": "80",
                            "color": WOW_COLORS["gold"],
                        },
                        "maxpoint": {
                            "type": "NUMBER",
                            "value": "200",
                            "color": WOW_COLORS["danger"],
                        },
                    },
                },
                "index": 2,
            }
        },
        {
            "repeatCell": {
                "range": {
                    "sheetId": sheet_id,
                    "startRowIndex": 1,
                    "endRowIndex": max(row_count, 2),
                    "startColumnIndex": min(CHECKBOX_COLUMN_INDEXES),
                    "endColumnIndex": max(CHECKBOX_COLUMN_INDEXES) + 1,
                },
                "cell": {
                    "dataValidation": {
                        "condition": {"type": "BOOLEAN"},
                        "strict": True,
                        "showCustomUi": True,
                    },
                    "userEnteredFormat": {
                        "horizontalAlignment": "CENTER",
                        "verticalAlignment": "MIDDLE",
                    },
                },
                "fields": "dataValidation,userEnteredFormat(horizontalAlignment,verticalAlignment)",
            }
        },
        {
            "addConditionalFormatRule": {
                "rule": {
                    "ranges": [
                        {
                            "sheetId": sheet_id,
                            "startRowIndex": 1,
                            "endRowIndex": max(row_count, 2),
                            "startColumnIndex": min(CHECKBOX_COLUMN_INDEXES),
                            "endColumnIndex": max(CHECKBOX_COLUMN_INDEXES) + 1,
                        }
                    ],
                    "booleanRule": {
                        "condition": {
                            "type": "TEXT_EQ",
                            "values": [{"userEnteredValue": "TRUE"}],
                        },
                        "format": {"backgroundColor": WOW_COLORS["mint"]},
                    },
                },
                "index": 3,
            }
        },
    ]
    requests.extend(width_requests)

    service.spreadsheets().batchUpdate(
        spreadsheetId=spreadsheet_id,
        body={"requests": requests},
    ).execute()


def quote_sheet_name(name: str) -> str:
    return "'" + name.replace("'", "''") + "'"


def normalize_checkbox(value: object) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "y", "on"}


def normalize_number(value: object) -> object:
    text = str(value).strip()
    if not text:
        return ""
    try:
        return float(text.replace(",", "."))
    except ValueError:
        return text


def row_to_values(row: dict[str, object]) -> list[object]:
    values = []
    for column in COLUMNS:
        value = row.get(column["key"], "")
        if column.get("checkbox"):
            values.append(normalize_checkbox(value))
        elif column["key"] in NUMERIC_COLUMN_KEYS:
            values.append(normalize_number(value))
        else:
            values.append(str(value).strip())
    return values


def read_existing_values(service, spreadsheet_id: str, worksheet: str) -> list[list[object]]:
    sheet_name = quote_sheet_name(worksheet)
    response = (
        service.spreadsheets()
        .values()
        .get(
            spreadsheetId=spreadsheet_id,
            range=f"{sheet_name}!A:Z",
            valueRenderOption="UNFORMATTED_VALUE",
        )
        .execute()
    )
    return response.get("values", [])


def normalize_existing_row(row: list[object]) -> list[object]:
    normalized = list(row[: len(COLUMNS)])
    if len(normalized) < len(COLUMNS):
        normalized.extend([""] * (len(COLUMNS) - len(normalized)))
    for index in CHECKBOX_COLUMN_INDEXES:
        normalized[index] = normalize_checkbox(normalized[index])
    for index, column in enumerate(COLUMNS):
        if column["key"] in NUMERIC_COLUMN_KEYS:
            normalized[index] = normalize_number(normalized[index])
    return normalized


def merge_rows(existing_values: list[list[object]], incoming_rows: list[dict[str, object]]) -> list[list[object]]:
    existing_rows = [
        normalize_existing_row(row)
        for row in existing_values[1:]
        if row and str(row[0]).strip()
    ]
    incoming_values = [row_to_values(row) for row in incoming_rows]
    row_by_host = {str(row[0]).strip(): row for row in existing_rows}

    for row in incoming_values:
        host = str(row[0]).strip()
        if host:
            row_by_host[host] = row

    ordered_hosts = []
    for row in existing_rows + incoming_values:
        host = str(row[0]).strip()
        if host and host not in ordered_hosts:
            ordered_hosts.append(host)

    return [HEADERS] + [row_by_host[host] for host in ordered_hosts]


def main() -> int:
    args = parse_args()
    rows = load_rows(Path(args.rows_file))

    service = get_sheets_service(Path(args.credentials))
    sheet_id = ensure_worksheet(service, args.spreadsheet_id, args.worksheet)
    clear_existing_format_rules(service, args.spreadsheet_id, args.worksheet)

    existing_values = read_existing_values(service, args.spreadsheet_id, args.worksheet)
    values = merge_rows(existing_values, rows)

    sheet_name = quote_sheet_name(args.worksheet)
    service.spreadsheets().values().clear(
        spreadsheetId=args.spreadsheet_id,
        range=f"{sheet_name}!A:Z",
        body={},
    ).execute()
    service.spreadsheets().values().update(
        spreadsheetId=args.spreadsheet_id,
        range=f"{sheet_name}!A1",
        valueInputOption="RAW",
        body={"values": values},
    ).execute()
    apply_wowsecure_format(
        service,
        args.spreadsheet_id,
        sheet_id,
        row_count=len(values),
        col_count=len(COLUMNS),
    )

    print(f"Updated {args.worksheet}: upserted {len(rows)} host rows, total {len(values) - 1}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
