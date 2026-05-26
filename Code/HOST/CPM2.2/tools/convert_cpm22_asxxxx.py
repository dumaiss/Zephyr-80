#!/usr/bin/env python3
"""Convert the immutable CP/M 2.2 source to ASxxxx syntax for local builds."""

from __future__ import annotations

import re
import sys
from pathlib import Path


EQU_RE = re.compile(r"^(\s*)([A-Za-z_.$][A-Za-z0-9_.$]*):?\s+EQU\s+(.+)$", re.IGNORECASE)
ORG_RE = re.compile(r"^(\s*)ORG\s+(.+)$", re.IGNORECASE)
DATA_RE = re.compile(r"^(\s*)(?:(?P<label>[A-Za-z_.$][A-Za-z0-9_.$]*):)?\s*(?P<op>DEFB|DEFW)\s+(?P<args>.*)$", re.IGNORECASE)

REG8 = {"A", "B", "C", "D", "E", "H", "L", "I", "R"}
REG16 = {"BC", "DE", "HL", "SP", "IX", "IY"}
REG_MEM = {"(BC)", "(DE)", "(HL)", "(SP)", "(IX)", "(IY)"}
COND = {"NZ", "Z", "NC", "C", "PO", "PE", "P", "M"}


def split_comment(line: str) -> tuple[str, str]:
    in_quote = False
    for index, char in enumerate(line):
        if char == "'":
            in_quote = not in_quote
        if char == ";" and not in_quote:
            return line[:index].rstrip(), line[index:]
    return line.rstrip(), ""


def convert_hex_suffix(text: str) -> str:
    return re.sub(r"\b([0-9][0-9A-Fa-f]*)H\b", lambda m: "0x" + m.group(1), text)


def split_csv(text: str) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    in_quote = False
    for char in text:
        if char == "'":
            in_quote = not in_quote
            current.append(char)
        elif char == "," and not in_quote:
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(char)
    if current or text.endswith(","):
        parts.append("".join(current).strip())
    return parts


def quote_delimiter(value: str) -> str:
    for delimiter in ("/", "|", "~", "!"):
        if delimiter not in value:
            return delimiter
    escaped = value.replace('"', '\\"')
    return f'"{escaped}"'


def convert_db_items(items: list[str]) -> list[tuple[str, str]]:
    converted: list[tuple[str, str]] = []
    numeric: list[str] = []
    for item in items:
        if len(item) >= 2 and item[0] == "'" and item[-1] == "'" and len(item[1:-1]) > 1:
            if numeric:
                converted.append((".db", ",".join(numeric)))
                numeric = []
            value = item[1:-1]
            delimiter = quote_delimiter(value)
            if len(delimiter) == 1:
                converted.append((".ascii", f"{delimiter}{value}{delimiter}"))
            else:
                converted.append((".ascii", delimiter))
        else:
            numeric.append(item)
    if numeric:
        converted.append((".db", ",".join(numeric)))
    return converted


def is_register(expr: str) -> bool:
    upper = expr.upper()
    return upper in REG8 or upper in REG16 or upper in REG_MEM


def is_memory(expr: str) -> bool:
    stripped = expr.strip()
    return stripped.startswith("(") or stripped.startswith("[")


def needs_immediate_prefix(expr: str) -> bool:
    stripped = expr.strip()
    if not stripped or stripped.startswith("#") or is_register(stripped) or is_memory(stripped):
        return False
    return True


def prefix_immediate(expr: str) -> str:
    return "#" + expr.strip() if needs_immediate_prefix(expr) else expr.strip()


def split_instruction(code: str) -> tuple[str, str, str]:
    match = re.match(r"^(\s*)(?:(?P<label>[A-Za-z_.$][A-Za-z0-9_.$]*):)?\s*(?P<body>.*)$", code)
    if not match:
        return "", "", code
    prefix = match.group(1)
    label = (match.group("label") or "")
    body = match.group("body").strip()
    label_text = f"{label}:" if label else ""
    return prefix, label_text, body


def convert_instruction(code: str) -> str:
    prefix, label, body = split_instruction(code)
    if not body:
        return code
    parts = body.split(None, 1)
    op = parts[0].upper()
    operands_text = parts[1] if len(parts) > 1 else ""
    operands = split_csv(operands_text) if operands_text else []

    if op == "LD" and len(operands) == 2:
        dst = operands[0].strip()
        src = operands[1].strip()
        dst_upper = dst.upper()
        if is_register(dst) and not is_memory(dst):
            operands[1] = prefix_immediate(src)
        elif dst_upper == "(HL)" and needs_immediate_prefix(src):
            operands[1] = prefix_immediate(src)
    elif op in {"CP", "AND", "OR", "XOR", "SUB"} and len(operands) == 1:
        operands[0] = prefix_immediate(operands[0])
    elif op in {"ADD", "ADC", "SBC"} and len(operands) == 2:
        first = operands[0].strip().upper()
        if first in {"A", "HL", "IX", "IY"}:
            operands[1] = prefix_immediate(operands[1])

    converted_body = op if not operands else f"{op}      {','.join(operands)}"
    if label:
        return f"{prefix}{label}{converted_body}"
    return f"{prefix}{converted_body}"


def convert_line(line: str) -> list[str]:
    code, comment = split_comment(line)
    if not code.strip():
        return [line.rstrip()]

    code = convert_hex_suffix(code)
    code = replace_dollar_outside_quotes(code)

    match = EQU_RE.match(code)
    if match:
        indent, label, expr = match.groups()
        return [f"{indent}{label} = {expr.strip()}{(' ' + comment) if comment else ''}".rstrip()]

    match = ORG_RE.match(code)
    if match:
        indent, expr = match.groups()
        return [f"{indent}.org     {expr.strip()}{(' ' + comment) if comment else ''}".rstrip()]

    match = DATA_RE.match(code)
    if match:
        indent = match.group(1)
        label = match.group("label") or ""
        op = match.group("op").upper()
        args = match.group("args")
        directive = ".db" if op == "DEFB" else ".dw"
        items = split_csv(args)
        chunks = convert_db_items(items) if directive == ".db" else [(directive, ",".join(items))]
        lines: list[str] = []
        for index, (chunk_directive, chunk_args) in enumerate(chunks):
            label_text = f"{label}:" if index == 0 and label else ""
            suffix = f" {comment}" if index == 0 and comment else ""
            lines.append(f"{indent}{label_text}{chunk_directive}    {chunk_args}{suffix}".rstrip())
        return lines

    converted = convert_instruction(code)
    if comment:
        converted = f"{converted} {comment}"
    return [converted.rstrip()]

def replace_dollar_outside_quotes(text: str) -> str:
    out: list[str] = []
    in_quote = False

    for char in text:
        if char == "'":
            in_quote = not in_quote
            out.append(char)
        elif char == "$" and not in_quote:
            out.append(".")
        else:
            out.append(char)

    return "".join(out)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} input.asm output.asm", file=sys.stderr)
        return 2

    source = Path(sys.argv[1])
    output = Path(sys.argv[2])
    lines = [
        "; Generated from immutable CP/M 2.2 source for ASxxxx assembly.",
        "; Do not edit this generated file; edit the source or converter instead.",
        "",
        "        .area   CODE (ABS)",
    ]
    for line in source.read_text(errors="replace").splitlines():
        lines.extend(convert_line(line))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
