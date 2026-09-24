"""Aligns Markdown tables for monospace reading, and checks local links.

Usage: python3 tools/check_docs.py [--fix] FILE.md...

Without --fix, exits 1 if a table is not aligned or a link to a file or
heading does not resolve. With --fix, aligns the tables in place first.
Column widths are display widths, so ×, −, → and superscripts count once.
"""

import argparse
from pathlib import Path
import re
import sys
import unicodedata


def width(text):
    total = 0
    for char in text:
        if unicodedata.combining(char):
            continue
        total += 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
    return total


def cells(line):
    # Split on pipes outside code spans; a table cell may quote code.
    parts, current, code = [], "", False
    for char in line.strip()[1:-1]:
        if char == "`":
            code = not code
        # An escaped pipe, \|, is text inside a cell, not a separator.
        if char == "|" and not code and not current.endswith("\\"):
            parts.append(current.strip())
            current = ""
        else:
            current += char
    parts.append(current.strip())
    return parts


def align(rows):
    table = [cells(row) for row in rows]
    columns = max(len(row) for row in table)
    table = [row + [""] * (columns - len(row)) for row in table]
    rule = table[1]
    kinds = ["right" if c.endswith(":") and not c.startswith(":") else
             "centre" if c.startswith(":") and c.endswith(":") else "left" for c in rule]
    widths = [max(3, *(width(row[i]) for j, row in enumerate(table) if j != 1))
              for i in range(columns)]
    out = []
    for j, row in enumerate(table):
        if j == 1:
            parts = []
            for kind, w in zip(kinds, widths):
                parts.append(":" + "-" * (w - 2) + ":" if kind == "centre" else
                             "-" * (w - 1) + ":" if kind == "right" else "-" * w)
        else:
            parts = []
            for text, kind, w in zip(row, kinds, widths):
                pad = w - width(text)
                parts.append(" " * pad + text if kind == "right" else
                             " " * (pad // 2) + text + " " * (pad - pad // 2) if kind == "centre"
                             else text + " " * pad)
        out.append("| " + " | ".join(parts) + " |")
    return out


def blocks(lines):
    """Yields (start, end) of each table outside code fences."""
    fence, start = False, None
    for i, line in enumerate(lines + [""]):
        if line.startswith("```"):
            fence = not fence
        table = not fence and line.startswith("|")
        if table and start is None:
            start = i
        elif not table and start is not None:
            if i - start >= 2:
                yield start, i
            start = None


def slug(heading):
    text = heading.strip().lower()
    text = "".join(c for c in text if c.isalnum() or c in " -_")
    return text.replace(" ", "-")


def anchors(lines):
    seen, result, fence = {}, set(), False
    for line in lines:
        if line.startswith("```"):
            fence = not fence
        match = None if fence else re.match(r"#{1,6} (.*)", line)
        if match:
            base = slug(match[1])
            count = seen.get(base, 0)
            seen[base] = count + 1
            result.add(base if count == 0 else f"{base}-{count}")
    return result


def links(path, lines):
    problems, fence = [], False
    own = anchors(lines)
    for number, line in enumerate(lines, 1):
        if line.startswith("```"):
            fence = not fence
        if fence:
            continue
        for target in re.findall(r"\]\(([^)\s]+)\)", re.sub(r"`[^`]*`", "", line)):
            if re.match(r"[a-z]+:", target):
                continue
            file, _, anchor = target.partition("#")
            destination = (path.parent / file) if file else path
            if not destination.exists():
                problems.append(f"{path}:{number}: missing file {file}")
            elif anchor and destination.suffix == ".md":
                known = own if not file else anchors(destination.read_text().split("\n"))
                if anchor not in known:
                    problems.append(f"{path}:{number}: missing heading #{anchor}")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fix", action="store_true")
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()
    problems = []
    for path in args.files:
        lines = path.read_text().split("\n")
        changed = False
        for start, end in list(blocks(lines)):
            aligned = align(lines[start:end])
            if aligned != lines[start:end]:
                if args.fix:
                    lines[start:end] = aligned
                    changed = True
                else:
                    problems.append(f"{path}:{start + 1}: table not aligned (run with --fix)")
        if changed:
            path.write_text("\n".join(lines))
        problems += links(path, lines)
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
