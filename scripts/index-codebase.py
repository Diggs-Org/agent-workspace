#!/usr/bin/env python3
"""
Codebase symbol indexer. Produces .claude/codebase-index.json.

Usage:
    python3 scripts/index-codebase.py            # re-index only changed files
    python3 scripts/index-codebase.py --full     # force full re-index
    python3 scripts/index-codebase.py --check    # print changed files, no write
    python3 scripts/index-codebase.py --file src/foo.py  # re-index one file
"""
import argparse
import ast
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent
INDEX_PATH = PROJECT_ROOT / ".claude" / "codebase-index.json"
SKIP_DIRS = {
    ".git", "node_modules", "__pycache__", ".claude",
    "dist", "build", ".venv", "venv", "coverage", ".nyc_output",
    ".pytest_cache", ".mypy_cache", ".tox",
}
EXTENSIONS = {".py", ".ts", ".tsx", ".js", ".jsx"}


# ── Hashing ──────────────────────────────────────────────────────────────────

def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:16]


# ── Python parsing ────────────────────────────────────────────────────────────

def _py_signature(node: ast.FunctionDef | ast.AsyncFunctionDef) -> str:
    args = node.args
    parts = []
    # positional args (with defaults aligned from the right)
    n_defaults = len(args.defaults)
    n_args = len(args.args)
    for i, arg in enumerate(args.args):
        default_idx = i - (n_args - n_defaults)
        part = arg.arg
        if arg.annotation:
            part += f": {ast.unparse(arg.annotation)}"
        if default_idx >= 0:
            part += f" = {ast.unparse(args.defaults[default_idx])}"
        parts.append(part)
    if args.vararg:
        a = f"*{args.vararg.arg}"
        if args.vararg.annotation:
            a += f": {ast.unparse(args.vararg.annotation)}"
        parts.append(a)
    for arg in args.kwonlyargs:
        part = arg.arg
        if arg.annotation:
            part += f": {ast.unparse(arg.annotation)}"
        parts.append(part)
    if args.kwarg:
        a = f"**{args.kwarg.arg}"
        if args.kwarg.annotation:
            a += f": {ast.unparse(args.kwarg.annotation)}"
        parts.append(a)
    prefix = "async def" if isinstance(node, ast.AsyncFunctionDef) else "def"
    sig = f"{prefix} {node.name}({', '.join(parts)})"
    if node.returns:
        sig += f" -> {ast.unparse(node.returns)}"
    return sig


def _py_docstring(node) -> str | None:
    if (node.body and isinstance(node.body[0], ast.Expr)
            and isinstance(node.body[0].value, ast.Constant)
            and isinstance(node.body[0].value.value, str)):
        return node.body[0].value.value.strip()
    return None


def parse_python(path: Path) -> dict:
    source = path.read_text(encoding="utf-8", errors="replace")
    try:
        tree = ast.parse(source, filename=str(path))
    except SyntaxError:
        return {"imports": [], "exports": [], "symbols": []}

    imports = []
    symbols = []
    all_names: list[str] | None = None

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imports.append(alias.name)
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                imports.append(node.module)

    for node in tree.body:
        # Check for __all__ = [...]
        if (isinstance(node, ast.Assign)
                and any(isinstance(t, ast.Name) and t.id == "__all__"
                        for t in node.targets)
                and isinstance(node.value, (ast.List, ast.Tuple))):
            all_names = [
                elt.value for elt in node.value.elts
                if isinstance(elt, ast.Constant) and isinstance(elt.value, str)
            ]

        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            symbols.append({
                "kind": "function",
                "name": node.name,
                "line": node.lineno,
                "signature": _py_signature(node),
                "docstring": _py_docstring(node),
            })

        elif isinstance(node, ast.ClassDef):
            methods = []
            for item in node.body:
                if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    methods.append({
                        "kind": "method",
                        "name": item.name,
                        "line": item.lineno,
                        "signature": _py_signature(item),
                        "docstring": _py_docstring(item),
                    })
            symbols.append({
                "kind": "class",
                "name": node.name,
                "line": node.lineno,
                "docstring": _py_docstring(node),
                "methods": methods,
            })

    if all_names is not None:
        exports = all_names
    else:
        exports = [
            s["name"] for s in symbols
            if not s["name"].startswith("_")
        ]

    return {
        "imports": sorted(set(imports)),
        "exports": exports,
        "symbols": symbols,
    }


# ── TypeScript / JavaScript parsing ──────────────────────────────────────────

