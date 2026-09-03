#!/usr/bin/env python3
"""Convert AsciiDoc guide pages to Markdown (docs/*.md)."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PAGES_DIR = REPO_ROOT / "content/modules/ROOT/pages"
DOCS_DIR = REPO_ROOT / "docs"

ATTRS = {
    "rhoai": "Red Hat OpenShift AI",
    "rhoai-short": "RHOAI",
    "ocp": "OpenShift Container Platform",
    "ocp-short": "OpenShift",
    "maas": "Models as a Service",
    "repo-url": "https://github.com/rh-aiservices-bu/rhoai-maas-guide",
}

ANCHOR_ALIASES = {
    "_getting_started": "getting-started",
    "_gateway_pod_oomkill_prevention": "gateway-pod-oomkill-prevention",
    "_optional_metallb_operator_non_cloud_clusters": "optional-metallb-operator-non-cloud-clusters",
    "_troubleshooting": "troubleshooting",
}

FILES = [
    "index.adoc",
    "quick-start.adoc",
    "claude-code.adoc",
    "01-prerequisites.adoc",
    "02-platform-config.adoc",
    "03-maas-platform.adoc",
    "04-rhoai-config.adoc",
    "05-maas-models.adoc",
    "06-verification.adoc",
    "07-observability.adoc",
    "08-architecture.adoc",
    "09-optional-guis.adoc",
]

STUB_TEMPLATE = """= {title}

This page is maintained as Markdown in the repository:

