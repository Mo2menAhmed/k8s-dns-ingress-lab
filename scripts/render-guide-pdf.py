#!/usr/bin/env python3
import re
import sys
import textwrap
from pathlib import Path


PAGE_WIDTH = 612
PAGE_HEIGHT = 792
MARGIN_X = 54
MARGIN_TOP = 54
MARGIN_BOTTOM = 54
CONTENT_WIDTH = PAGE_WIDTH - (2 * MARGIN_X)


def pdf_escape(text):
    return (
        text.replace("\\", "\\\\")
        .replace("(", "\\(")
        .replace(")", "\\)")
    )


def ascii_text(text):
    return text.encode("ascii", "replace").decode("ascii")


def wrap_text(text, font_size, code=False):
    if code:
      max_chars = max(40, int(CONTENT_WIDTH / (font_size * 0.58)))
      return textwrap.wrap(
          text,
          width=max_chars,
          replace_whitespace=False,
          drop_whitespace=False,
          subsequent_indent="  ",
      ) or [""]
    max_chars = max(40, int(CONTENT_WIDTH / (font_size * 0.50)))
    return textwrap.wrap(text, width=max_chars) or [""]


def parse_markdown(markdown):
    blocks = []
    in_code = False
    paragraph = []

    def flush_paragraph():
        nonlocal paragraph
        if paragraph:
            blocks.append(("p", " ".join(line.strip() for line in paragraph)))
            paragraph = []

    for raw_line in markdown.splitlines():
        line = ascii_text(raw_line.rstrip())
        if line.startswith("```"):
            flush_paragraph()
            in_code = not in_code
            if in_code:
                blocks.append(("code_start", ""))
            else:
                blocks.append(("code_end", ""))
            continue

        if in_code:
            blocks.append(("code", line))
            continue

        if not line.strip():
            flush_paragraph()
            blocks.append(("blank", ""))
            continue

        if line.startswith("# "):
            flush_paragraph()
            blocks.append(("h1", line[2:].strip()))
        elif line.startswith("## "):
            flush_paragraph()
            blocks.append(("h2", line[3:].strip()))
        elif line.startswith("- "):
            flush_paragraph()
            blocks.append(("li", line))
        else:
            paragraph.append(line)

    flush_paragraph()
    return blocks


def build_pages(blocks):
    pages = []
    commands = []
    y = PAGE_HEIGHT - MARGIN_TOP

    def new_page():
        nonlocal commands, y
        if commands:
            pages.append(commands)
        commands = []
        y = PAGE_HEIGHT - MARGIN_TOP

    def ensure(height):
        if y - height < MARGIN_BOTTOM:
            new_page()

    def draw_text(text, font, size, x, line_y):
        commands.append(f"BT /{font} {size:.1f} Tf {x:.1f} {line_y:.1f} Td ({pdf_escape(text)}) Tj ET")

    for kind, text in blocks:
        if kind == "blank":
            y -= 5
            continue

        if kind == "code_start":
            y -= 3
            continue

        if kind == "code_end":
            y -= 8
            continue

        if kind == "h1":
            lines = wrap_text(text, 20)
            ensure(30 + len(lines) * 22)
            for line in lines:
                draw_text(line, "F2", 20, MARGIN_X, y)
                y -= 24
            y -= 8
            continue

        if kind == "h2":
            lines = wrap_text(text, 14)
            ensure(20 + len(lines) * 17)
            y -= 8
            for line in lines:
                draw_text(line, "F2", 14, MARGIN_X, y)
                y -= 18
            y -= 2
            continue

        if kind == "li":
            lines = wrap_text(text, 10.5)
            ensure(len(lines) * 14 + 4)
            first = True
            for line in lines:
                x = MARGIN_X if first else MARGIN_X + 14
                draw_text(line, "F1", 10.5, x, y)
                y -= 14
                first = False
            continue

        if kind == "code":
            lines = wrap_text(text, 7.5, code=True)
            ensure(len(lines) * 10 + 4)
            for line in lines:
                draw_text(line, "F3", 7.5, MARGIN_X + 8, y)
                y -= 10
            continue

        lines = wrap_text(text, 10.5)
        ensure(len(lines) * 14 + 4)
        for line in lines:
            draw_text(line, "F1", 10.5, MARGIN_X, y)
            y -= 14
        y -= 4

    if commands:
        pages.append(commands)

    for i, page in enumerate(pages, start=1):
        page.append(f"BT /F1 8 Tf {PAGE_WIDTH / 2 - 20:.1f} 28 Td (Page {i}) Tj ET")

    return pages


def make_pdf(pages):
    objects = {}
    objects[1] = b"<< /Type /Catalog /Pages 2 0 R >>"
    objects[3] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    objects[4] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>"
    objects[5] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>"

    next_id = 6
    page_ids = []
    for commands in pages:
        content = "\n".join(commands).encode("ascii")
        content_id = next_id
        page_id = next_id + 1
        next_id += 2
        objects[content_id] = b"<< /Length " + str(len(content)).encode("ascii") + b" >>\nstream\n" + content + b"\nendstream"
        objects[page_id] = (
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PAGE_WIDTH} {PAGE_HEIGHT}] "
            f"/Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >> >> "
            f"/Contents {content_id} 0 R >>"
        ).encode("ascii")
        page_ids.append(page_id)

    kids = " ".join(f"{page_id} 0 R" for page_id in page_ids)
    objects[2] = f"<< /Type /Pages /Kids [{kids}] /Count {len(page_ids)} >>".encode("ascii")

    output = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for obj_id in range(1, max(objects) + 1):
        offsets.append(len(output))
        output.extend(f"{obj_id} 0 obj\n".encode("ascii"))
        output.extend(objects[obj_id])
        output.extend(b"\nendobj\n")

    xref_pos = len(output)
    output.extend(f"xref\n0 {max(objects) + 1}\n".encode("ascii"))
    output.extend(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        output.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
    output.extend(
        f"trailer\n<< /Size {max(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref_pos}\n%%EOF\n".encode("ascii")
    )
    return bytes(output)


def main():
    if len(sys.argv) != 3:
        print("usage: render-guide-pdf.py input.md output.pdf", file=sys.stderr)
        return 2
    markdown = Path(sys.argv[1]).read_text(encoding="utf-8")
    blocks = parse_markdown(markdown)
    pages = build_pages(blocks)
    Path(sys.argv[2]).write_bytes(make_pdf(pages))
    print(f"wrote {sys.argv[2]} ({len(pages)} pages)")


if __name__ == "__main__":
    raise SystemExit(main())