_TS_IMPORT = re.compile(
    r"""^import\s+.*?from\s+['"]([^'"]+)['"]""",
    re.MULTILINE,
)
_TS_EXPORT_NAME = re.compile(
    r"""^export\s+(?:default\s+)?(?:async\s+)?(?:abstract\s+)?"""
    r"""(?:class|function\*?|const|let|var|interface|type|enum)\s+(\w+)""",
    re.MULTILINE,
)
_TS_FUNCTION = re.compile(
    r"""(?:^|(?<=\n))(?:export\s+)?(?:async\s+)?function\s*\*?\s*(\w+)\s*"""
    r"""(<[^>]*>)?\s*(\([^)]*(?:\([^)]*\)[^)]*)*\))"""
    r"""(?:\s*:\s*([^\{;\n]+))?""",
    re.MULTILINE,
)
_TS_CLASS = re.compile(
    r"""(?:^|(?<=\n))(?:export\s+)?(?:abstract\s+)?class\s+(\w+)""",
    re.MULTILINE,
)
_TS_METHOD = re.compile(
    r"""^\s+(?:(?:public|private|protected|static|async|readonly|override)\s+)*"""
    r"""(\w+)\s*(?:<[^>]*>)?\s*(\([^)]*(?:\([^)]*\)[^)]*)*\))"""
    r"""(?:\s*:\s*([^\{;\n]+))?""",
    re.MULTILINE,
)
_JSDOC = re.compile(r"/\*\*(.*?)\*/\s*$", re.DOTALL)


def _jsdoc_before(source: str, pos: int) -> str | None:
    snippet = source[max(0, pos - 500):pos]
    m = _JSDOC.search(snippet)
    if m:
        lines = [l.strip().lstrip("* ")
                 for l in m.group(1).strip().splitlines()]
        return " ".join(l for l in lines if l and not l.startswith("@")).strip() or None
    return None


def parse_typescript(path: Path) -> dict:
    source = path.read_text(encoding="utf-8", errors="replace")

    imports = [m.group(1) for m in _TS_IMPORT.finditer(source)]
    exports = [m.group(1) for m in _TS_EXPORT_NAME.finditer(source)]
    symbols = []

    # Functions
    for m in _TS_FUNCTION.finditer(source):
        name = m.group(1)
        params = m.group(3) or "()"
        ret = (m.group(4) or "").strip()
        sig = f"function {name}{params}"
        if ret:
            sig += f": {ret}"
        line = source[:m.start()].count("\n") + 1
        symbols.append({
            "kind": "function",
            "name": name,
            "line": line,
            "signature": sig,
            "docstring": _jsdoc_before(source, m.start()),
        })

    # Classes
    for m in _TS_CLASS.finditer(source):
        name = m.group(1)
        line = source[:m.start()].count("\n") + 1
        # Find class body (brace counting)
        brace_start = source.find("{", m.end())
        if brace_start == -1:
            body = ""
        else:
            depth = 0
            end = brace_start
            for i, ch in enumerate(source[brace_start:], brace_start):
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        end = i
                        break
            body = source[brace_start:end]

        methods = []
        for mm in _TS_METHOD.finditer(body):
            mname = mm.group(1)
            if mname in {"if", "for", "while", "switch", "return", "class"}:
                continue
            mparams = mm.group(2) or "()"
            mret = (mm.group(3) or "").strip()
            msig = f"{mname}{mparams}"
            if mret:
                msig += f": {mret}"
            mline = line + body[:mm.start()].count("\n")
            methods.append({
                "kind": "method",
                "name": mname,
                "line": mline,
                "signature": msig,
                "docstring": None,
            })

        symbols.append({
            "kind": "class",
            "name": name,
            "line": line,
            "docstring": _jsdoc_before(source, m.start()),
            "methods": methods,
        })

    return {
        "imports": sorted(set(imports)),
        "exports": sorted(set(exports)),
        "symbols": symbols,
    }


# ── File walker ───────────────────────────────────────────────────────────────

def walk_files(root: Path) -> list[Path]:
    result = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fname in filenames:
            p = Path(dirpath) / fname
            if p.suffix in EXTENSIONS:
                result.append(p)
    return sorted(result)


def index_file(path: Path) -> tuple[str, dict]:
    rel = str(path.relative_to(PROJECT_ROOT))
    h = file_hash(path)
    lang = "python" if path.suffix == ".py" else "typescript"
    parsed = parse_python(path) if lang == "python" else parse_typescript(path)
    return rel, {
        "hash": h,
        "language": lang,
        **parsed,
    }


