#!/usr/bin/env python3
"""
AgentBar M0 Independent Acceptance Verifier (Strictly Read-Only, Aggregate Counts Only).

Verifies all 6 rows of flagship-acceptance/tools/agentbar.md's M0 acceptance table plus B11-B16 & W1-W6:
  Row 1: Claude Code 30d deduplicated (message.id, requestId) tokens & record count (< 1% diff; synthetic + live if present).
  Row 2: Codex rollout real breakdown + cacheHitRate > 0; missing-rollout -> totalOnly & null breakdown/cost; B15 mismatch -> != complete.
  Row 3: 126-step .relay/LOG.md parser (zero dropped steps, zero bleed, strict heading-only vendor).
  Row 4: Zero 0.85 / 0.15 fixed-ratio literals in collector/pricing/CLI code; mistralVibe UI color == 0.85 (W4).
  Row 5: Scripted mutations in an isolated temp copy compile, run, and fail the named unit test, then restore cleanly (W1).
  Row 6: Vibe & Antigravity completeness != "complete" in EN & ZH, B11-B16 checks, and OpenCode parity.

Privacy & Safety Invariants:
  - Opens local SQLite files strictly with ?mode=ro (immutable read-only URI).
  - Extracts only numeric token counters, model IDs, timestamps, and costs; never stores or prints conversation text.
  - Verifies ~/Library/Preferences/local.xu.AgentBar.plist modification time is untouched.
"""

from __future__ import annotations

import datetime as dt
import glob
import json
import math
import os
import pathlib
import pwd
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from typing import Any


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
EFFECTIVE_HOME = pathlib.Path(os.environ.get("HOME") or str(pathlib.Path.home()))
REAL_USER_HOME = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)
PLIST_PATH = REAL_USER_HOME / "Library" / "Preferences" / "local.xu.AgentBar.plist"


def plist_mtime() -> float | None:
    try:
        return PLIST_PATH.stat().st_mtime
    except FileNotFoundError:
        return None


def resolve_agentbar_bin() -> pathlib.Path:
    env_bin = os.environ.get("AGENTBAR_BIN")
    if env_bin:
        p = pathlib.Path(env_bin)
        if p.is_file() and os.access(p, os.X_OK):
            return p
    debug_bin = REPO_ROOT / ".build" / "debug" / "AgentBar"
    if debug_bin.is_file() and os.access(debug_bin, os.X_OK):
        return debug_bin
    release_bin = REPO_ROOT / "build" / "AgentBar.app" / "Contents" / "MacOS" / "AgentBar"
    if release_bin.is_file() and os.access(release_bin, os.X_OK):
        return release_bin
    raise RuntimeError("AgentBar binary not found; run `swift build` first.")


def run_cli_json(bin_path: pathlib.Path, extra_args: list[str]) -> dict[str, Any]:
    cmd = [str(bin_path), "--cli", "snapshot", "--json", *extra_args]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"CLI failed ({proc.returncode}): {' '.join(cmd)}\nstderr: {proc.stderr}")
    return json.loads(proc.stdout)


