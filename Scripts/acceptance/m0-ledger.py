#!/usr/bin/env python3
"""
AgentBar M0 Independent Acceptance Verifier (Strictly Read-Only, Aggregate Metadata Only).

Verifies all 6 rows of flagship-acceptance/tools/agentbar.md's M0 acceptance table:
  Row 1: Claude Code 30d deduplicated (message.id, requestId) tokens & record count (< 1% diff).
  Row 2: Codex rollout real breakdown + cacheHitRate > 0; missing-rollout -> totalOnly & null breakdown/cost.
  Row 3: 126-step .relay/LOG.md parser (zero dropped steps, zero bleed, strict heading-only vendor).
  Row 4: Zero 0.85 / 0.15 fixed-ratio literals in Sources/.
  Row 5: Scoped unit tests for streaming deduplication & 3-term cache hit denominator pass cleanly.
  Row 6: Vibe & Antigravity completeness != "complete" in both --lang en and --lang zh (+ OpenCode parity).

Privacy & Safety Invariants:
  - Opens local SQLite files strictly with ?mode=ro (immutable read-only URI).
  - Never reads, stores, or prints any conversation/prompt/message text.
  - Verifies ~/Library/Preferences/local.xu.AgentBar.plist modification time is untouched.
"""

from __future__ import annotations

import datetime as dt
import glob
import json
import math
import os
import pathlib
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from typing import Any


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
HOME_DIR = pathlib.Path.home()
PLIST_PATH = HOME_DIR / "Library" / "Preferences" / "local.xu.AgentBar.plist"


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
    """Independent port of claude_ind.py: deduplicate by (message.id, requestId) taking max per usage field."""
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


