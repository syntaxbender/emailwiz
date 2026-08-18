#!/usr/bin/env python3

"""Small sqlite3 CLI subset used only when the test host lacks sqlite3(1)."""

import sqlite3
import sys


def statements(script: str):
    current = ""
    for character in script:
        current += character
        if character == ";" and sqlite3.complete_statement(current):
            if current.strip():
                yield current
            current = ""
    if current.strip():
        yield current


def main() -> int:
    args = sys.argv[1:]
    show_header = False
    column_mode = False
    while args and args[0].startswith("-"):
        option = args.pop(0)
        if option == "-header":
            show_header = True
        elif option == "-column":
            column_mode = True
        else:
            raise SystemExit(f"unsupported sqlite3 shim option: {option}")

    if not args:
        raise SystemExit("database path is required")
    database = args.pop(0)
    script = args.pop(0) if args else sys.stdin.read()
    if args:
        raise SystemExit("too many sqlite3 shim arguments")

    connection = sqlite3.connect(database)
    connection.execute("PRAGMA foreign_keys = ON")
    try:
        for statement in statements(script):
            cursor = connection.execute(statement)
            if cursor.description is None:
                continue
            rows = cursor.fetchall()
            headers = [description[0] for description in cursor.description]
            if column_mode:
                values = [["" if value is None else str(value) for value in row] for row in rows]
                widths = [len(header) for header in headers]
                for row in values:
                    widths = [max(width, len(value)) for width, value in zip(widths, row)]
                if show_header:
                    print("  ".join(header.ljust(width) for header, width in zip(headers, widths)))
                    print("  ".join("-" * width for width in widths))
                for row in values:
                    print("  ".join(value.ljust(width) for value, width in zip(row, widths)))
            else:
                if show_header:
                    print("|".join(headers))
                for row in rows:
                    print("|".join("" if value is None else str(value) for value in row))
        connection.commit()
    finally:
        connection.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