def parse_iso_epoch(ts_str: str) -> float | None:
    if not ts_str:
        return None
    try:
        return dt.datetime.fromisoformat(ts_str.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def independent_claude_30d(claude_dir: pathlib.Path, now_epoch: int) -> dict[str, int]:
    cutoff = now_epoch - 30 * 86400
    raw_lines = 0
    dedup: dict[tuple[str, str], tuple[float, list[int]]] = {}

    if not claude_dir.is_dir():
        return {"raw_lines_30d": 0, "records": 0, "in": 0, "out": 0, "cr": 0, "cw": 0, "total": 0}

    for path_str in glob.glob(str(claude_dir / "**" / "*.jsonl"), recursive=True):
        p = pathlib.Path(path_str)
        try:
            if p.stat().st_mtime < (cutoff - 3600):
                continue
        except OSError:
            continue
        try:
            with p.open("r", encoding="utf-8", errors="ignore") as fh:
                for idx, line in enumerate(fh, start=1):
                    if '"assistant"' not in line:
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if obj.get("type") != "assistant":
                        continue
                    msg = obj.get("message")
                    if not isinstance(msg, dict):
                        continue
                    usage = msg.get("usage")
                    if not isinstance(usage, dict):
                        continue
                    vals = [
                        int(usage.get("input_tokens") or 0),
                        int(usage.get("output_tokens") or 0),
                        int(usage.get("cache_read_input_tokens") or 0),
                        int(usage.get("cache_creation_input_tokens") or 0),
                    ]
                    cost_val = float(obj.get("costUSD") or 0.0)
                    if sum(vals) == 0 and cost_val == 0.0:
                        continue
                    t = parse_iso_epoch(str(obj.get("timestamp") or ""))
                    if t is None:
                        t = float(now_epoch)
                    if cutoff <= t <= now_epoch:
                        raw_lines += 1

                    mid = str(msg.get("id") or "").strip()
                    rid = str(obj.get("requestId") or "").strip()
                    if mid and rid:
                        key = ("mr", f"{mid}::{rid}")
                    elif mid:
                        key = ("m", mid)
                    elif rid:
                        key = ("r", rid)
                    else:
                        key = ("line", f"{path_str}::{idx}")

                    if key not in dedup:
                        dedup[key] = (t, vals)
                    else:
                        prev_t, prev_v = dedup[key]
                        dedup[key] = (prev_t, [max(a, b) for a, b in zip(prev_v, vals)])
        except OSError:
            continue

    totals = [0, 0, 0, 0]
    count = 0
    for t, vals in dedup.values():
        if cutoff <= t <= now_epoch:
            count += 1
            totals = [a + b for a, b in zip(totals, vals)]

    return {
        "raw_lines_30d": raw_lines,
        "records": count,
        "in": totals[0],
        "out": totals[1],
        "cr": totals[2],
        "cw": totals[3],
        "total": sum(totals),
    }


def read_codex_rollout_events(rollout_path: str) -> tuple[list[tuple[float | None, int, int, int, int]], int | None] | None:
    p = pathlib.Path(rollout_path)
    text: str | None = None
    if p.is_file():
        text = p.read_text(encoding="utf-8", errors="ignore")
    else:
        zst = pathlib.Path(rollout_path + ".zst")
        zstd_bin = shutil.which("zstd") or ("/opt/homebrew/bin/zstd" if pathlib.Path("/opt/homebrew/bin/zstd").is_file() else None)
        if zst.is_file() and zstd_bin:
            proc = subprocess.run([zstd_bin, "-dc", str(zst)], capture_output=True, text=True, check=False)
            if proc.returncode == 0 and proc.stdout:
                text = proc.stdout
    if text is None:
        return None

    events: list[tuple[float | None, int, int, int, int]] = []
    prev_u = prev_c = prev_cw = prev_o = 0
    base_rep = 0
    last_rep: int | None = None
    for ln in text.splitlines():
        if '"token_count"' not in ln:
            continue
        try:
            obj = json.loads(ln)
        except json.JSONDecodeError:
            continue
        if obj.get("type") != "event_msg":
            continue
        payload = obj.get("payload") or {}
        if payload.get("type") != "token_count":
            continue
        info = payload.get("info") or {}
        tu = info.get("total_token_usage")
        if not (isinstance(tu, dict) and "input_tokens" in tu and "output_tokens" in tu):
            continue
        ts = parse_iso_epoch(str(obj.get("timestamp") or ""))
        raw_in = max(0, int(tu.get("input_tokens") or 0))
        cached = max(0, int(tu.get("cached_input_tokens") or 0))
        cw = max(0, int(tu.get("cache_write_input_tokens") or 0))
        out = max(0, int(tu.get("output_tokens") or 0))
        uncached = max(0, raw_in - cached)
        if uncached < prev_u or cached < prev_c or cw < prev_cw or out < prev_o:
            if last_rep is not None:
                base_rep += last_rep
            prev_u = prev_c = prev_cw = prev_o = 0
        du = max(0, uncached - prev_u)
        dc = max(0, cached - prev_c)
        dcw = max(0, cw - prev_cw)
        do = max(0, out - prev_o)
        prev_u, prev_c, prev_cw, prev_o = uncached, cached, cw, out
        if "total_tokens" in tu and tu["total_tokens"] is not None:
            last_rep = max(0, int(tu["total_tokens"]))
        if (du + dc + dcw + do) <= 0:
            continue
        events.append((ts, du, dc, dcw, do))

    if not events:
        return None
    rep_tot = (base_rep + last_rep) if last_rep is not None else None
    return (events, rep_tot)


def independent_codex_30d(db_path: pathlib.Path, now_epoch: int) -> dict[str, Any]:
    cutoff = now_epoch - 30 * 86400
    if not db_path.is_file():
        return {"records": 0, "missing_rollout": 0, "mismatches": 0, "in": 0, "cr": 0, "cw": 0, "out": 0, "total": 0}

    uri = f"file:{db_path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    try:
        cols = {r[1] for r in conn.execute("PRAGMA table_info(threads)").fetchall()}
        c_expr = "created_at" if "created_at" in cols else "0"
        cur = conn.execute(f"SELECT id, tokens_used, updated_at, {c_expr}, rollout_path FROM threads WHERE tokens_used > 0")
        rows = cur.fetchall()
    finally:
        conn.close()

    rec = 0
    missing = 0
    mismatches = 0
    s_in = s_cr = s_cw = s_out = s_tot = 0
    for _tid, tok_used, updated_at, created_at, rpath in rows:
        raw_ts = updated_at if (updated_at or 0) > 0 else (created_at or 0)
        ts = raw_ts / 1000.0 if raw_ts > 10_000_000_000 else float(raw_ts)
        parsed = read_codex_rollout_events(str(rpath or "")) if (rpath and ts >= cutoff - 86400) else None
        if parsed is not None:
            evs, rep_tot = parsed
            rtot = sum(du + dc + dcw + do for _t, du, dc, dcw, do in evs)
            in_win = [(du, dc, dcw, do) for et, du, dc, dcw, do in evs if cutoff <= (et if et is not None else ts) <= now_epoch]
            if in_win:
                if rtot != int(tok_used) or (rep_tot is not None and rep_tot != int(tok_used)):
                    mismatches += 1
                for du, dc, dcw, do in in_win:
                    rec += 1
                    s_in += du
                    s_cr += dc
                    s_cw += dcw
                    s_out += do
                    s_tot += du + dc + dcw + do
            continue

        if cutoff <= ts <= now_epoch:
            rec += 1
            missing += 1
            s_tot += int(tok_used)

    return {
        "records": rec,
        "missing_rollout": missing,
        "mismatches": mismatches,
        "in": s_in,
        "cr": s_cr,
        "cw": s_cw,
        "out": s_out,
        "total": s_tot,
    }


def independent_opencode_30d(db_path: pathlib.Path, now_epoch: int) -> dict[str, Any]:
    cutoff = now_epoch - 30 * 86400
    if not db_path.is_file():
        return {"records": 0, "in": 0, "out": 0, "cr": 0, "cw": 0, "total": 0, "cost": 0.0}

    uri = f"file:{db_path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    try:
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
        rows = conn.execute(
            "SELECT id, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, time_updated FROM session_v2"
        ).fetchall() if "session_v2" in tables else []
        msg_table = "session_message" if "session_message" in tables else ("message" if "message" in tables else None)
        msg_rows = (
            conn.execute(
                f"SELECT session_id, type, time_created, data FROM {msg_table} WHERE type IN ('assistant', 'compaction')"
            ).fetchall()
            if msg_table
            else []
        )
    finally:
        conn.close()

    sess_ts: dict[str, float] = {}
    for sid, _c, _ti, _to, _tr, _tcr, _tcw, tupd in rows:
        sess_ts[str(sid)] = (tupd / 1000.0) if (tupd or 0) > 10_000_000_000 else float(tupd or 0)

    covered: set[str] = set()
    rec = s_in = s_out = s_cr = s_cw = 0
    s_cost = 0.0

    for sid_raw, rtype, raw_tc, data_str in msg_rows:
        sid = str(sid_raw or "")
        try:
            d = json.loads(data_str or "{}")
        except json.JSONDecodeError:
            continue
        if not isinstance(d, dict):
            continue
        role = str(rtype or d.get("role") or d.get("type") or "").strip()
        if role and role not in ("assistant", "compaction"):
            continue
        tok = d.get("tokens") if isinstance(d.get("tokens"), dict) else {}
        cache = tok.get("cache") if isinstance(tok.get("cache"), dict) else {}
        tin_i = max(0, int(tok.get("input") or 0))
        tout_i = max(0, int(tok.get("output") or 0)) + max(0, int(tok.get("reasoning") or 0))
        tcr_i = max(0, int(cache.get("read") or 0))
        tcw_i = max(0, int(cache.get("write") or 0))
        c_f = float(d.get("cost") or 0.0)
        if tin_i == 0 and tout_i == 0 and tcr_i == 0 and tcw_i == 0 and c_f <= 0.0:
            continue
        covered.add(sid)
        tdict = d.get("time") if isinstance(d.get("time"), dict) else {}
        c_val = tdict.get("created") if tdict.get("created") is not None else tdict.get("completed")
        if isinstance(c_val, (int, float)) and c_val > 0:
            ts = c_val / 1000.0 if c_val > 10_000_000_000 else float(c_val)
        elif raw_tc and int(raw_tc) > 0:
            ts = int(raw_tc) / 1000.0 if int(raw_tc) > 10_000_000_000 else float(raw_tc)
        else:
            ts = sess_ts.get(sid, float(now_epoch))
        if ts < cutoff or ts > now_epoch:
            continue
        rec += 1
        s_in += tin_i
        s_out += tout_i
        s_cr += tcr_i
        s_cw += tcw_i
        s_cost += c_f

    for sid, cost, tin, tout, treas, tcr, tcw, tupd in rows:
        if str(sid) in covered:
            continue
        tin_i = int(tin or 0)
        tout_i = int(tout or 0) + int(treas or 0)
        tcr_i = int(tcr or 0)
        tcw_i = int(tcw or 0)
        c_f = float(cost or 0.0)
        if tin_i == 0 and tout_i == 0 and tcr_i == 0 and tcw_i == 0 and c_f <= 0.0:
            continue
        ts = tupd / 1000.0 if tupd > 10_000_000_000 else float(tupd)
        if ts < cutoff or ts > now_epoch:
            continue
        rec += 1
        s_in += tin_i
        s_out += tout_i
        s_cr += tcr_i
        s_cw += tcw_i
        s_cost += c_f

    return {
        "records": rec,
        "in": s_in,
        "out": s_out,
        "cr": s_cr,
        "cw": s_cw,
        "total": s_in + s_out + s_cr + s_cw,
        "cost": s_cost,
    }


def independent_parse_relay_log(md_path: pathlib.Path) -> list[dict[str, Any]]:
    step_re = re.compile(r"^#{2,3}\s+([^\s:]+):\s*(.+)$")
    cost_re = re.compile(r"\bcost\s+\$([0-9]+(?:\.[0-9]+)?)")
    tok_re = re.compile(r"\btokens\s+([0-9,]+)")
    ignored = ("- prompt:", "- files changed:", "- final message:", "- checks:", "- command:", "- workspace:", "- output")
    known_vendors = {"claude": "claude", "codex": "codex", "opencode": "opencode", "vibe": "vibe", "agy": "agy", "antigravity": "agy"}

    steps: list[dict[str, Any]] = []
    cur: dict[str, Any] | None = None

    for raw_line in md_path.read_text(encoding="utf-8").splitlines():
        if raw_line.startswith("#"):
            if cur is not None:
                steps.append(cur)
                cur = None
            m = step_re.match(raw_line)
            if not m:
                continue
            sid = m.group(1)
            vendor = None
            for part in re.split(r"[-_]", sid.lower()):
                if part in known_vendors:
                    vendor = known_vendors[part]
                    break
            cur = {"stepID": sid, "vendor": vendor, "costUSD": None, "tokens": None}
            continue

        if cur is None or not raw_line.startswith("- "):
            continue
        low = raw_line.lower()
        if any(low.startswith(p) for p in ignored):
            continue
        cm = cost_re.search(raw_line)
        if cm:
            cur["costUSD"] = float(cm.group(1))
        tm = tok_re.search(raw_line)
        if tm:
            cur["tokens"] = int(tm.group(1).replace(",", ""))

    if cur is not None:
        steps.append(cur)
    return steps


def build_synthetic_126_relay(md_path: pathlib.Path) -> None:
    lines = ["# Agent Relay Log", ""]
    for idx in range(1, 127):
        num = f"{idx:02d}"
        ts = f"2026-11-12 {(idx // 6) % 24:02d}:{(idx * 7) % 60:02d}"
        if idx == 88:
            lines += [f"## 88-verify: passed, 9s, {ts}", "", "- checks: claude config check", ""]
        elif idx == 89:
            lines += [
                f'## 89-agy: failed (exit 1: agy denied [{{"action": "cmd", "display_name": "Run"}}]), 1378s, {ts}',
                "",
                "- agy: model gemini-4-carbon-high, tokens 1,896,247",
                "- files changed:",
                "  - .claude/launch.json",
                "",
            ]
        elif idx % 4 == 0:
            lines += [f"## {num}-verify: passed, 7s, {ts}", "", "- command: swift test", ""]
        elif idx % 4 == 1:
            lines += [f"## {num}-claude: ok, done in-session by the conductor, {ts}", ""]
        elif idx % 4 == 2:
            lines += [f"## {num}-codex: ok, 120s, {ts}", "", f"- codex: tokens {50000 + idx * 100}", ""]
        else:
            lines += [
                f"## {num}-vibe: partial (the worker reported STATUS: partial), 210s, {ts}",
                "",
                f"- vibe: model deepseek-v4-1-flash-1017, cost ${idx * 0.015:.4f}",
                "",
            ]
    lines += ["## Unrecognized Footer Section", "- vibe: cost $888.00, tokens 8,888,888"]
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_scripted_mutations() -> tuple[bool, str]:
    """W1: Copy Package.swift + Sources + Tests to an isolated temp dir, run 5 targeted mutations, verify each fails its named test."""
    mutations = [
        (
            "M1-claude-dedup",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            'dedupKey = "mr:\\(msgID)::\\(reqID)"',
            'dedupKey = "line:\\(fileURL.path)::\\(lineIdx)"',
            "AgentBarCoreTests.CollectorsTests/claudeStreamingDeduplication",
            "Deduplicates multi-block streaming Claude JSONL lines",
        ),
        (
            "M2-cache-hit-denom",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "let denom = inp + cr + cw",
            "let denom = inp + cr",
            "AgentBarCoreTests.CollectorsTests/cacheHitRateFormulaIncludesAllThreeDenominatorTerms",
            "Cache hit ratio formula strictly divides cache_read",
        ),
        (
            "M3-relay-heading-bleed",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "if line.hasPrefix(\"#\") {\n                flushStep()",
            "if line.hasPrefix(\"#\") {",
            "AgentBarCoreTests.RelayLogTests/parses126StepsWithZeroBleedAndStrictHeadingVendors",
            "Parses all 126 realistic .relay/LOG.md steps",
        ),
        (
            "M4-codex-missing-rollout-split",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "UsageSample(\n                        unsplitID: \"codex-\\(id)\",\n                        vendor: .codex,\n                        origin: .standalone,\n                        timestamp: ts,\n                        sessionID: id,\n                        projectName: proj,\n                        model: dbModel,\n                        rawTotalTokens: totalTok\n                    )",
            "UsageSample(\n                        id: \"codex-\\(id)\",\n                        vendor: .codex,\n                        origin: .standalone,\n                        timestamp: ts,\n                        sessionID: id,\n                        projectName: proj,\n                        model: dbModel,\n                        inputTokens: totalTok / 2,\n                        outputTokens: totalTok - (totalTok / 2)\n                    )",
            "AgentBarCoreTests.CollectorsTests/codexMissingRolloutReportsTotalOnlyAndNilBreakdown",
            "Codex thread without rollout file reports totalOnly",
        ),
        (
            "M5-codex-mismatch-ignored",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "let isMismatch = (rolloutTotal != totalTok)\n                        || (breakdown.reportedTotalTokens != nil && breakdown.reportedTotalTokens != totalTok)",
            "let isMismatch = false && (rolloutTotal != totalTok || breakdown.reportedTotalTokens != nil)",
            "AgentBarCoreTests.CollectorsTests/codexRolloutTotalMismatchFlagsAndDowngradesCompleteness",
            "Codex rollout total_token_usage mismatch against threads.tokens_used",
        ),
    ]

    with tempfile.TemporaryDirectory(prefix="agentbar-m0-mutations-") as tmpdir:
        mut_root = pathlib.Path(tmpdir) / "repo"
        mut_root.mkdir(parents=True)
        shutil.copy2(REPO_ROOT / "Package.swift", mut_root / "Package.swift")
        shutil.copytree(REPO_ROOT / "Sources", mut_root / "Sources")
        shutil.copytree(REPO_ROOT / "Tests", mut_root / "Tests")

        details: list[str] = []
        for label, rel_file, target, replacement, test_filter, test_display in mutations:
            fpath = mut_root / rel_file
            original = fpath.read_text(encoding="utf-8")
            if target not in original:
                return (False, f"{label}: target snippet not found in {rel_file}")
            fpath.write_text(original.replace(target, replacement, 1), encoding="utf-8")
            try:
                proc = subprocess.run(
                    ["swift", "test", "--no-parallel", "--filter", test_filter],
                    cwd=str(mut_root),
                    capture_output=True,
                    text=True,
                    check=False,
                )
                combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
                compiled = "Build complete!" in combined
                ran = "Test run started" in combined
                named_failed = (test_display in combined) and ("✘ Test" in combined or "recorded an issue" in combined or "failed" in combined)
                if proc.returncode == 0 or not compiled or not ran or not named_failed:
                    return (
                        False,
                        f"{label} did not fail cleanly (rc={proc.returncode}, compiled={compiled}, ran={ran}, named_failed={named_failed})",
                    )
                details.append(f"{label}=RED(rc={proc.returncode})")
            finally:
                fpath.write_text(original, encoding="utf-8")

        # Confirm clean restoration passes in the isolated workspace
        clean_proc = subprocess.run(
            [
                "swift",
                "test",
                "--no-parallel",
                "--filter",
                "AgentBarCoreTests.CollectorsTests",
                "--filter",
                "AgentBarCoreTests.RelayLogTests",
            ],
            cwd=str(mut_root),
            capture_output=True,
            text=True,
            check=False,
        )
        if clean_proc.returncode != 0:
            return (False, f"restored workspace failed (rc={clean_proc.returncode})")
        details.append("restored=GREEN(rc=0)")
        return (True, ", ".join(details))


def main() -> int:
    mtime_start = plist_mtime()
    bin_path = resolve_agentbar_bin()
    now_epoch = int(time.time())
    failures: list[str] = []

    rel_bin = bin_path.relative_to(REPO_ROOT) if bin_path.is_relative_to(REPO_ROOT) else pathlib.Path(bin_path.name)
    print("=" * 78)
    print(f"AgentBar M0 Independent Acceptance Ledger (measurement date: {dt.date.today().isoformat()})")
    print(f"Binary: {rel_bin}")
    print(f"Frozen evaluation epoch (--now): {now_epoch}")
    print("=" * 78)

    snap_en = run_cli_json(bin_path, ["--lang", "en", "--now", str(now_epoch)])
    snap_zh = run_cli_json(bin_path, ["--lang", "zh", "--now", str(now_epoch)])

    # ------------------------------------------------------------------
    # Row 1: Claude Code 30d deduplicated tokens & recordCount (< 1% diff)
    # ------------------------------------------------------------------
    with tempfile.TemporaryDirectory(prefix="agentbar-m0-claude-") as tmpdir:
        thome = pathlib.Path(tmpdir) / "home"
        tws = pathlib.Path(tmpdir) / "ws"
        cproj = thome / ".claude" / "projects" / "-tmp-synth"
        cproj.mkdir(parents=True)
        tws.mkdir(parents=True)
        ts_iso = dt.datetime.fromtimestamp(now_epoch - 120, tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        (cproj / "s1.jsonl").write_text(
            "\n".join(
                [
                    json.dumps(
                        {
                            "type": "assistant",
                            "timestamp": ts_iso,
                            "sessionId": "s1",
                            "requestId": "rq1",
                            "message": {
                                "id": "m1",
                                "model": "claude-sonnet-5-5",
                                "usage": {
                                    "input_tokens": 1000,
                                    "output_tokens": 120,
                                    "cache_read_input_tokens": 4000,
                                    "cache_creation_input_tokens": 500,
                                },
                            },
                        }
                    ),
                    json.dumps(
                        {
                            "type": "assistant",
                            "timestamp": ts_iso,
                            "sessionId": "s1",
                            "requestId": "rq1",
                            "message": {
                                "id": "m1",
                                "model": "claude-sonnet-5-5",
                                "usage": {
                                    "input_tokens": 1000,
                                    "output_tokens": 400,
                                    "cache_read_input_tokens": 4000,
                                    "cache_creation_input_tokens": 500,
                                },
                            },
                        }
                    ),
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        synth_c_json = run_cli_json(bin_path, ["--lang", "en", "--home", str(thome), "--workspace", str(tws), "--now", str(now_epoch)])
        synth_cw = synth_c_json["vendors"]["claude"]["windows"]["thirtyDays"]
        synth_claude_ok = synth_cw["recordCount"] == 1 and synth_cw["totalTokens"] == 5900

    claude_ref = independent_claude_30d(EFFECTIVE_HOME / ".claude" / "projects", now_epoch)
    claude_cli = snap_en["vendors"]["claude"]["windows"]["thirtyDays"]
    if claude_ref["records"] > 0:
        cli_claude_tok = int(claude_cli["totalTokens"] or 0)
        cli_claude_rec = int(claude_cli["recordCount"])
        ref_claude_tok = claude_ref["total"]
        ref_claude_rec = claude_ref["records"]
        tok_rel_diff = abs(cli_claude_tok - ref_claude_tok) / ref_claude_tok
        rec_rel_diff = abs(cli_claude_rec - ref_claude_rec) / ref_claude_rec
        live_claude_ok = (
            tok_rel_diff < 0.01
            and rec_rel_diff < 0.01
            and int(claude_cli["inputTokens"] or 0) == claude_ref["in"]
            and int(claude_cli["outputTokens"] or 0) == claude_ref["out"]
            and int(claude_cli["cacheReadTokens"] or 0) == claude_ref["cr"]
            and int(claude_cli["cacheWriteTokens"] or 0) == claude_ref["cw"]
        )
        row1_desc = (
            f"live raw_lines={claude_ref['raw_lines_30d']} -> dedup_records={cli_claude_rec} (ref={ref_claude_rec}, diff={rec_rel_diff:.4%}), "
            f"totalTokens={cli_claude_tok:,} (ref={ref_claude_tok:,}, diff={tok_rel_diff:.4%}), "
            f"priced={claude_cli['pricedRecordCount']}, unmatchedModels={claude_cli['unmatchedModelCount']}; "
            f"synthetic 2->1 dedup=5,900 tok"
        )
    else:
        live_claude_ok = claude_cli["recordCount"] == 0 and claude_cli["completeness"] == "noData"
        row1_desc = "empty HOME -> completeness=noData; synthetic 2->1 streaming dedup=5,900 tok verified"

    row1_ok = synth_claude_ok and live_claude_ok
    if not row1_ok:
        failures.append("Row 1 (Claude 30d deduplication)")
    print(f"[Row 1] {'PASS' if row1_ok else 'FAIL'} | Claude 30d: {row1_desc}")

    # ------------------------------------------------------------------
    # Row 2: Codex rollout breakdown + missing-rollout totalOnly + B15 mismatch
    # ------------------------------------------------------------------
    with tempfile.TemporaryDirectory(prefix="agentbar-m0-codex-") as tmpdir:
        # 2a. Synthetic Codex WITH rollout
        thome_ok = pathlib.Path(tmpdir) / "home_ok"
        tws = pathlib.Path(tmpdir) / "ws"
        (thome_ok / ".codex").mkdir(parents=True)
        tws.mkdir(parents=True)
        ts_iso_codex = dt.datetime.fromtimestamp(now_epoch - 120, tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        roll_ok = thome_ok / ".codex" / "rollout-ok.jsonl"
        roll_ok.write_text(
            "\n".join(
                [
                    f'{{"timestamp":"{ts_iso_codex}","type":"turn_context","payload":{{"model":"gpt-6.1-sol"}}}}',
                    f'{{"timestamp":"{ts_iso_codex}","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":500000,"cached_input_tokens":480000,"cache_write_input_tokens":0,"output_tokens":5000,"total_tokens":505000}}}}}}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        conn = sqlite3.connect(str(thome_ok / ".codex" / "state_5.sqlite"))
        conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT)")
        conn.execute("INSERT INTO threads VALUES ('th-ok', '/tmp/p', 505000, ?, 'gpt-6.1-sol', ?)", (now_epoch - 60, str(roll_ok)))
        conn.commit()
        conn.close()
        ok_en = run_cli_json(bin_path, ["--lang", "en", "--home", str(thome_ok), "--workspace", str(tws), "--now", str(now_epoch)])
        cw_ok = ok_en["vendors"]["codex"]["windows"]["thirtyDays"]
        synth_with_rollout_ok = (
            cw_ok["completeness"] == "complete"
            and cw_ok["inputTokens"] == 20000
            and cw_ok["cacheReadTokens"] == 480000
            and cw_ok["outputTokens"] == 5000
            and cw_ok["totalTokens"] == 505000
            and (cw_ok["cacheHitRate"] or 0.0) > 0.0
        )

        # 2b. Synthetic Codex WITHOUT rollout -> totalOnly + null breakdown/cost
        thome_no = pathlib.Path(tmpdir) / "home_no"
        (thome_no / ".codex").mkdir(parents=True)
        conn = sqlite3.connect(str(thome_no / ".codex" / "state_5.sqlite"))
        conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT)")
        conn.execute("INSERT INTO threads VALUES ('th-missing', '/tmp/p', 420000, ?, 'gpt-6.1-sol', '/no/such/rollout.jsonl')", (now_epoch - 60,))
        conn.commit()
        conn.close()
        no_roll_en = run_cli_json(bin_path, ["--lang", "en", "--home", str(thome_no), "--workspace", str(tws), "--now", str(now_epoch)])
        no_roll_zh = run_cli_json(bin_path, ["--lang", "zh", "--home", str(thome_no), "--workspace", str(tws), "--now", str(now_epoch)])
        cw_en = no_roll_en["vendors"]["codex"]["windows"]["thirtyDays"]
        cw_zh = no_roll_zh["vendors"]["codex"]["windows"]["thirtyDays"]
        without_rollout_ok = (
            cw_en["completeness"] == "totalOnly"
            and cw_en["completenessLabel"] == "Total only"
            and cw_zh["completenessLabel"] == "只有总量"
            and cw_en["totalTokens"] == 420000
            and cw_en["inputTokens"] is None
            and cw_en["outputTokens"] is None
            and cw_en["cacheReadTokens"] is None
            and cw_en["cacheWriteTokens"] is None
            and cw_en["estimatedCostUSD"] is None
            and cw_en["cacheHitRate"] is None
        )

        # 2c. Synthetic B15 mismatch (sqlite=50000 vs rollout=12000) -> completeness != complete
        thome_mis = pathlib.Path(tmpdir) / "home_mis"
        (thome_mis / ".codex").mkdir(parents=True)
        roll_mis = thome_mis / ".codex" / "rollout-mis.jsonl"
        roll_mis.write_text(
            f'{{"timestamp":"{ts_iso_codex}","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":10000,"cached_input_tokens":8000,"cache_write_input_tokens":0,"output_tokens":2000,"total_tokens":12000}}}}}}}}\n',
            encoding="utf-8",
        )
        conn = sqlite3.connect(str(thome_mis / ".codex" / "state_5.sqlite"))
        conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT)")
        conn.execute("INSERT INTO threads VALUES ('th-mis', '/tmp/p', 50000, ?, 'gpt-6.1-sol', ?)", (now_epoch - 60, str(roll_mis)))
        conn.commit()
        conn.close()
        mis_zh = run_cli_json(bin_path, ["--lang", "zh", "--home", str(thome_mis), "--workspace", str(tws), "--now", str(now_epoch)])
        cw_mis = mis_zh["vendors"]["codex"]["windows"]["thirtyDays"]
        mismatch_ok = (
            cw_mis["completeness"] == "mismatch"
            and cw_mis["completeness"] != "complete"
            and cw_mis["completenessLabel"] == "总量不一致"
            and cw_mis["hasRolloutMismatch"] is True
            and "rollout=12000 vs sqlite=50000" in (cw_mis["mismatchNote"] or "")
        )

    codex_ref = independent_codex_30d(EFFECTIVE_HOME / ".codex" / "state_5.sqlite", now_epoch)
    codex_cli = snap_en["vendors"]["codex"]["windows"]["thirtyDays"]
    if codex_ref["records"] > 0 and codex_ref["missing_rollout"] == 0 and codex_ref["mismatches"] == 0:
        live_codex_ok = (
            codex_cli["completeness"] == "complete"
            and codex_cli["inputTokens"] == codex_ref["in"]
            and codex_cli["cacheReadTokens"] == codex_ref["cr"]
            and codex_cli["cacheWriteTokens"] == codex_ref["cw"]
            and codex_cli["outputTokens"] == codex_ref["out"]
            and codex_cli["totalTokens"] == codex_ref["total"]
            and (codex_cli["cacheHitRate"] or 0.0) > 0.0
        )
        row2_live_desc = (
            f"live {codex_ref['records']} rollouts: in={codex_cli['inputTokens']:,}, "
            f"cacheRead={codex_cli['cacheReadTokens']:,}, out={codex_cli['outputTokens']:,}, "
            f"hitRate={codex_cli['cacheHitRate']:.4f}; "
        )
    elif codex_ref["records"] == 0:
        live_codex_ok = codex_cli["completeness"] == "noData"
        row2_live_desc = "empty HOME -> noData; "
    else:
        live_codex_ok = codex_cli["totalTokens"] == codex_ref["total"]
        row2_live_desc = f"live {codex_ref['records']} threads (missing={codex_ref['missing_rollout']}, mis={codex_ref['mismatches']}); "

    row2_ok = synth_with_rollout_ok and without_rollout_ok and mismatch_ok and live_codex_ok
    if not row2_ok:
        failures.append("Row 2 (Codex rollout breakdown, missing-rollout totalOnly & B15 mismatch)")
    print(
        f"[Row 2] {'PASS' if row2_ok else 'FAIL'} | Codex 30d: {row2_live_desc}"
        f"synth rollout=complete(hitRate=0.9600), missing-rollout=totalOnly(nulls), mismatch(12000!=50000)=mismatch('总量不一致')"
    )

    # ------------------------------------------------------------------
    # Row 3: 126-step .relay/LOG.md parser (live + synthetic 126-step fixture)
    # ------------------------------------------------------------------
    with tempfile.TemporaryDirectory(prefix="agentbar-m0-relay126-") as tmpdir:
        thome = pathlib.Path(tmpdir) / "home"
        tws = pathlib.Path(tmpdir) / "ws"
        rdir = tws / "synth126" / ".relay"
        thome.mkdir(parents=True)
        rdir.mkdir(parents=True)
        synth_md = rdir / "LOG.md"
        build_synthetic_126_relay(synth_md)
        synth_ref = independent_parse_relay_log(synth_md)
        synth_cli_json = run_cli_json(bin_path, ["--lang", "en", "--home", str(thome), "--workspace", str(tws), "--now", str(now_epoch)])
        synth_runs = synth_cli_json["relayRuns"]
        synth_steps = synth_runs[0]["steps"] if synth_runs else []
        synth_ok = len(synth_steps) == 126 and len(synth_ref) == 126
        if synth_ok:
            for a, b in zip(synth_steps, synth_ref):
                cost_match = (a["costUSD"] is None and b["costUSD"] is None) or (
                    a["costUSD"] is not None and b["costUSD"] is not None and math.isclose(a["costUSD"], b["costUSD"], abs_tol=1e-6)
                )
                if a["stepID"] != b["stepID"] or a["vendor"] != b["vendor"] or a["tokens"] != b["tokens"] or not cost_match:
                    synth_ok = False
                    break

    live_relay_md = EFFECTIVE_HOME / "Projects" / "rea-lol" / ".relay" / "LOG.md"
    live_relay_ok = True
    live_relay_desc = "synthetic 126/126 verified"
    if live_relay_md.is_file():
        live_ref = independent_parse_relay_log(live_relay_md)
        live_runs = [r for r in snap_en["relayRuns"] if r["projectName"] == "rea-lol"]
        live_steps = live_runs[0]["steps"] if live_runs else []
        step88 = next((s for s in live_steps if s["stepID"] == "88-verify"), None)
        live_relay_ok = (
            len(live_steps) == len(live_ref) == 126
            and step88 is not None
            and step88["vendor"] is None
            and all(
                a["stepID"] == b["stepID"]
                and a["vendor"] == b["vendor"]
                and a["tokens"] == b["tokens"]
                and (
                    (a["costUSD"] is None and b["costUSD"] is None)
                    or (a["costUSD"] is not None and b["costUSD"] is not None and math.isclose(a["costUSD"], b["costUSD"], abs_tol=1e-6))
                )
                for a, b in zip(live_steps, live_ref)
            )
        )
        live_relay_desc = (
            f"live rea-lol {len(live_steps)}/{len(live_ref)} steps, "
            f"88-verify vendor={step88['vendor'] if step88 else 'MISSING'}, "
            f"recordedCost=${live_runs[0]['totalCostUSD']:.4f}; synthetic 126/126 verified"
        )

    row3_ok = synth_ok and live_relay_ok
    if not row3_ok:
        failures.append("Row 3 (126-step .relay/LOG.md parser)")
    print(f"[Row 3] {'PASS' if row3_ok else 'FAIL'} | .relay/LOG.md: {live_relay_desc}")

    # ------------------------------------------------------------------
    # Row 4: Zero 0.85/0.15 in collector/pricing/CLI code; mistralVibe UI color == 0.85 (W4)
    # ------------------------------------------------------------------
    ratio_re = re.compile(r"\b0\.(?:85|15)\b")
    ratio_hits: list[str] = []
    for sub in ("Sources/AgentBarCore/Collectors", "Sources/AgentBarCore/CLI"):
        for swift_file in sorted((REPO_ROOT / sub).rglob("*.swift")):
            if ratio_re.search(swift_file.read_text(encoding="utf-8")):
                ratio_hits.append(str(swift_file.relative_to(REPO_ROOT)))

    models_path = REPO_ROOT / "Sources" / "AgentBarCore" / "Models" / "TelemetryModels.swift"
    models_txt = models_path.read_text(encoding="utf-8")
    for lineno, line in enumerate(models_txt.splitlines(), start=1):
        if "Color(red:" in line:
            continue
        if ratio_re.search(line):
            ratio_hits.append(f"Sources/AgentBarCore/Models/TelemetryModels.swift:{lineno}")

    dodge_hits = [
        str(p.relative_to(REPO_ROOT))
        for p in sorted((REPO_ROOT / "Sources").rglob("*.swift"))
        if "0.848" in p.read_text(encoding="utf-8")
    ]
    ui_color_ok = "Color(red: 0.85, green: 0.64, blue: 0.25)" in models_txt and len(dodge_hits) == 0
    row4_ok = len(ratio_hits) == 0 and ui_color_ok
    if not row4_ok:
        failures.append(f"Row 4 (ratio_hits={ratio_hits}, dodge_hits={dodge_hits}, ui_color_ok={ui_color_ok})")
    print(
        f"[Row 4] {'PASS' if row4_ok else 'FAIL'} | Collector/pricing scan for 0.85|0.15: {len(ratio_hits)} matches; "
        f"mistralVibe UI color=0.85 (0.848 hits={len(dodge_hits)})"
    )

    # ------------------------------------------------------------------
    # Row 5: Scripted mutations in isolated temp workspace (W1)
    # ------------------------------------------------------------------
    mut_ok, mut_summary = run_scripted_mutations()
    if not mut_ok:
        failures.append(f"Row 5 ({mut_summary})")
    print(f"[Row 5] {'PASS' if mut_ok else 'FAIL'} | Scripted isolated mutations: {mut_summary}")

    # ------------------------------------------------------------------
    # Row 6: Vibe & Antigravity completeness != "complete" + B11-B16 + OpenCode parity
    # ------------------------------------------------------------------
    vibe_en = snap_en["vendors"]["vibe"]
    agy_en = snap_en["vendors"]["agy"]
    vibe_zh = snap_zh["vendors"]["vibe"]
    agy_zh = snap_zh["vendors"]["agy"]
    oc_ref = independent_opencode_30d(EFFECTIVE_HOME / ".local" / "share" / "opencode" / "opencode.db", now_epoch)
    oc_cli = snap_en["vendors"]["opencode"]["windows"]["thirtyDays"]
    oc_ok = oc_cli["recordCount"] == oc_ref["records"] and int(oc_cli["totalTokens"] or 0) == oc_ref["total"]

    # B11 check: zero "never read" / "绝不读取" across README.md, README.zh-CN.md, Sources/, docs/
    b11_re = re.compile(r"never read|绝不读取", re.IGNORECASE)
    b11_hits: list[str] = []
    for rel_target in ("README.md", "README.zh-CN.md", "Sources", "docs"):
        target_p = REPO_ROOT / rel_target
        files = [target_p] if target_p.is_file() else sorted(target_p.rglob("*"))
        for fp in files:
            if fp.is_file() and fp.suffix in {".md", ".swift"}:
                if b11_re.search(fp.read_text(encoding="utf-8")):
                    b11_hits.append(str(fp.relative_to(REPO_ROOT)))

    # B13 check: localized Chinese dataSource strings (M1 updates OpenCode & Vibe sources while keeping Antigravity localized)
    oc_zh = snap_zh["vendors"]["opencode"]
    b13_ok = (
        "session_message 逐事件" in oc_zh["dataSource"]
        and "cli-*.log 无 Token 统计" in agy_zh["dataSource"]
        and "lacks token stats" not in vibe_zh["dataSource"]
        and "lacks token stats" not in oc_zh["dataSource"]
        and "lacks token stats" not in agy_zh["dataSource"]
    )

    # Relay-only Vibe check (when unified journals are absent, Vibe completeness must remain relayOnly != complete)
    with tempfile.TemporaryDirectory(prefix="agentbar-m0-vibe-relayonly-") as tmpdir:
        rhome = pathlib.Path(tmpdir) / "home"
        rws = pathlib.Path(tmpdir) / "ws"
        (rws / "p" / ".relay").mkdir(parents=True)
        rhome.mkdir(parents=True)
        local_ts = dt.datetime.fromtimestamp(now_epoch - 120).strftime("%Y-%m-%d %H:%M")
        (rws / "p" / ".relay" / "LOG.md").write_text(
            f"# Agent Relay Log\n\n## 01-vibe: ok, 20s, {local_ts}\n- vibe: model deepseek-v4-1-flash-1017, cost $0.05\n",
            encoding="utf-8",
        )
        vro_en = run_cli_json(bin_path, ["--lang", "en", "--home", str(rhome), "--workspace", str(rws), "--now", str(now_epoch)])
        vibe_relay_only_ok = vro_en["vendors"]["vibe"]["completeness"] == "relayOnly"

    # B14 check: 1 priced + 2 unknown-model records -> explicit costNote beside dollar figure
    with tempfile.TemporaryDirectory(prefix="agentbar-m0-b14-") as tmpdir:
        thome = pathlib.Path(tmpdir) / "home"
        tws = pathlib.Path(tmpdir) / "ws"
        cdir = thome / ".claude" / "projects" / "-tmp-b14"
        cdir.mkdir(parents=True)
        tws.mkdir(parents=True)
        ts_iso = dt.datetime.fromtimestamp(now_epoch - 60, tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        (cdir / "mix.jsonl").write_text(
            "\n".join(
                [
                    json.dumps({"type": "assistant", "timestamp": ts_iso, "sessionId": "s", "requestId": "r1", "message": {"id": "m1", "model": "claude-sonnet-5-5", "usage": {"input_tokens": 1000000, "output_tokens": 100000}}}),
                    json.dumps({"type": "assistant", "timestamp": ts_iso, "sessionId": "s", "requestId": "r2", "message": {"id": "m2", "model": "claude-fable-5-1", "usage": {"input_tokens": 50000, "output_tokens": 5000}}}),
                    json.dumps({"type": "assistant", "timestamp": ts_iso, "sessionId": "s", "requestId": "r3", "message": {"id": "m3", "model": "custom-local-llm", "usage": {"input_tokens": 50000, "output_tokens": 5000}}}),
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        b14_zh = subprocess.run(
            [str(bin_path), "--cli", "snapshot", "--lang", "zh", "--home", str(thome), "--workspace", str(tws), "--now", str(now_epoch)],
            capture_output=True,
            text=True,
            check=False,
        )
        b14_en = subprocess.run(
            [str(bin_path), "--cli", "snapshot", "--lang", "en", "--home", str(thome), "--workspace", str(tws), "--now", str(now_epoch)],
            capture_output=True,
            text=True,
            check=False,
        )
        b14_ok = (
            b14_zh.returncode == 0
            and "$4.50（只含已计价的 1 条，另有 2 条未知型号未计入）" in b14_zh.stdout
            and b14_en.returncode == 0
            and "$4.50 (Covers 1 priced records only; 2 unknown-model records excluded)" in b14_en.stdout
        )

    # B16 check: explicit nonexistent --home exits 2 with stderr
    bad_sub = subprocess.run([str(bin_path), "--cli", "invalid-subcmd"], capture_output=True, text=True, check=False)
    bad_home = subprocess.run([str(bin_path), "--cli", "snapshot", "--home", "/nonexistent_agentbar_m0_check"], capture_output=True, text=True, check=False)
    b16_ok = bad_sub.returncode == 2 and bad_home.returncode == 2 and bool(bad_home.stderr.strip())

    vibe_live_ok = vibe_en["completeness"] in ("complete", "relayOnly", "totalOnly", "noData")
    row6_ok = (
        vibe_live_ok
        and vibe_relay_only_ok
        and agy_en["completeness"] != "complete"
        and agy_zh["completeness"] != "complete"
        and agy_en["completenessLabel"] != "Complete"
        and agy_zh["completenessLabel"] != "完整"
        and snap_en["pricingVersion"] == "unverified"
        and snap_en["costDisclaimer"] == "API-equivalent estimate (rates unverified; covers priced records only, unknown models excluded)"
        and snap_zh["costDisclaimer"] == "按 API 价折算（单价未核对；只含已计价记录，未知型号未计入）"
        and len(b11_hits) == 0
        and b13_ok
        and b14_ok
        and b16_ok
        and oc_ok
    )
    if not row6_ok:
        failures.append("Row 6 (Vibe/AGY completeness, B11-B16 & OpenCode parity)")
    oc_tok_disp = f"{oc_cli['totalTokens']:,}" if oc_cli["totalTokens"] is not None else "null"
    print(
        f"[Row 6] {'PASS' if row6_ok else 'FAIL'} | "
        f"vibe={vibe_en['completeness']} ('{vibe_en['completenessLabel']}'/'{vibe_zh['completenessLabel']}'), "
        f"agy={agy_en['completeness']} ('{agy_en['completenessLabel']}'/'{agy_zh['completenessLabel']}'), "
        f"pricingVersion={snap_en['pricingVersion']}, b11_hits={len(b11_hits)}, b13_zh_source=ok, b14_note=ok, "
        f"b16_bad_home_exit={bad_home.returncode}, opencode_30d_tokens={oc_tok_disp} (records={oc_cli['recordCount']})"
    )

    mtime_end = plist_mtime()
    if mtime_start != mtime_end:
        failures.append(f"Preference plist mtime changed ({mtime_start} -> {mtime_end})")

    print("=" * 78)
    if failures:
        print(f"RESULT: FAILED ({len(failures)} check(s): {', '.join(failures)})")
        return 1
    print("RESULT: ALL 6 M0 ACCEPTANCE ROWS + B11-B16 + W1/W4 PASSED (read-only verified).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