# ── Brief overview ───────────────────────────────────────────────────────────

def brief_overview(data: dict) -> None:
    files = data.get("files", {})
    if not files:
        print("Index is empty — run: python3 scripts/index-codebase.py --full")
        return

    lang_counts: dict[str, int] = {}
    total_functions = 0
    total_classes = 0
    for entry in files.values():
        lang = entry.get("language", "unknown")
        lang_counts[lang] = lang_counts.get(lang, 0) + 1
        for sym in entry.get("symbols", []):
            if sym["kind"] == "function":
                total_functions += 1
            elif sym["kind"] == "class":
                total_classes += 1
                total_functions += len(sym.get("methods", []))

    changed = []
    for rel, entry in files.items():
        p = PROJECT_ROOT / rel
        if p.exists():
            current = hashlib.sha256(p.read_bytes()).hexdigest()[:16]
            if current != entry.get("hash", ""):
                changed.append(rel)

    generated = data.get("generated_at", "unknown")
    lang_summary = "  ".join(
        f"{lang}: {n}" for lang, n in sorted(lang_counts.items()))
    print(f"Codebase index  generated: {generated}")
    print(f"Files: {len(files)}  |  {lang_summary}")
    print(
        f"Symbols: {total_functions} functions/methods, {total_classes} classes")
    print()
    if changed:
        print(f"Stale ({len(changed)} file(s) need re-index):")
        for f in changed[:5]:
            print(f"  {f}")
        if len(changed) > 5:
            print(f"  ... and {len(changed) - 5} more")
    else:
        print("Index is current — no stale files.")
    print()
    print("Top exports (up to 3 per file):")
    for rel, entry in sorted(files.items())[:10]:
        exports = entry.get("exports", [])[:3]
        if exports:
            print(f"  {rel}: {', '.join(exports)}")


# ── Main ──────────────────────────────────────────────────────────────────────

def load_index() -> dict:
    if INDEX_PATH.exists():
        try:
            return json.loads(INDEX_PATH.read_text())
        except Exception:
            pass
    return {"version": 1, "generated_at": "", "files": {}}


def save_index(data: dict) -> None:
    INDEX_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = INDEX_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2))
    os.replace(tmp, INDEX_PATH)


def main() -> None:
    parser = argparse.ArgumentParser(description="Codebase symbol indexer")
    parser.add_argument("--full", action="store_true",
                        help="Force full re-index")
    parser.add_argument("--check", action="store_true",
                        help="Print changed files, no write")
    parser.add_argument("--file", metavar="PATH",
                        help="Re-index a single file")
    parser.add_argument("--brief", action="store_true",
                        help="Print compact project overview")
    args = parser.parse_args()

    data = load_index()

    if args.brief:
        brief_overview(data)
        return
    existing = data.get("files", {})
    updated = 0
    removed = 0

    if args.file:
        # Single-file mode
        target = Path(args.file)
        if not target.is_absolute():
            target = PROJECT_ROOT / target
        if not target.exists():
            print(f"File not found: {target}", file=sys.stderr)
            sys.exit(1)
        rel, entry = index_file(target)
        existing[rel] = entry
        data["files"] = existing
        data["generated_at"] = datetime.now(timezone.utc).isoformat()
        save_index(data)
        print(f"Indexed: {rel}")
        return

    all_files = walk_files(PROJECT_ROOT)
    all_rels = {str(p.relative_to(PROJECT_ROOT)) for p in all_files}

    # Remove stale entries
    stale = [k for k in existing if k not in all_rels]
    for k in stale:
        del existing[k]
        removed += 1

    changed = []
    for path in all_files:
        rel = str(path.relative_to(PROJECT_ROOT))
        current_hash = file_hash(path)
        stored_hash = existing.get(rel, {}).get("hash", "")
        if args.full or current_hash != stored_hash:
            changed.append(path)

    if args.check:
        if changed:
            print(f"{len(changed)} file(s) changed:")
            for p in changed:
                print(f"  {p.relative_to(PROJECT_ROOT)}")
        else:
            print("Index is up to date.")
        if removed:
            print(f"{removed} stale entries would be removed.")
        return

    for path in changed:
        rel, entry = index_file(path)
        existing[rel] = entry
        updated += 1
        print(f"Indexed: {rel}")

    data["files"] = existing
    data["generated_at"] = datetime.now(timezone.utc).isoformat()
    save_index(data)
    print(f"Done. {updated} updated, {removed} removed, "
          f"{len(existing) - updated} unchanged.")


if __name__ == "__main__":
    main()
