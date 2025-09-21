#!/usr/bin/env python3
# restore_vscode_history_window_place.py
# Restore each file to the newest save within a TIME WINDOW using VS Code/Cursor Local History (entries.json),
# and place the restored file into the correct spot inside an existing destination tree.
#
# Selection rule:
#   pick the newest entry with timestamp that satisfies:
#       (after_ms is None or ts >= after_ms)  AND  (before_ms is None or ts < before_ms)
# i.e., "saved BEFORE <upper> but AFTER <lower>".
#
# No headers/annotations are written to restored files.

import argparse
import datetime as dt
import json
import os
import pathlib
import sys
from urllib.parse import urlparse, unquote
from collections import defaultdict

# -----------------------------
# Helpers
# -----------------------------

def dequote_and_expand(p: str) -> pathlib.Path:
    if (p.startswith('"') and p.endswith('"')) or (p.startswith("'") and p.endswith("'")):
        p = p[1:-1]
    p = os.path.expandvars(os.path.expanduser(p))
    return pathlib.Path(p)

def parse_when(s: str) -> dt.datetime:
    s = (s or "").strip()
    if not s:
        raise ValueError("empty date string")
    fmts = [
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y/%m/%d %H:%M:%S",
        "%Y/%m/%d %H:%M",
        "%Y-%m-%d",
        "%Y/%m/%d",
    ]
    last_err = None
    for f in fmts:
        try:
            return dt.datetime.strptime(s, f)
        except ValueError as e:
            last_err = e
    raise ValueError(f"Could not parse date/time: {s}. Try 'YYYY-MM-DD HH:MM[:SS]'.")

def to_epoch_ms_local(d: dt.datetime) -> int:
    try:
        return int(d.timestamp() * 1000)
    except OSError:
        return int((d - dt.datetime(1970, 1, 1)).total_seconds() * 1000)