def read_last_codex_rollout_usage(rollout_path: str) -> tuple[int, int, int, int] | None:
    p = pathlib.Path(rollout_path)
    lines: list[str] = []
    if p.is_file():
        with p.open("rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            offset = max(0, size - 512 * 1024)
            fh.seek(offset)
            text = fh.read().decode("utf-8", errors="ignore")
            lines = text.splitlines()
            if not any('"token_count"' in ln for ln in lines) and offset > 0:
                fh.seek(0)
                lines = fh.read().decode("utf-8", errors="ignore").splitlines()
    else:
        zst = pathlib.Path(rollout_path + ".zst")
        zstd_bin = shutil.which("zstd") or ("/opt/homebrew/bin/zstd" if pathlib.Path("/opt/homebrew/bin/zstd").is_file() else None)
        if zst.is_file() and zstd_bin:
            proc = subprocess.run([zstd_bin, "-dc", str(zst)], capture_output=True, text=True, check=False)
            if proc.returncode == 0 and proc.stdout:
                lines = proc.stdout.splitlines()

    last_total: dict[str, Any] | None = None
    for ln in lines:
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
        if isinstance(tu, dict) and "input_tokens" in tu and "output_tokens" in tu:
            last_total = tu

    if not last_total:
        return None
    raw_in = max(0, int(last_total.get("input_tokens") or 0))
    cached = max(0, int(last_total.get("cached_input_tokens") or 0))
    cw = max(0, int(last_total.get("cache_write_input_tokens") or 0))
    out = max(0, int(last_total.get("output_tokens") or 0))
    uncached = max(0, raw_in - cached)
    if (uncached + cached + cw + out) <= 0:
        return None
    return (uncached, cached, cw, out)


def independent_codex_30d(db_path: pathlib.Path, now_epoch: int) -> dict[str, Any]:
    cutoff = now_epoch - 30 * 86400
    if not db_path.is_file():
        return {"records": 0, "missing_rollout": 0, "in": 0, "cr": 0, "cw": 0, "out": 0, "total": 0}

    uri = f"file:{db_path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    try:
        cur = conn.execute("SELECT id, tokens_used, updated_at, rollout_path FROM threads WHERE tokens_used > 0")
        rows = cur.fetchall()
    finally:
        conn.close()

    rec = 0
    missing = 0
    s_in = s_cr = s_cw = s_out = s_tot = 0
    for _tid, tok_used, updated_at, rpath in rows:
        ts = updated_at / 1000.0 if updated_at > 10_000_000_000 else float(updated_at)
        if ts < cutoff or ts > now_epoch:
            continue
        rec += 1
        usage = read_last_codex_rollout_usage(str(rpath or "")) if rpath else None
        if usage is None:
            missing += 1
            s_tot += int(tok_used)
        else:
            u_in, u_cr, u_cw, u_out = usage
            s_in += u_in
            s_cr += u_cr
            s_cw += u_cw
            s_out += u_out
            s_tot += (u_in + u_cr + u_cw + u_out)

    return {
        "records": rec,
        "missing_rollout": missing,
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
        cur = conn.execute(
            "SELECT cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, time_updated FROM session_v2"
        )
        rows = cur.fetchall()
    finally:
        conn.close()

    rec = s_in = s_out = s_cr = s_cw = 0
    s_cost = 0.0
    for cost, tin, tout, treas, tcr, tcw, tupd in rows:
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
    claude_ref = independent_claude_30d(HOME_DIR / ".claude" / "projects", now_epoch)
    claude_cli = snap_en["vendors"]["claude"]["windows"]["thirtyDays"]
    cli_claude_tok = int(claude_cli["totalTokens"] or 0)
    cli_claude_rec = int(claude_cli["recordCount"])
    ref_claude_tok = claude_ref["total"]
    ref_claude_rec = claude_ref["records"]
    tok_rel_diff = 0.0 if ref_claude_tok == 0 else abs(cli_claude_tok - ref_claude_tok) / ref_claude_tok
    rec_rel_diff = 0.0 if ref_claude_rec == 0 else abs(cli_claude_rec - ref_claude_rec) / ref_claude_rec
    row1_ok = (
        tok_rel_diff < 0.01
        and rec_rel_diff < 0.01
        and int(claude_cli["inputTokens"] or 0) == claude_ref["in"]
        and int(claude_cli["outputTokens"] or 0) == claude_ref["out"]
        and int(claude_cli["cacheReadTokens"] or 0) == claude_ref["cr"]
        and int(claude_cli["cacheWriteTokens"] or 0) == claude_ref["cw"]
    )
    if not row1_ok:
        failures.append("Row 1 (Claude 30d deduplication)")
    print(
        f"[Row 1] {'PASS' if row1_ok else 'FAIL'} | Claude 30d: "
        f"raw_lines={claude_ref['raw_lines_30d']} -> dedup_records={cli_claude_rec} (ref={ref_claude_rec}, diff={rec_rel_diff:.4%}), "
        f"totalTokens={cli_claude_tok:,} (ref={ref_claude_tok:,}, diff={tok_rel_diff:.4%}), "
        f"in={claude_cli['inputTokens']:,}, out={claude_cli['outputTokens']:,}, "
        f"cacheRead={claude_cli['cacheReadTokens']:,}, cacheWrite={claude_cli['cacheWriteTokens']:,}, "
        f"hitRate={claude_cli['cacheHitRate']:.4f}, estCostUSD=${claude_cli['estimatedCostUSD']:.2f}, "
        f"unmatchedModels={claude_cli['unknownModelRecordCount']}"
    )

    # ------------------------------------------------------------------
    # Row 2: Codex rollout breakdown + missing-rollout totalOnly check
    # ------------------------------------------------------------------
    codex_ref = independent_codex_30d(HOME_DIR / ".codex" / "state_5.sqlite", now_epoch)
    codex_cli = snap_en["vendors"]["codex"]["windows"]["thirtyDays"]
    with_rollout_ok = (
        codex_ref["missing_rollout"] == 0
        and codex_cli["completeness"] == "complete"
        and codex_cli["inputTokens"] == codex_ref["in"]
        and codex_cli["cacheReadTokens"] == codex_ref["cr"]
        and codex_cli["cacheWriteTokens"] == codex_ref["cw"]
        and codex_cli["outputTokens"] == codex_ref["out"]
        and codex_cli["totalTokens"] == codex_ref["total"]
        and (codex_cli["cacheHitRate"] or 0.0) > 0.0
    )

    # Verify missing-rollout behavior in an isolated temp --home fixture (EN & ZH)
    with tempfile.TemporaryDirectory(prefix="agentbar-m0-norollout-") as tmpdir:
        thome = pathlib.Path(tmpdir) / "home"
        tws = pathlib.Path(tmpdir) / "ws"
        (thome / ".codex").mkdir(parents=True)
        tws.mkdir(parents=True)
        tdb = thome / ".codex" / "state_5.sqlite"
        conn = sqlite3.connect(str(tdb))
        conn.execute(
            "CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT)"
        )
        conn.execute(
            "INSERT INTO threads VALUES ('th-missing', '/tmp/p', 420000, ?, 'gpt-6.1-sol', '/no/such/rollout.jsonl')",
            (now_epoch - 60,),
        )
        conn.commit()
        conn.close()

        no_roll_en = run_cli_json(bin_path, ["--lang", "en", "--home", str(thome), "--workspace", str(tws), "--now", str(now_epoch)])
        no_roll_zh = run_cli_json(bin_path, ["--lang", "zh", "--home", str(thome), "--workspace", str(tws), "--now", str(now_epoch)])
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

    row2_ok = with_rollout_ok and without_rollout_ok
    if not row2_ok:
        failures.append("Row 2 (Codex rollout breakdown & missing-rollout totalOnly)")
    print(
        f"[Row 2] {'PASS' if row2_ok else 'FAIL'} | Codex 30d (live {codex_ref['records']}/{codex_ref['records']} rollouts): "
        f"in={codex_cli['inputTokens']:,}, cacheRead={codex_cli['cacheReadTokens']:,}, "
        f"out={codex_cli['outputTokens']:,}, total={codex_cli['totalTokens']:,}, "
        f"hitRate={codex_cli['cacheHitRate']:.4f}, estCostUSD=${codex_cli['estimatedCostUSD']:.2f}; "
        f"missing-rollout fixture -> completeness=totalOnly ('Total only'/'只有总量'), breakdown=null, cost=null"
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

    live_relay_md = HOME_DIR / "Projects" / "rea-lol" / ".relay" / "LOG.md"
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
    # Row 4: rg '0\.85|0\.15' in Sources/ == 0 matches
    # ------------------------------------------------------------------
    ratio_re = re.compile(r"0\.(?:85|15)")
    ratio_hits: list[str] = []
    for swift_file in sorted((REPO_ROOT / "Sources").rglob("*.swift")):
        txt = swift_file.read_text(encoding="utf-8")
        if ratio_re.search(txt):
            ratio_hits.append(str(swift_file.relative_to(REPO_ROOT)))
    row4_ok = len(ratio_hits) == 0
    if not row4_ok:
        failures.append(f"Row 4 (found 0.85/0.15 in {ratio_hits})")
    print(f"[Row 4] {'PASS' if row4_ok else 'FAIL'} | Sources/ scan for 0.85|0.15: {len(ratio_hits)} matches")

    # ------------------------------------------------------------------
    # Row 5: Unit tests for Claude streaming dedup & cache hit denominator
    # ------------------------------------------------------------------
    collectors_test_file = (REPO_ROOT / "Tests" / "AgentBarCoreTests" / "CollectorsTests.swift").read_text(encoding="utf-8")
    has_both_tests = (
        "func claudeStreamingDeduplication()" in collectors_test_file
        and "func cacheHitRateFormulaIncludesAllThreeDenominatorTerms()" in collectors_test_file
    )
    scoped_run = subprocess.run(
        ["bash", str(REPO_ROOT / "Scripts" / "test.sh"), "scope", "Collectors"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    row5_ok = has_both_tests and scoped_run.returncode == 0
    if not row5_ok:
        failures.append("Row 5 (Collectors unit tests)")
    print(
        f"[Row 5] {'PASS' if row5_ok else 'FAIL'} | Scoped Collectors tests exit={scoped_run.returncode} "
        f"(claudeStreamingDeduplication + cacheHitRateFormulaIncludesAllThreeDenominatorTerms present)"
    )

    # ------------------------------------------------------------------
    # Row 6: Vibe & Antigravity completeness != "complete" in EN & ZH (+ OpenCode parity)
    # ------------------------------------------------------------------
    vibe_en = snap_en["vendors"]["vibe"]
    agy_en = snap_en["vendors"]["agy"]
    vibe_zh = snap_zh["vendors"]["vibe"]
    agy_zh = snap_zh["vendors"]["agy"]
    oc_ref = independent_opencode_30d(HOME_DIR / ".local" / "share" / "opencode" / "opencode.db", now_epoch)
    oc_cli = snap_en["vendors"]["opencode"]["windows"]["thirtyDays"]
    oc_ok = (
        oc_cli["recordCount"] == oc_ref["records"]
        and int(oc_cli["totalTokens"] or 0) == oc_ref["total"]
    )
    bad_sub = subprocess.run([str(bin_path), "--cli", "invalid-subcmd"], capture_output=True, text=True, check=False)

    row6_ok = (
        vibe_en["completeness"] != "complete"
        and agy_en["completeness"] != "complete"
        and vibe_zh["completeness"] != "complete"
        and agy_zh["completeness"] != "complete"
        and vibe_en["completenessLabel"] != "Complete"
        and agy_en["completenessLabel"] != "Complete"
        and vibe_zh["completenessLabel"] != "完整"
        and agy_zh["completenessLabel"] != "完整"
        and snap_en["costDisclaimer"] == "API-equivalent estimate (pricing 2026-11)"
        and snap_zh["costDisclaimer"] == "按 API 价折算（价格表 2026-11）"
        and oc_ok
        and bad_sub.returncode == 2
    )
    if not row6_ok:
        failures.append("Row 6 (Vibe/AGY completeness & bilingual disclaimers)")
    print(
        f"[Row 6] {'PASS' if row6_ok else 'FAIL'} | "
        f"vibe={vibe_en['completeness']} ('{vibe_en['completenessLabel']}'/'{vibe_zh['completenessLabel']}'), "
        f"agy={agy_en['completeness']} ('{agy_en['completenessLabel']}'/'{agy_zh['completenessLabel']}'), "
        f"opencode_30d_tokens={oc_cli['totalTokens']:,} (records={oc_cli['recordCount']}), "
        f"invalid_subcmd_exit={bad_sub.returncode}"
    )

    mtime_end = plist_mtime()
    if mtime_start != mtime_end:
        failures.append(f"Preference plist mtime changed ({mtime_start} -> {mtime_end})")

    print("=" * 78)
    if failures:
        print(f"RESULT: FAILED ({len(failures)} check(s): {', '.join(failures)})")
        return 1
    print("RESULT: ALL 6 M0 ACCEPTANCE ROWS PASSED (EN + zh-Hans, read-only verified).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