link:{{repo-url}}/blob/main/docs/{md_name}[docs/{md_name}]
"""


def substitute_attrs(text: str) -> str:
    for key, val in ATTRS.items():
        text = text.replace(f"{{{key}}}", val)
    return text


def xref_to_md(ref: str, label: str) -> str:
    ref = ref.removeprefix("xref:")
    if "#" in ref:
        page, anchor = ref.split("#", 1)
        anchor = ANCHOR_ALIASES.get(anchor, anchor.lstrip("_").replace("_", "-"))
        page = page.replace(".adoc", ".md")
        if not page.startswith(("http", "./")):
            page = f"./{page}"
        return f"[{label}]({page}#{anchor})"
    page = ref.replace(".adoc", ".md")
    if not page.startswith(("http", "./")):
        page = f"./{page}"
    return f"[{label}]({page})"


def adoc_link_to_md(match: re.Match) -> str:
    url = match.group(1)
    label = match.group(2)
    if url.startswith("http"):
        return f"[{label}]({url})"
    return xref_to_md(url, label)


def convert_inline(text: str) -> str:
    text = substitute_attrs(text)
    placeholders: list[str] = []

    def protect(pattern: str, s: str) -> str:
        def repl(m: re.Match) -> str:
            placeholders.append(m.group(0))
            return f"\0P{len(placeholders) - 1}\0"

        return re.sub(pattern, repl, s)

    text = protect(r"`[^`]+`", text)
    text = re.sub(r"link:([^\[]+)\[([^\]]*)\]", adoc_link_to_md, text)
    text = re.sub(r"xref:([^\[]+)\[([^\]]*)\]", lambda m: xref_to_md(m.group(1), m.group(2)), text)
    text = re.sub(
        r"<<([^>,]+)>>",
        lambda m: f"[{m.group(1).replace('-', ' ').title()}](#{m.group(1)})",
        text,
    )
    text = re.sub(r"\^([^\^]+)\^", r"^\1^", text)
    text = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"**\1**", text)
    text = re.sub(r"(?<=\s)_([^_\s]+)_(?=\s)", r"*\1*", text)
    for i, val in enumerate(placeholders):
        text = text.replace(f"\0P{i}\0", val)
    text = re.sub(
        r"^(IMPORTANT|NOTE|WARNING|TIP):\s*(.+)$",
        lambda m: f"> **{m.group(1).title()}:** {m.group(2)}",
        text,
        flags=re.M,
    )
    return text


def convert_adoc(content: str) -> str:
    lines = content.splitlines()
    out: list[str] = []
    i = 0
    pending_anchor: str | None = None
    in_table = False
    table_header_done = False
    table_cols = 0
    table_cells: list[str] = []
    para_buf: list[str] = []

    def flush_table_row(cells: list[str]) -> None:
        nonlocal table_header_done
        if not cells:
            return
        row = [convert_inline(c) for c in cells]
        out.append("| " + " | ".join(row) + " |")
        if not table_header_done:
            out.append("| " + " | ".join(["---"] * len(row)) + " |")
            table_header_done = True

    def flush_para(buf: list[str]) -> None:
        if buf:
            out.append(convert_inline(" ".join(buf).strip()))
            out.append("")

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        m = re.match(r"^\[\[([^\]]+)\]\]$", stripped)
        if m:
            pending_anchor = m.group(1)
            i += 1
            continue

        if stripped == "++++":
            i += 1
            block = []
            while i < len(lines) and lines[i].strip() != "++++":
                block.append(lines[i])
                i += 1
            out.extend(block)
            out.append("")
            i += 1
            continue

        adm = re.match(r"^\[(NOTE|IMPORTANT|WARNING|TIP)\]$", stripped)
        if adm:
            kind = adm.group(1)
            i += 1
            if i < len(lines) and lines[i].strip() == "====":
                i += 1
                block = []
                while i < len(lines) and lines[i].strip() != "====":
                    block.append(lines[i])
                    i += 1
                i += 1
                label = {"NOTE": "Note", "IMPORTANT": "Important", "WARNING": "Warning", "TIP": "Tip"}[kind]
                out.append(f"> **{label}:**")
                for bl in convert_adoc("\n".join(block)).splitlines():
                    out.append(f"> {bl}" if bl else ">")
                out.append("")
                continue

        if stripped.startswith("[source"):
            i += 1
            if i < len(lines) and lines[i].strip() == "----":
                i += 1
                lang = "bash" if "bash" in stripped else ""
                out.append(f"```{lang}")
                while i < len(lines) and lines[i].strip() != "----":
                    out.append(lines[i])
                    i += 1
                out.append("```")
                out.append("")
                i += 1
                continue

        cols_match = re.match(r'^\[cols="([^"]+)"', stripped)
        if cols_match:
            table_cols = len(cols_match.group(1).split(","))
            i += 1
            continue

        if stripped == "|===":
            flush_para(para_buf)
            para_buf = []
            in_table = True
            table_header_done = False
            table_cells = []
            i += 1
            continue

        if in_table:
            if stripped == "|===":
                if table_cells:
                    flush_table_row(table_cells)
                    table_cells = []
                in_table = False
                out.append("")
                i += 1
                continue
            if stripped.startswith("|"):
                cell = stripped.lstrip("|").strip()
                if "|" in cell:
                    if table_cells:
                        flush_table_row(table_cells)
                        table_cells = []
                    flush_table_row([c.strip() for c in cell.split("|")])
                else:
                    table_cells.append(cell)
                    ncol = table_cols or max(len(table_cells), 1)
                    if table_cols and len(table_cells) >= ncol:
                        flush_table_row(table_cells[:ncol])
                        table_cells = table_cells[ncol:]
                i += 1
                continue
            if not stripped:
                i += 1
                continue
            if table_cells:
                flush_table_row(table_cells)
                table_cells = []
            in_table = False
            out.append("")

        hm = re.match(r"^(=+)\s+(.+)$", stripped)
        if hm:
            flush_para(para_buf)
            para_buf = []
            level = len(hm.group(1))
            title = convert_inline(hm.group(2))
            hashes = "#" * min(level, 6)
            if pending_anchor:
                out.append(f"{hashes} {title} {{#{pending_anchor}}}")
                pending_anchor = None
            else:
                out.append(f"{hashes} {title}")
            out.append("")
            i += 1
            continue

        if stripped == "----" and not para_buf:
            i += 1
            continue

        if re.match(r"^\.\s", stripped):
            flush_para(para_buf)
            para_buf = []
            out.append(convert_inline(re.sub(r"^\.\s+", "1. ", stripped)))
            i += 1
            continue
        if stripped.startswith("* "):
            flush_para(para_buf)
            para_buf = []
            out.append(convert_inline(stripped.replace("* ", "- ", 1)))
            i += 1
            continue

        if not stripped:
            flush_para(para_buf)
            para_buf = []
            i += 1
            continue

        para_buf.append(stripped)
        i += 1

    flush_para(para_buf)
    if table_cells:
        flush_table_row(table_cells)
    text = "\n".join(out)
    return re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"


def write_stub(adoc_path: Path, md_name: str, title: str) -> None:
    adoc_path.write_text(
        STUB_TEMPLATE.format(title=title, md_name=md_name).replace("{{repo-url}}", "{repo-url}"),
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stubs", action="store_true", help="Replace .adoc with redirect stubs")
    args = parser.parse_args()

    DOCS_DIR.mkdir(exist_ok=True)
    for name in FILES:
        adoc_path = PAGES_DIR / name
        if not adoc_path.exists():
            print(f"skip missing {name}", file=sys.stderr)
            continue
        content = adoc_path.read_text(encoding="utf-8")
        if "This page is maintained as Markdown" in content:
            print(f"skip stub source {name}", file=sys.stderr)
            continue
        md_name = name.replace(".adoc", ".md")
        md_path = DOCS_DIR / md_name
        md_path.write_text(convert_adoc(content), encoding="utf-8")
        print(f"converted {name} -> docs/{md_name}")
        if args.stubs:
            title_match = re.search(r"^=\s+(.+)$", content, re.M)
            title = title_match.group(1) if title_match else name
            write_stub(adoc_path, md_name, substitute_attrs(title))
            print(f"  stubbed {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