def load_json(path: pathlib.Path):
    try:
        with path.open("r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except json.JSONDecodeError as e:
        print(f"[warn] could not parse JSON: {path} ({e})", file=sys.stderr)
        return None

def resource_uri_to_path(uri: str) -> pathlib.Path:
    # VS Code/Cursor Local History 'resource' looks like file:///Users/... or file:///C:/Users/...
    u = urlparse(uri)
    path = unquote(u.path)
    if os.name == "nt" and len(path) >= 3 and path[0] == "/" and path[2] == ":":
        path = path[1:]
    return pathlib.Path(path)

def common_suffix_len(a_parts, b_parts):
    """Return the length of the common path suffix between two sequences of parts."""
    i = 1
    limit = min(len(a_parts), len(b_parts))
    while i <= limit and a_parts[-i] == b_parts[-i]:
        i += 1
    return i - 1

# -----------------------------
# Destination placement logic
# -----------------------------

class DestPlacer:
    """
    Finds the best destination path inside an existing tree (restore_to) for a given source path.
    Prefers:
      - exact relative mapping under restore_from
      - else: best match by filename and deepest matching directory suffix inside restore_to
      - else: reconstruct relative path based on the anchor folder name
    """

    def __init__(self, restore_from: pathlib.Path, restore_to: pathlib.Path):
        self.restore_from = restore_from.resolve()
        self.restore_from_name = self.restore_from.name
        self.restore_to = restore_to.resolve()
        self._index = None  # built lazily

    def _build_index(self):
        idx = defaultdict(list)  # filename -> [full_path]
        for root, _, files in os.walk(self.restore_to):
            for fn in files:
                idx[fn].append(pathlib.Path(root) / fn)
        self._index = idx

    def _index_candidates(self, filename: str):
        if self._index is None:
            self._build_index()
        return self._index.get(filename, [])

    def choose_dest(self, src_path: pathlib.Path) -> pathlib.Path:
        src_path = src_path.resolve()

        # 1) If src is under restore_from, map by relative path.
        try:
            rel = src_path.relative_to(self.restore_from)
            return (self.restore_to / rel)
        except ValueError:
            pass  # Not under the same absolute tree

        # 2) Find best match in destination by filename + deepest matching path suffix
        candidates = self._index_candidates(src_path.name)
        if candidates:
            src_parents = list(src_path.parents)[:-1]  # exclude the file
            src_parts = [p.name for p in src_parents] + [src_path.name]
            best = None
            best_score = (-1, -1)  # (suffix_len, -distance)

            for cand in candidates:
                cand_parents = list(cand.parents)[:-1]
                cand_parts = [p.name for p in cand_parents] + [cand.name]
                suffix_len = common_suffix_len(src_parts, cand_parts)
                score = (suffix_len, -len(cand_parts))
                if score > best_score:
                    best_score = score
                    best = cand

            if best is not None and best_score[0] > 0:
                return best  # overwrite that candidate in-place

        # 3) Reconstruct relative path starting at the anchor folder name
        parts = list(src_path.parts)
        if self.restore_from_name in parts:
            idx = parts.index(self.restore_from_name)
            rel = pathlib.Path(*parts[idx + 1:]) if idx + 1 < len(parts) else pathlib.Path(src_path.name)
            return self.restore_to / rel

        # 4) Fallback: drop at top level in destination
        return self.restore_to / src_path.name

# -----------------------------
# Core
# -----------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Restore files to the newest save within a time window from VS Code/Cursor Local History, placing them correctly in an existing destination tree."
    )
    parser.add_argument("restore_from", type=str, help="Original project root to match (the source tree in the 'resource' URIs).")
    parser.add_argument("history", type=str, help="History root (e.g., '~/Library/Application Support/Code/User/History' or Cursor workspaceStorage/*/.history).")
    parser.add_argument("restore_to", type=str, help="Destination project root (your current tree to fix in-place).")

    parser.add_argument("--before", type=str, default=None,
                        help="Upper bound (exclusive). Restore each file to the newest snapshot with timestamp < this time "
                             "(e.g., '2025-09-20 10:20:00').")
    parser.add_argument("--after", type=str, default=None,
                        help="Lower bound (inclusive). Restore each file to the newest snapshot with timestamp >= this time.")
    parser.add_argument("--dry-run", action="store_true", help="Plan only; don't write files.")
    parser.add_argument("--max-index-files", type=int, default=200000,
                        help="Safety limit for indexing destination files (default: 200k).")

    args = parser.parse_args()

    history_root = dequote_and_expand(args.history)
    restore_from = dequote_and_expand(args.restore_from).resolve()
    restore_to = dequote_and_expand(args.restore_to).resolve()

    if not history_root.exists():
        print(f"[error] history directory not found: {history_root}", file=sys.stderr)
        sys.exit(1)
    restore_to.mkdir(parents=True, exist_ok=True)

    if not args.before and not args.after:
        print("[error] Provide at least one bound: --before, --after, or both.", file=sys.stderr)
        sys.exit(1)

    before_ms = to_epoch_ms_local(parse_when(args.before)) if args.before else None
    after_ms  = to_epoch_ms_local(parse_when(args.after))  if args.after  else None
    if before_ms is not None and after_ms is not None and after_ms >= before_ms:
        print("[error] --after must be earlier than --before.", file=sys.stderr)
        sys.exit(1)

    # Collect all file histories (VS Code/Cursor: entries.json per file)
    file_histories = []
    for fh in history_root.glob("**/entries.json"):
        data = load_json(fh)
        if not data or "entries" not in data or "resource" not in data:
            continue
        if not data["entries"]:
            continue
        file_histories.append((fh.parent, data))

    if not file_histories:
        print("[warn] no entries.json files found under history root.", file=sys.stderr)
        sys.exit(0)

    placer = DestPlacer(restore_from, restore_to)

    restored_count = 0
    for file_history_folder, data in file_histories:
        src_path = resource_uri_to_path(data["resource"]).resolve()

        # Restrict to files under restore_from (or matching folder name if absolute roots differ)
        in_tree = (restore_from in src_path.parents) or (src_path == restore_from)
        if not in_tree:
            parents_names = {p.name for p in src_path.parents}
            if restore_from.name not in parents_names and src_path.name != restore_from.name:
                continue

        # Sort entries by timestamp ascending (oldest -> newest).
        entries = sorted(data["entries"], key=lambda e: e.get("timestamp", 0))

        # Pick the newest entry that satisfies the window: (ts >= after) AND (ts < before)
        chosen = None
        for e in reversed(entries):
            ts = e.get("timestamp", None)
            if ts is None:
                continue
            if (after_ms is None or ts >= after_ms) and (before_ms is None or ts < before_ms):
                chosen = e
                break

        # If none matched the window, skip this file
        if not chosen:
            continue

        last_id = chosen.get("id")
        if not last_id:
            continue

        code_path = file_history_folder / last_id
        if not code_path.exists():
            alt = file_history_folder / "entries" / last_id
            if alt.exists():
                code_path = alt
            else:
                print(f"[warn] missing content blob for {src_path} ({last_id})", file=sys.stderr)
                continue

        try:
            text = code_path.read_text(encoding="utf-8", errors="replace")
        except Exception as e:
            print(f"[warn] could not read {code_path}: {e}", file=sys.stderr)
            continue

        # Decide destination path *inside the existing destination tree*
        dest_path = placer.choose_dest(src_path)
        dest_path.parent.mkdir(parents=True, exist_ok=True)

        if not args.dry_run:
            try:
                dest_path.write_text(text, encoding="utf-8")
            except Exception as e:
                print(f"[warn] could not write {dest_path}: {e}", file=sys.stderr)
                continue

        action = "WOULD_RESTORE" if args.dry_run else "RESTORED"
        print(f"{action}: {src_path} -> {dest_path}")
        restored_count += 1

    if args.dry_run:
        print(f"\nPlan complete. Would restore {restored_count} file(s) into: {restore_to}")
    else:
        print(f"\nDone. Restored {restored_count} file(s) into: {restore_to}")

if __name__ == "__main__":
    main()
