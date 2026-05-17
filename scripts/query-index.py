#!/usr/bin/env python3
"""
Query the codebase symbol index without reading source files.

Usage:
    python3 scripts/query-index.py --symbol <name>         # fuzzy match
    python3 scripts/query-index.py --kind function|class|method
    python3 scripts/query-index.py --file "scripts/*.py"   # fnmatch glob
    python3 scripts/query-index.py --exports               # exported symbols only
    python3 scripts/query-index.py --top 20                # limit output lines
"""
import argparse
import difflib
import fnmatch
import json
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent
INDEX_PATH = PROJECT_ROOT / ".claude" / "codebase-index.json"


def load_index() -> dict:
    if not INDEX_PATH.exists():
        print(
            "Index not found — run first:\n"
            "  python3 scripts/index-codebase.py --full",
            file=sys.stderr,
        )
        sys.exit(1)
    try:
        return json.loads(INDEX_PATH.read_text())
    except Exception as exc:
        print(f"Failed to read index: {exc}", file=sys.stderr)
        sys.exit(1)


def flatten_symbols(files: dict) -> list[dict]:
    """Return flat list of {rel, line, kind, name, signature, exported} dicts."""
    rows = []
    for rel, entry in files.items():
        exports = set(entry.get("exports", []))
        for sym in entry.get("symbols", []):
            rows.append({
                "rel": rel,
                "line": sym.get("line", 0),
                "kind": sym["kind"],
                "name": sym["name"],
                "signature": sym.get("signature") or sym["name"],
                "exported": sym["name"] in exports,
            })
            # Flatten class methods
            if sym["kind"] == "class":
                for method in sym.get("methods", []):
                    rows.append({
                        "rel": rel,
                        "line": method.get("line", 0),
                        "kind": "method",
                        "name": method["name"],
                        "signature": method.get("signature") or method["name"],
                        "exported": False,
                    })
    return rows


def match_file_glob(rel: str, glob: str) -> bool:
    """Match rel path against a glob; if no separator in glob, also match basename."""
    if fnmatch.fnmatch(rel, glob):
        return True
    if "/" not in glob and "\\" not in glob:
        return fnmatch.fnmatch(Path(rel).name, glob)
    return False


def filter_symbols(
    rows: list[dict],
    symbol: str | None,
    kinds: set[str] | None,
    file_glob: str | None,
    exports_only: bool,
) -> list[dict]:
    if file_glob:
        rows = [r for r in rows if match_file_glob(r["rel"], file_glob)]
    if kinds:
        rows = [r for r in rows if r["kind"] in kinds]
    if exports_only:
        rows = [r for r in rows if r["exported"]]
    if symbol:
        # Substring match first (case-insensitive), then fuzzy fallback
        lower = symbol.lower()
        substring_hits = [r for r in rows if lower in r["name"].lower()]
        if substring_hits:
            rows = substring_hits
        else:
            all_names = [r["name"] for r in rows]
            close = set(difflib.get_close_matches(symbol, all_names, n=20, cutoff=0.6))
            rows = [r for r in rows if r["name"] in close]
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description="Query the codebase symbol index")
    parser.add_argument("--symbol", metavar="NAME", help="Fuzzy match symbol name")
    parser.add_argument(
        "--kind",
        metavar="KINDS",
        help="Comma-separated: function, class, method",
    )
    parser.add_argument("--file", metavar="GLOB", help="Filter by file path glob")
    parser.add_argument("--exports", action="store_true", help="Exported symbols only")
    parser.add_argument("--top", metavar="N", type=int, default=50, help="Max results (default 50)")
    args = parser.parse_args()

    data = load_index()
    files = data.get("files", {})
    if not files:
        print("Index is empty — run: python3 scripts/index-codebase.py --full")
        return

    kinds = {k.strip() for k in args.kind.split(",")} if args.kind else None
    rows = flatten_symbols(files)
    rows = filter_symbols(rows, args.symbol, kinds, args.file, args.exports)

    if not rows:
        print("No matches found.")
        return

    rows = rows[: args.top]
    for r in rows:
        print(f"{r['rel']}:{r['line']}: {r['kind']} {r['signature']}")

    if len(rows) == args.top:
        print(f"... (--top {args.top} reached; use --top N to show more)")


if __name__ == "__main__":
    main()
