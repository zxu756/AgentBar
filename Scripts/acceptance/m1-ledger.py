#!/usr/bin/env python3
"""
AgentBar M1 Independent Acceptance Verifier (Hand-Calculated Fixture Oracles, Strictly Read-Only).

Verifies all M1 requirements from flagship-acceptance/tools/agentbar.md and
07-tools-m0-review.md (Part 2 + Rework BR1, BR2, BR3) WITHOUT any self-authored
duplicate collector implementation:

  Row 1 (a & b): Cross-day long sessions (Codex .jsonl & .jsonl.zst rollouts, OpenCode
                 session_message + session_v2 fallback, Vibe multi-segment journal +
                 .relay/LOG.md export.json dedup) verified against literal hand-calculated
                 expected dictionaries right beside each fixture.
  Row 2:         14-day x 5-vendor complete 70-cell daily ledger verified against a literal
                 70-cell hand-calculated expected table (0-token / 0.0000% diff).
  Row 3 + BR3:   Rolling 5-hour window [now - 5h, now] and exact-second boundaries
                 (thirtyDaysAgo -/+ 0s, sevenDaysAgo -/+ 0s, prevDayStart, startOfToday -/+ 0s,
                 fiveHoursAgo -/+ 0s, now, now + 1s) verified against literal hand sums.
  Row 4:         Per-day B14 (pricedRecordCount, unmatchedModelCount, bilingual costNote),
                 per-day B15 (hasCodexRolloutMismatch, codexMismatchNote), B7 structured 429
                 vs prose traps, and Antigravity completeness != "complete".
  Row 5 + BR3:   14 scripted isolated mutations in a clean temp workspace (including < -> <=
                 on dayEnd, >= -> > on fiveHoursAgo & sevenDaysAgo, BR1 parsedTS ?? now,
                 Codex session-ts, OpenCode message skip, Vibe action_id dedup removal,
                 prose 429 match, and B12-B17 guards) — all 14 compile, run, and FAIL (RED), then restore GREEN.
  Row 6 (BR1):   Missing & malformed timestamps across all 5 sources contribute 0 tokens and
                 0 records to 5h/today/7d/30d and all 14 dated rows, routing strictly to
                 untimestamped ("No timestamp" / "没有时间").
  Row 7 (BR2):   Pacific/Auckland (--tz Pacific/Auckland) NZDT start day (2026-09-27, 23h),
                 NZDT end day (2027-04-04, 25h + rolling 5h across fall-back), and cross-midnight
                 cases verified against literal hand-calculated expected dictionaries.
  Row 8 (Opt):   Live-host read-only smoke check runs ONLY when AGENTBAR_LIVE_HOST=1; otherwise
                 explicitly recorded as SKIPPED (never counted as passed).

Privacy & Safety Invariants:
  - Opens zero GUI windows and writes zero files under ~/Library.
  - Verifies ~/Library/Preferences/local.xu.AgentBar.plist modification time is untouched.
  - Skipped checks are counted separately and NEVER counted as passed.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import pwd
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from typing import Any


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
EFFECTIVE_HOME = pathlib.Path(os.environ.get("HOME") or str(pathlib.Path.home()))
REAL_USER_HOME = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)
PLIST_PATH = REAL_USER_HOME / "Library" / "Preferences" / "local.xu.AgentBar.plist"
VENDORS = ("claude", "codex", "opencode", "vibe", "agy")


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


def resolve_zstd_bin() -> str | None:
    found = shutil.which("zstd")
    if found:
        return found
    for candidate in ("/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"):
        if pathlib.Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def run_cli(bin_path: pathlib.Path, subcmd: str, extra_args: list[str]) -> str:
    cmd = [str(bin_path), "--cli", subcmd, *extra_args]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"CLI failed ({proc.returncode}): {' '.join(cmd)}\nstderr: {proc.stderr}")
    return proc.stdout


def run_cli_json(bin_path: pathlib.Path, subcmd: str, extra_args: list[str]) -> dict[str, Any]:
    return json.loads(run_cli(bin_path, subcmd, ["--json", *extra_args]))


def iso_to_epoch_s(iso_str: str) -> int:
    return int(dt.datetime.fromisoformat(iso_str.replace("Z", "+00:00")).timestamp())


def iso_to_epoch_ms(iso_str: str) -> int:
    return int(round(dt.datetime.fromisoformat(iso_str.replace("Z", "+00:00")).timestamp() * 1000))


def rel_diff(cli_val: int, exp_val: int) -> float:
    if cli_val == exp_val:
        return 0.0
    denom = max(1, abs(exp_val), abs(cli_val))
    return abs(cli_val - exp_val) / float(denom)


def assert_vendor_cell(
    actual_cell: dict[str, Any],
    expected_tuple: tuple[int, int, int, int, int, int],
    ctx: str,
    mismatches: list[str],
) -> float:
    """Compare (uncached_in, cached_in, cache_write, out, total, records) against literal tuple."""
    exp_in, exp_cr, exp_cw, exp_out, exp_tot, exp_rec = expected_tuple
    checks = (
        ("uncachedInputTokens", exp_in),
        ("cachedInputTokens", exp_cr),
        ("cacheWriteTokens", exp_cw),
        ("outputTokens", exp_out),
        ("totalTokens", exp_tot),
        ("recordCount", exp_rec),
    )
    max_d = 0.0
    for field, exp_v in checks:
        got_v = int(actual_cell[field])
        d = rel_diff(got_v, exp_v)
        max_d = max(max_d, d)
        if got_v != exp_v:
            mismatches.append(f"{ctx}.{field}: got={got_v}, expected={exp_v}")
    return max_d


# ===========================================================================
# Check 1a & 1b: Cross-Day Multi-Turn Sessions (Codex .jsonl & .jsonl.zst,
#                OpenCode session_message + session_v2 fallback, Vibe multi-segment)
# ===========================================================================


def verify_row1_cross_day(bin_path: pathlib.Path) -> tuple[bool, str, bool | None, str]:
    """
    Returns (row1a_ok, row1a_msg, row1b_zst_ok_or_none_if_skipped, row1b_msg).
    All expected values are hand-calculated literals right beside the fixture.
    """
    now_iso = "2026-11-15T18:00:00Z"
    t_d12_ms = iso_to_epoch_ms("2026-11-12T09:00:00Z")
    t_d13_s = iso_to_epoch_s("2026-11-13T10:00:00Z")
    t_d14_s = iso_to_epoch_s("2026-11-14T10:00:00Z")
    t_d15_s = iso_to_epoch_s("2026-11-15T10:00:00Z")
    t_upd_s = iso_to_epoch_s("2026-11-15T17:50:00Z")

    # Hand-calculated literal expected dictionary for Row 1a:
    # Tuple layout: (uncached_in, cached_in, cache_write, output, total, records)
    EXPECTED_ROW1A_BY_DAY: dict[str, dict[str, tuple[int, int, int, int, int, int]]] = {
        "2026-11-12": {
            # OpenCode ses-agg-12 has 0 session_message rows -> falls back to session_v2:
            # 4,000 uncached + 12,000 cache_read + 0 cw + 500 out = 16,500 (1 record)
            "codex": (0, 0, 0, 0, 0, 0),
            "opencode": (4_000, 12_000, 0, 500, 16_500, 1),
            "vibe": (0, 0, 0, 0, 0, 0),
        },
        "2026-11-13": {
            # Codex turn 1 cumulative (in=100k, cr=80k, out=5k) + 1 zero-delta duplicate skipped:
            # uncached = 100k - 80k = 20k; 20k + 80k + 0 + 5k = 105,000 (1 record)
            "codex": (20_000, 80_000, 0, 5_000, 105_000, 1),
            # OpenCode msg m1: 8k + 40k + 0 + 2k = 50,000 (1 record)
            "opencode": (8_000, 40_000, 0, 2_000, 50_000, 1),
            # Vibe journal a1 (in=12k, cached=8k, out=500): uncached = 12k - 8k = 4k -> 12,500 (1 record)
            "vibe": (4_000, 8_000, 0, 500, 12_500, 1),
        },
        "2026-11-14": {
            # Codex turn 2 cumulative (in=250k, cr=200k, out=12k) -> uncached_cum=50k:
            # delta = (50k-20k=30k, 200k-80k=120k, 0, 12k-5k=7k) -> 30k + 120k + 7k = 157,000 (1 record)
            "codex": (30_000, 120_000, 0, 7_000, 157_000, 1),
            # OpenCode msg m2 (compaction): in=10k, cr=65k, cw=0, out=4500+reasoning 500=5k -> 80,000 (1 record)
            "opencode": (10_000, 65_000, 0, 5_000, 80_000, 1),
            # Vibe journal a2 (in=20k, cached=15k, cw=1k, out=1k; replayed in seg 20 -> deduped by action_id):
            # uncached = 20k - 15k = 5k -> 5k + 15k + 1k + 1k = 22,000 (1 record)
            "vibe": (5_000, 15_000, 1_000, 1_000, 22_000, 1),
        },
        "2026-11-15": {
            # Codex turn 3 cumulative (in=310k, cr=240k, out=15k) -> uncached_cum=70k:
            # delta = (70k-50k=20k, 240k-200k=40k, 0, 15k-12k=3k) -> 20k + 40k + 3k = 63,000 (1 record)
            # Rollout 3-day total = 105k + 157k + 63k = 325,000 == threads.tokens_used
            "codex": (20_000, 40_000, 0, 3_000, 63_000, 1),
            # OpenCode msg m3: 12k + 75k + 0 + 3k = 90,000 (1 record)
            "opencode": (12_000, 75_000, 0, 3_000, 90_000, 1),
            # Vibe journal a3 (in=30k, cached=25k, cw=0, out=1k) + .relay/01-vibe.vibe/export.json dedup:
            # uncached = 30k - 25k = 5k -> 5k + 25k + 0 + 1k = 31,000 (1 record; .relay 99,999 NOT double-counted)
            "vibe": (5_000, 25_000, 0, 1_000, 31_000, 1),
        },
    }

    with tempfile.TemporaryDirectory(prefix="agentbar-m1-row1a-") as tmpdir:
        thome = pathlib.Path(tmpdir) / "home"
        tws = pathlib.Path(tmpdir) / "ws"
        (thome / ".codex").mkdir(parents=True)
        (thome / ".local" / "share" / "opencode").mkdir(parents=True)
        v_jdir = thome / ".vibe" / "logs" / "session" / "unified" / "vs-3d" / "journal"
        r_vibe = tws / "demo-pipe" / ".relay" / "01-vibe.vibe"
        v_jdir.mkdir(parents=True)
        r_vibe.mkdir(parents=True)

        roll_3d = thome / ".codex" / "rollout-3d.jsonl"
        roll_3d.write_text(
            "\n".join(
                [
                    '{"timestamp":"2026-11-13T10:00:00Z","type":"turn_context","payload":{"model":"gpt-6-luna"}}',
                    '{"timestamp":"2026-11-13T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100000,"cached_input_tokens":80000,"cache_write_input_tokens":0,"output_tokens":5000,"total_tokens":105000}}}}',
                    '{"timestamp":"2026-11-13T10:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100000,"cached_input_tokens":80000,"cache_write_input_tokens":0,"output_tokens":5000,"total_tokens":105000}}}}',
                    '{"timestamp":"2026-11-14T10:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}',
                    '{"timestamp":"2026-11-14T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250000,"cached_input_tokens":200000,"cache_write_input_tokens":0,"output_tokens":12000,"total_tokens":262000}}}}',
                    '{"timestamp":"2026-11-15T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":310000,"cached_input_tokens":240000,"cache_write_input_tokens":0,"output_tokens":15000,"total_tokens":325000}}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        cx = sqlite3.connect(str(thome / ".codex" / "state_5.sqlite"))
        cx.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT)")
        cx.execute("INSERT INTO threads VALUES ('th-3d', '/tmp/p', 325000, ?, 'gpt-6.1-sol', ?)", (t_upd_s, str(roll_3d)))
        cx.commit()
        cx.close()

        oc = sqlite3.connect(str(thome / ".local" / "share" / "opencode" / "opencode.db"))
        oc.execute(
            "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, model TEXT, time_updated INTEGER)"
        )
        oc.execute(
            "CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT)"
        )
        oc.execute("INSERT INTO session_v2 VALUES ('ses-agg-12', '/tmp/p', 0.02, 4000, 500, 0, 12000, 0, 'deepseek-v4.1-flash', ?)", (t_d12_ms,))
        oc.execute("INSERT INTO session_v2 VALUES ('oc-3d', '/tmp/p', 0.30, 30000, 10000, 0, 180000, 0, 'deepseek-v4.1-flash', ?)", (t_upd_s * 1000,))
        oc_msgs = [
            ("m1", "assistant", 1, t_d13_s * 1000, {"model": {"id": "deepseek-v4.1-flash"}, "cost": 0.08, "time": {"created": t_d13_s * 1000}, "tokens": {"input": 8000, "output": 2000, "reasoning": 0, "cache": {"read": 40000, "write": 0}}}),
            ("m2", "compaction", 2, t_d14_s * 1000, {"model": {"id": "deepseek-v4.1-flash"}, "cost": 0.10, "time": {"created": t_d14_s * 1000}, "tokens": {"input": 10000, "output": 4500, "reasoning": 500, "cache": {"read": 65000, "write": 0}}}),
            ("m3", "assistant", 3, t_d15_s * 1000, {"model": {"id": "deepseek-v4.1-flash"}, "cost": 0.12, "time": {"created": t_d15_s * 1000}, "tokens": {"input": 12000, "output": 3000, "reasoning": 0, "cache": {"read": 75000, "write": 0}}}),
        ]
        for mid, rtype, seq_i, ms, payload in oc_msgs:
            oc.execute("INSERT INTO session_message VALUES (?, 'oc-3d', ?, ?, ?, ?, ?)", (mid, rtype, seq_i, ms, ms, json.dumps(payload)))
        oc.commit()
        oc.close()

        (v_jdir.parent / "meta.json").write_text(
            '{"session_id":"vs-3d","start_time":"2026-11-13T10:00:00Z","config":{"active_model":"deepseek-v4-1-flash-1017"}}\n',
            encoding="utf-8",
        )
        (v_jdir / "0000000000000001.jsonl").write_text(
            "\n".join(
                [
                    json.dumps({"sequence": 1, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": t_d13_s * 1000}}}}),
                    '{"sequence":2,"type":"action_result","payload":{"action_id":"a1","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":12000,"cached_input_tokens":8000,"cache_write_tokens":0,"output_tokens":500,"total_tokens":12500}}}}}',
                    json.dumps({"sequence": 3, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": t_d14_s * 1000}}}}),
                    '{"sequence":4,"type":"action_result","payload":{"action_id":"a2","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":20000,"cached_input_tokens":15000,"cache_write_tokens":1000,"output_tokens":1000,"total_tokens":22000}}}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        (v_jdir / "0000000000000020.jsonl").write_text(
            "\n".join(
                [
                    '{"sequence":20,"type":"action_result","payload":{"action_id":"a2","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":20000,"cached_input_tokens":15000,"cache_write_tokens":1000,"output_tokens":1000,"total_tokens":22000}}}}}',
                    json.dumps({"sequence": 21, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": t_d15_s * 1000}}}}),
                    '{"sequence":22,"type":"action_result","payload":{"action_id":"a3","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":30000,"cached_input_tokens":25000,"cache_write_tokens":0,"output_tokens":1000,"total_tokens":31000}}}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        (r_vibe / "export.json").write_text('{"session_id":"vs-3d"}\n', encoding="utf-8")
        (r_vibe.parent / "LOG.md").write_text(
            "# Agent Relay Log\n\n## 01-vibe: ok, 35s, 2026-11-15 11:00\n- vibe: model deepseek-v4-1-flash-1017, tokens 99,999, cost $0.25\n",
            encoding="utf-8",
        )

        doc = run_cli_json(
            bin_path,
            "snapshot",
            ["--lang", "en", "--tz", "UTC", "--home", str(thome), "--workspace", str(tws), "--now", now_iso],
        )
        by_day = {d["date"]: d for d in doc["dailyBreakdown"]}
        errs: list[str] = []
        max_d = 0.0
        for d_key, v_map in EXPECTED_ROW1A_BY_DAY.items():
            for v_id, exp_t in v_map.items():
                d = assert_vendor_cell(by_day[d_key]["vendors"][v_id], exp_t, f"Row1a[{d_key}].{v_id}", errs)
                max_d = max(max_d, d)
        if doc["vendors"]["codex"]["completeness"] != "complete":
            errs.append(f"codex completeness={doc['vendors']['codex']['completeness']}")
        if doc["vendors"]["vibe"]["completeness"] != "complete":
            errs.append(f"vibe completeness={doc['vendors']['vibe']['completeness']}")

        row1a_ok = len(errs) == 0
        row1a_msg = (
            f"Codex=[105k, 157k, 63k], OpenCode=[16.5k(fb), 50k, 80k, 90k], Vibe=[12.5k, 22k, 31k], max_diff={max_d:.4%}"
            if row1a_ok
            else "; ".join(errs[:5])
        )

    # Subcheck Row 1b: Archived Codex .jsonl.zst cross-day rollout
    zstd_bin = resolve_zstd_bin()
    if zstd_bin is None:
        return (
            row1a_ok,
            row1a_msg,
            None,
            "zstd binary not installed on host; .jsonl.zst subcheck skipped (not counted as passed)",
        )

    # Hand-calculated literal expected dictionary for Row 1b (.jsonl.zst):
    EXPECTED_ROW1B_ZST: dict[str, tuple[int, int, int, int, int, int]] = {
        # Day 2026-11-14 cumulative (in=35k, cr=25k, out=5k) -> uncached=10k, cr=25k, out=5k, total=40k
        "2026-11-14": (10_000, 25_000, 0, 5_000, 40_000, 1),
        # Day 2026-11-15 cumulative (in=80k, cr=55k, out=10k) -> uncached_cum=25k;
        # delta = (25k-10k=15k, 55k-25k=30k, 0, 10k-5k=5k) -> total=50k; 40k + 50k = 90,000 == sqlite
        "2026-11-15": (15_000, 30_000, 0, 5_000, 50_000, 1),
    }

    with tempfile.TemporaryDirectory(prefix="agentbar-m1-row1b-zst-") as tmpdir:
        thome = pathlib.Path(tmpdir) / "home"
        tws = pathlib.Path(tmpdir) / "ws"
        (thome / ".codex").mkdir(parents=True)
        tws.mkdir(parents=True)

        plain_roll = thome / ".codex" / "rollout-2d.jsonl"
        plain_roll.write_text(
            "\n".join(
                [
                    '{"timestamp":"2026-11-14T11:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}',
                    '{"timestamp":"2026-11-14T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":35000,"cached_input_tokens":25000,"cache_write_input_tokens":0,"output_tokens":5000,"total_tokens":40000}}}}',
                    '{"timestamp":"2026-11-15T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80000,"cached_input_tokens":55000,"cache_write_input_tokens":0,"output_tokens":10000,"total_tokens":90000}}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        subprocess.run([zstd_bin, "-q", "-f", str(plain_roll)], check=True)
        plain_roll.unlink()  # Only rollout-2d.jsonl.zst remains on disk

        cx = sqlite3.connect(str(thome / ".codex" / "state_5.sqlite"))
        cx.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT)")
        cx.execute("INSERT INTO threads VALUES ('th-2d-zst', '/tmp/p', 90000, ?, 'gpt-6.1-sol', ?)", (t_upd_s, str(plain_roll)))
        cx.commit()
        cx.close()

        zst_doc = run_cli_json(
            bin_path,
            "snapshot",
            ["--lang", "en", "--tz", "UTC", "--home", str(thome), "--workspace", str(tws), "--now", now_iso],
        )
        nozst_doc = run_cli_json(
            bin_path,
            "snapshot",
            ["--lang", "en", "--tz", "UTC", "--no-zstd", "--home", str(thome), "--workspace", str(tws), "--now", now_iso],
        )
        z_days = {d["date"]: d for d in zst_doc["dailyBreakdown"]}
        z_errs: list[str] = []
        for dk, exp_t in EXPECTED_ROW1B_ZST.items():
            assert_vendor_cell(z_days[dk]["vendors"]["codex"], exp_t, f"Row1b[{dk}].codex", z_errs)
        if zst_doc["vendors"]["codex"]["completeness"] != "complete":
            z_errs.append(f"zst completeness={zst_doc['vendors']['codex']['completeness']}")
        if nozst_doc["vendors"]["codex"]["completeness"] != "totalOnly":
            z_errs.append(f"--no-zstd completeness={nozst_doc['vendors']['codex']['completeness']}")
        if nozst_doc["vendors"]["codex"]["windows"]["thirtyDays"]["totalTokens"] != 90_000:
            z_errs.append("--no-zstd 30d totalTokens != 90000")

        zst_ok = len(z_errs) == 0
        zst_msg = "Codex .jsonl.zst=[40k, 50k] complete & --no-zstd=totalOnly(90k)" if zst_ok else "; ".join(z_errs)
        return (row1a_ok, row1a_msg, zst_ok, zst_msg)


# ===========================================================================
# Check 2: 14-Day x 5-Vendor Complete 70-Cell Daily Ledger (Literal Expected Table)
# ===========================================================================


def verify_row2_14d_70cells(bin_path: pathlib.Path) -> tuple[bool, str]:
    """
    Verifies all 14 days (2026-11-02 .. 2026-11-15) x 5 vendors = 70 cells against an explicit,
    hand-calculated literal dictionary placed right beside the fixture. Zero self-authored collector logic.
    """
    now_iso = "2026-11-15T18:00:00Z"
    ZERO = (0, 0, 0, 0, 0, 0)

    # Explicit hand-calculated 70-cell table: date -> vendor -> (in, cr, cw, out, total, records)
    EXPECTED_70_CELLS: dict[str, dict[str, tuple[int, int, int, int, int, int]]] = {
        "2026-11-02": {
            # Claude streaming 2-chunk max(out 100, 300)=300: 1000 + 4000 + 200 + 300 = 5,500
            "claude": (1_000, 4_000, 200, 300, 5_500, 1),
            # Codex missing-rollout fallback thread th-fb-02 (tokens_used=9,000 -> unsplit totalOnly: breakdown=0s, total=9000)
            "codex": (0, 0, 0, 0, 9_000, 1),
            # OpenCode session_v2-only fallback ses-fb-02: 3000 + 9000 + 0 + 600 = 12,600
            "opencode": (3_000, 9_000, 0, 600, 12_600, 1),
            # Vibe journal seg1 va-02 (in=7000, cr=5000 -> uncached=2000, cw=100, out=400): 2000+5000+100+400 = 7,500
            "vibe": (2_000, 5_000, 100, 400, 7_500, 1),
            # AGY .relay/LOG.md step 02-agy (unsplit tokens 50,000)
            "agy": (0, 0, 0, 0, 50_000, 1),
        },
        "2026-11-03": {
            # Claude turn (2000 + 5000 + 0 + 400 = 7,400) + unknown model (500 + 0 + 0 + 50 = 550) -> 7,950 (2 records)
            "claude": (2_500, 5_000, 0, 450, 7_950, 2),
            # Codex th-long turn 1: uncached=5000, cr=15000, cw=0, out=1000 -> 21,000
            "codex": (5_000, 15_000, 0, 1_000, 21_000, 1),
            "opencode": ZERO,
            "vibe": ZERO,
            "agy": ZERO,
        },
        "2026-11-04": {
            "claude": ZERO,
            # Codex th-long turn 2 delta: uncached=6000, cr=20000, cw=0, out=1500 -> 27,500
            "codex": (6_000, 20_000, 0, 1_500, 27_500, 1),
            # OpenCode msg om-04: 4000 + 16000 + 100 + 800 = 20,900
            "opencode": (4_000, 16_000, 100, 800, 20_900, 1),
            "vibe": ZERO,
            # AGY .relay/LOG.md step 04-agy: 60,000
            "agy": (0, 0, 0, 0, 60_000, 1),
        },
        "2026-11-05": {
            # Claude: 3000 + 6000 + 300 + 500 = 9,800
            "claude": (3_000, 6_000, 300, 500, 9_800, 1),
            "codex": ZERO,
            "opencode": ZERO,
            # Vibe journal seg1 va-05 (in=9000, cr=6000 -> uncached=3000, cw=0, out=500): 9,500
            "vibe": (3_000, 6_000, 0, 500, 9_500, 1),
            "agy": ZERO,
        },
        "2026-11-06": {
            "claude": ZERO,
            # Codex th-long counter reset (new segment cumulative smaller than prev!):
            # uncached=4000, cr=10000, cw=0, out=800 -> 14,800
            "codex": (4_000, 10_000, 0, 800, 14_800, 1),
            # OpenCode msg om-06 (compaction): 5000 + 20000 + 0 + (900+100=1000) = 26,000
            "opencode": (5_000, 20_000, 0, 1_000, 26_000, 1),
            "vibe": ZERO,
            "agy": ZERO,
        },
        "2026-11-07": {
            # Claude: 4000 + 8000 + 0 + 600 = 12,600
            "claude": (4_000, 8_000, 0, 600, 12_600, 1),
            "codex": ZERO,
            "opencode": ZERO,
            # Vibe unlinked .relay/LOG.md step 07-vibe (unsplit tokens 18,000)
            "vibe": (0, 0, 0, 0, 18_000, 1),
            # AGY .relay/LOG.md step 07-agy: 70,000
            "agy": (0, 0, 0, 0, 70_000, 1),
        },
        "2026-11-08": {
            "claude": ZERO,
            # Codex th-long post-reset delta: uncached=7000, cr=18000, cw=0, out=1200 -> 26,200
            "codex": (7_000, 18_000, 0, 1_200, 26_200, 1),
            # OpenCode msg om-08: 6000 + 24000 + 200 + 1100 = 31,300
            "opencode": (6_000, 24_000, 200, 1_100, 31_300, 1),
            "vibe": ZERO,
            "agy": ZERO,
        },
        "2026-11-09": {
            # Claude: 5000 + 10000 + 400 + 700 = 16,100
            "claude": (5_000, 10_000, 400, 700, 16_100, 1),
            "codex": ZERO,
            "opencode": ZERO,
            # Vibe journal seg2 va-09 (in=11000, cr=7500 -> uncached=3500, cw=200, out=600): 11,800
            "vibe": (3_500, 7_500, 200, 600, 11_800, 1),
            "agy": ZERO,
        },
        "2026-11-10": {
            "claude": ZERO,
            "codex": ZERO,
            # OpenCode msg om-10: 7000 + 28000 + 0 + 1400 = 36,400
            "opencode": (7_000, 28_000, 0, 1_400, 36_400, 1),
            "vibe": ZERO,
            # AGY .relay/LOG.md step 10-agy: 80,000
            "agy": (0, 0, 0, 0, 80_000, 1),
        },
        "2026-11-11": {
            # Claude: 6000 + 12000 + 0 + 800 = 18,800
            "claude": (6_000, 12_000, 0, 800, 18_800, 1),
            # Codex th-long delta: uncached=8000, cr=22000, cw=0, out=1600 -> 31,600
            "codex": (8_000, 22_000, 0, 1_600, 31_600, 1),
            "opencode": ZERO,
            "vibe": ZERO,
            "agy": ZERO,
        },
        "2026-11-12": {
            "claude": ZERO,
            "codex": ZERO,
            # OpenCode msg om-12: 8000 + 32000 + 300 + 1600 = 41,900
            "opencode": (8_000, 32_000, 300, 1_600, 41_900, 1),
            # Vibe journal seg2 va-12 (in=14000, cr=10000 -> uncached=4000, cw=0, out=700): 14,700
            "vibe": (4_000, 10_000, 0, 700, 14_700, 1),
            "agy": ZERO,
        },
        "2026-11-13": {
            # Claude: 7000 + 14000 + 500 + 900 = 22,400
            "claude": (7_000, 14_000, 500, 900, 22_400, 1),
            "codex": ZERO,
            "opencode": ZERO,
            "vibe": ZERO,
            # AGY .relay/LOG.md step 13-agy: 90,000
            "agy": (0, 0, 0, 0, 90_000, 1),
        },
        "2026-11-14": {
            "claude": ZERO,
            # Codex th-long delta: uncached=9000, cr=25000, cw=0, out=1900 -> 35,900
            "codex": (9_000, 25_000, 0, 1_900, 35_900, 1),
            # OpenCode msg om-14: 9000 + 36000 + 0 + 1800 = 46,800
            "opencode": (9_000, 36_000, 0, 1_800, 46_800, 1),
            "vibe": ZERO,
            "agy": ZERO,
        },
        "2026-11-15": {
            # Claude: 8000 + 16000 + 600 + 1000 = 25,600
            "claude": (8_000, 16_000, 600, 1_000, 25_600, 1),
            # Codex th-long final delta: uncached=10000, cr=30000, cw=0, out=2000 -> 42,000
            # th-long total across both reset segments = (21000+27500) + (14800+26200+31600+35900+42000) = 48500 + 150500 = 199,000 == sqlite
            "codex": (10_000, 30_000, 0, 2_000, 42_000, 1),
            # OpenCode msg om-15: 10000 + 40000 + 400 + 2000 = 52,400
            "opencode": (10_000, 40_000, 400, 2_000, 52_400, 1),
            # Vibe journal seg2 va-15 (in=16000, cr=11000 -> uncached=5000, cw=300, out=800): 17,100
            "vibe": (5_000, 11_000, 300, 800, 17_100, 1),
            # AGY .relay/LOG.md step 15-agy: 100,000 (cli-*.log contributes 0 tokens!)
            "agy": (0, 0, 0, 0, 100_000, 1),
        },
    }

    with tempfile.TemporaryDirectory(prefix="agentbar-m1-row2-70cells-") as tmpdir:
        shome = pathlib.Path(tmpdir) / "home"
        sws = pathlib.Path(tmpdir) / "ws"
        c_dir = shome / ".claude" / "projects" / "-tmp-14d"
        x_dir = shome / ".codex"
        o_dir = shome / ".local" / "share" / "opencode"
        v_jdir = shome / ".vibe" / "logs" / "session" / "unified" / "vibe-14d" / "journal"
        agy_log_dir = shome / ".gemini" / "antigravity-cli" / "log"
        r_dir = sws / "pipe14" / ".relay" / "01-vibe-linked.vibe"
        for d in (c_dir, x_dir, o_dir, v_jdir, agy_log_dir, r_dir):
            d.mkdir(parents=True, exist_ok=True)

        # 1. Claude JSONL
        (c_dir / "s14.jsonl").write_text(
            "\n".join(
                [
                    # 2026-11-02: 2 streaming chunks for (cm-02, crq-02) -> max out=300
                    '{"type":"assistant","timestamp":"2026-11-02T10:00:00Z","sessionId":"cs1","requestId":"crq-02","message":{"id":"cm-02","model":"claude-sonnet-5-5","usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":4000,"cache_creation_input_tokens":200}}}',
                    '{"type":"assistant","timestamp":"2026-11-02T10:00:01Z","sessionId":"cs1","requestId":"crq-02","message":{"id":"cm-02","model":"claude-sonnet-5-5","usage":{"input_tokens":1000,"output_tokens":300,"cache_read_input_tokens":4000,"cache_creation_input_tokens":200}}}',
                    # 2026-11-03: priced + unknown model
                    '{"type":"assistant","timestamp":"2026-11-03T10:00:00Z","sessionId":"cs1","requestId":"crq-03a","message":{"id":"cm-03a","model":"claude-sonnet-5-5","usage":{"input_tokens":2000,"output_tokens":400,"cache_read_input_tokens":5000,"cache_creation_input_tokens":0}}}',
                    '{"type":"assistant","timestamp":"2026-11-03T10:05:00Z","sessionId":"cs1","requestId":"crq-03u","message":{"id":"cm-03u","model":"claude-fable-5-1","usage":{"input_tokens":500,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}',
                    # 2026-11-05, 07, 09, 11, 13, 15
                    '{"type":"assistant","timestamp":"2026-11-05T10:00:00Z","sessionId":"cs2","requestId":"crq-05","message":{"id":"cm-05","model":"claude-sonnet-5-5","usage":{"input_tokens":3000,"output_tokens":500,"cache_read_input_tokens":6000,"cache_creation_input_tokens":300}}}',
                    '{"type":"assistant","timestamp":"2026-11-07T10:00:00Z","sessionId":"cs2","requestId":"crq-07","message":{"id":"cm-07","model":"claude-sonnet-5-5","usage":{"input_tokens":4000,"output_tokens":600,"cache_read_input_tokens":8000,"cache_creation_input_tokens":0}}}',
                    '{"type":"assistant","timestamp":"2026-11-09T10:00:00Z","sessionId":"cs3","requestId":"crq-09","message":{"id":"cm-09","model":"claude-sonnet-5-5","usage":{"input_tokens":5000,"output_tokens":700,"cache_read_input_tokens":10000,"cache_creation_input_tokens":400}}}',
                    '{"type":"assistant","timestamp":"2026-11-11T10:00:00Z","sessionId":"cs3","requestId":"crq-11","message":{"id":"cm-11","model":"claude-sonnet-5-5","usage":{"input_tokens":6000,"output_tokens":800,"cache_read_input_tokens":12000,"cache_creation_input_tokens":0}}}',
                    '{"type":"assistant","timestamp":"2026-11-13T10:00:00Z","sessionId":"cs4","requestId":"crq-13","message":{"id":"cm-13","model":"claude-sonnet-5-5","usage":{"input_tokens":7000,"output_tokens":900,"cache_read_input_tokens":14000,"cache_creation_input_tokens":500}}}',
                    '{"type":"assistant","timestamp":"2026-11-15T10:00:00Z","sessionId":"cs4","requestId":"crq-15","message":{"id":"cm-15","model":"claude-sonnet-5-5","usage":{"input_tokens":8000,"output_tokens":1000,"cache_read_input_tokens":16000,"cache_creation_input_tokens":600}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        # 2. Codex: th-fb-02 (missing rollout on 2026-11-02) + th-long (with counter reset on 2026-11-06)
        roll_long = x_dir / "rollout-long.jsonl"
        roll_long.write_text(
            "\n".join(
                [
                    # Segment 1 before counter reset:
                    # 2026-11-03: uncached=5k, cr=15k, out=1k -> cum in=20k, cr=15k, out=1k, tot=21k
                    '{"timestamp":"2026-11-03T11:00:00Z","type":"turn_context","payload":{"model":"gpt-6-luna"}}',
                    '{"timestamp":"2026-11-03T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20000,"cached_input_tokens":15000,"cache_write_input_tokens":0,"output_tokens":1000,"total_tokens":21000}}}}',
                    # 2026-11-04: +uncached=6k(11k), +cr=20k(35k), +out=1.5k(2.5k) -> cum in=46k, cr=35k, out=2.5k, tot=48.5k
                    '{"timestamp":"2026-11-04T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":46000,"cached_input_tokens":35000,"cache_write_input_tokens":0,"output_tokens":2500,"total_tokens":48500}}}}',
                    # Segment 2 after counter reset on 2026-11-06 (cumulative drops below previous!):
                    # 2026-11-06: uncached=4k, cr=10k, out=800 -> cum in=14k, cr=10k, out=800, tot=14.8k
                    '{"timestamp":"2026-11-06T11:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}',
                    '{"timestamp":"2026-11-06T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":14000,"cached_input_tokens":10000,"cache_write_input_tokens":0,"output_tokens":800,"total_tokens":14800}}}}',
                    # 2026-11-08: +uncached=7k(11k), +cr=18k(28k), +out=1.2k(2k) -> cum in=39k, cr=28k, out=2k, tot=41k
                    '{"timestamp":"2026-11-08T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":39000,"cached_input_tokens":28000,"cache_write_input_tokens":0,"output_tokens":2000,"total_tokens":41000}}}}',
                    # 2026-11-11: +uncached=8k(19k), +cr=22k(50k), +out=1.6k(3.6k) -> cum in=69k, cr=50k, out=3.6k, tot=72.6k
                    '{"timestamp":"2026-11-11T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":69000,"cached_input_tokens":50000,"cache_write_input_tokens":0,"output_tokens":3600,"total_tokens":72600}}}}',
                    # 2026-11-14: +uncached=9k(28k), +cr=25k(75k), +out=1.9k(5.5k) -> cum in=103k, cr=75k, out=5.5k, tot=108.5k
                    '{"timestamp":"2026-11-14T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":103000,"cached_input_tokens":75000,"cache_write_input_tokens":0,"output_tokens":5500,"total_tokens":108500}}}}',
                    # 2026-11-15: +uncached=10k(38k), +cr=30k(105k), +out=2k(7.5k) -> cum in=143k, cr=105k, out=7.5k, tot=150.5k
                    '{"timestamp":"2026-11-15T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":143000,"cached_input_tokens":105000,"cache_write_input_tokens":0,"output_tokens":7500,"total_tokens":150500}}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        cx = sqlite3.connect(str(x_dir / "state_5.sqlite"))
        cx.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT)")
        cx.execute(
            "INSERT INTO threads VALUES ('th-fb-02', '/tmp/p', 9000, ?, 'gpt-6-luna', '/nonexistent/missing-02.jsonl')",
            (iso_to_epoch_s("2026-11-02T12:00:00Z"),),
        )
        cx.execute(
            "INSERT INTO threads VALUES ('th-long', '/tmp/p', 199000, ?, 'gpt-6.1-sol', ?)",
            (iso_to_epoch_s("2026-11-15T12:00:00Z"), str(roll_long)),
        )
        cx.commit()
        cx.close()

        # 3. OpenCode: ses-fb-02 (fallback on 2026-11-02) + ses-msgs across 04, 06, 08, 10, 12, 14, 15
        oc = sqlite3.connect(str(o_dir / "opencode.db"))
        oc.execute(
            "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, model TEXT, time_updated INTEGER)"
        )
        oc.execute(
            "CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT)"
        )
        oc.execute(
            "INSERT INTO session_v2 VALUES ('ses-fb-02', '/tmp/p', 0.03, 3000, 600, 0, 9000, 0, 'deepseek-v4.1-flash', ?)",
            (iso_to_epoch_ms("2026-11-02T09:00:00Z"),),
        )
        oc.execute(
            "INSERT INTO session_v2 VALUES ('ses-msgs', '/tmp/p', 0.50, 49000, 9700, 0, 196000, 1000, 'deepseek-v4.1-flash', ?)",
            (iso_to_epoch_ms("2026-11-15T15:00:00Z"),),
        )
        oc_rows = [
            ("om-04", "assistant", 1, "2026-11-04T09:30:00Z", 4000, 800, 0, 16000, 100),
            ("om-06", "compaction", 2, "2026-11-06T09:30:00Z", 5000, 900, 100, 20000, 0),
            ("om-08", "assistant", 3, "2026-11-08T09:30:00Z", 6000, 1100, 0, 24000, 200),
            ("om-10", "assistant", 4, "2026-11-10T09:30:00Z", 7000, 1400, 0, 28000, 0),
            ("om-12", "assistant", 5, "2026-11-12T09:30:00Z", 8000, 1600, 0, 32000, 300),
            ("om-14", "assistant", 6, "2026-11-14T09:30:00Z", 9000, 1800, 0, 36000, 0),
            ("om-15", "assistant", 7, "2026-11-15T09:30:00Z", 10000, 2000, 0, 40000, 400),
        ]
        for mid, rtype, seq_i, ts_s, tin, tout, treas, tcr, tcw in oc_rows:
            ms = iso_to_epoch_ms(ts_s)
            data = {
                "model": {"id": "deepseek-v4.1-flash"},
                "cost": 0.05,
                "time": {"created": ms},
                "tokens": {"input": tin, "output": tout, "reasoning": treas, "cache": {"read": tcr, "write": tcw}},
            }
            oc.execute("INSERT INTO session_message VALUES (?, 'ses-msgs', ?, ?, ?, ?, ?)", (mid, rtype, seq_i, ms, ms, json.dumps(data)))
        oc.commit()
        oc.close()

        # 4. Vibe: 2 journal segments + 1 linked export.json (deduped) + 1 unlinked relay step on 2026-11-07
        (shome / ".vibe" / "config.toml").write_text('active_model = "deepseek-v4-1-flash-1017"\n', encoding="utf-8")
        (v_jdir.parent / "meta.json").write_text('{"session_id":"vibe-14d","start_time":"2026-11-02T08:00:00Z","config":{}}\n', encoding="utf-8")
        (v_jdir / "0000000000000001.jsonl").write_text(
            "\n".join(
                [
                    json.dumps({"sequence": 1, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": iso_to_epoch_ms("2026-11-02T08:00:00Z")}}}}),
                    '{"sequence":2,"type":"action_result","payload":{"action_id":"va-02","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":7000,"cached_input_tokens":5000,"cache_write_tokens":100,"output_tokens":400,"total_tokens":7500}}}}}',
                    json.dumps({"sequence": 3, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": iso_to_epoch_ms("2026-11-05T08:00:00Z")}}}}),
                    '{"sequence":4,"type":"action_result","payload":{"action_id":"va-05","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":9000,"cached_input_tokens":6000,"cache_write_tokens":0,"output_tokens":500,"total_tokens":9500}}}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        (v_jdir / "0000000000000050.jsonl").write_text(
            "\n".join(
                [
                    # Replay va-05 across segment boundary -> must be deduplicated
                    '{"sequence":50,"type":"action_result","payload":{"action_id":"va-05","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":9000,"cached_input_tokens":6000,"cache_write_tokens":0,"output_tokens":500,"total_tokens":9500}}}}}',
                    json.dumps({"sequence": 51, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": iso_to_epoch_ms("2026-11-09T08:00:00Z")}}}}),
                    '{"sequence":52,"type":"action_result","payload":{"action_id":"va-09","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":11000,"cached_input_tokens":7500,"cache_write_tokens":200,"output_tokens":600,"total_tokens":11800}}}}}',
                    json.dumps({"sequence": 53, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": iso_to_epoch_ms("2026-11-12T08:00:00Z")}}}}),
                    '{"sequence":54,"type":"action_result","payload":{"action_id":"va-12","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":14000,"cached_input_tokens":10000,"cache_write_tokens":0,"output_tokens":700,"total_tokens":14700}}}}}',
                    json.dumps({"sequence": 55, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": iso_to_epoch_ms("2026-11-15T08:00:00Z")}}}}),
                    '{"sequence":56,"type":"action_result","payload":{"action_id":"va-15","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":16000,"cached_input_tokens":11000,"cache_write_tokens":300,"output_tokens":800,"total_tokens":17100}}}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        (r_dir / "export.json").write_text('{"session_id":"vibe-14d"}\n', encoding="utf-8")

        # 5. Antigravity cli-*.log (active model only, 0 tokens) + .relay/LOG.md
        (agy_log_dir / "cli-1.log").write_text('INFO override to backend: label="gemini-4-carbon-high"\n', encoding="utf-8")
        (r_dir.parent / "LOG.md").write_text(
            "\n".join(
                [
                    "# Agent Relay Log",
                    "",
                    "## 01-vibe-linked: ok, 30s, 2026-11-15 08:05",
                    "- vibe: model deepseek-v4-1-flash-1017, tokens 77,777, cost $0.20",
                    "",
                    "## 02-agy: ok, 40s, 2026-11-02 14:00",
                    "- agy: model gemini-4-carbon-high, tokens 50,000",
                    "",
                    "## 04-agy: ok, 40s, 2026-11-04 14:00",
                    "- agy: model gemini-4-carbon-high, tokens 60,000",
                    "",
                    "## 07-vibe: ok, 25s, 2026-11-07 13:00",
                    "- vibe: model deepseek-v4-1-flash-1017, tokens 18,000, cost $0.04",
                    "",
                    "## 07-agy: ok, 40s, 2026-11-07 14:00",
                    "- agy: model gemini-4-carbon-high, tokens 70,000",
                    "",
                    "## 10-agy: ok, 40s, 2026-11-10 14:00",
                    "- agy: model gemini-4-carbon-high, tokens 80,000",
                    "",
                    "## 13-agy: ok, 40s, 2026-11-13 14:00",
                    "- agy: model gemini-4-carbon-high, tokens 90,000",
                    "",
                    "## 15-agy: ok, 40s, 2026-11-15 14:00:30",
                    "- agy: model gemini-4-carbon-high, tokens 100,000",
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        daily_doc = run_cli_json(
            bin_path,
            "daily",
            ["--lang", "en", "--tz", "UTC", "--home", str(shome), "--workspace", str(sws), "--now", now_iso],
        )
        cli_days = {d["date"]: d for d in daily_doc["dailyBreakdown"]}
        errs: list[str] = []
        if set(cli_days.keys()) != set(EXPECTED_70_CELLS.keys()):
            return (False, f"date keys mismatch: got={sorted(cli_days.keys())}")

        max_d = 0.0
        cells = 0
        for dk, v_map in EXPECTED_70_CELLS.items():
            row_tot_exp = sum(t[4] for t in v_map.values())
            row_rec_exp = sum(t[5] for t in v_map.values())
            if int(cli_days[dk]["totalTokens"]) != row_tot_exp:
                errs.append(f"{dk}.totalTokens: got={cli_days[dk]['totalTokens']}, expected={row_tot_exp}")
            if int(cli_days[dk]["recordCount"]) != row_rec_exp:
                errs.append(f"{dk}.recordCount: got={cli_days[dk]['recordCount']}, expected={row_rec_exp}")
            for v_id in VENDORS:
                cells += 1
                d = assert_vendor_cell(cli_days[dk]["vendors"][v_id], v_map[v_id], f"Row2[{dk}].{v_id}", errs)
                max_d = max(max_d, d)

        ok = len(errs) == 0 and max_d == 0.0
        msg = (
            f"{cells}/70 day x vendor cells matched literal hand-calculated ledger with max_diff={max_d:.4%}"
            if ok
            else "; ".join(errs[:6])
        )
        return (ok, msg)


# ===========================================================================
# Check 3 (Row 3 + BR3): Rolling fiveHours [now - 5h, now] & Exact Second Boundaries
# ===========================================================================


def verify_row3_and_br3_exact_boundaries(bin_path: pathlib.Path) -> tuple[bool, str]:
    """
    Places events at exact 1-second boundary offsets around thirtyDaysAgo, sevenDaysAgo,
    prevDayStart, startOfToday, fiveHoursAgo, and now (with session updated_at = 10m ago).
    """
    # Frozen now = 2026-11-15T12:00:00Z
    #   thirtyDaysAgo = 2026-10-16T12:00:00Z
    #   sevenDaysAgo  = 2026-11-08T12:00:00Z
    #   prevDayStart  = 2026-11-14T00:00:00Z
    #   startOfToday  = 2026-11-15T00:00:00Z (== nextDayStart of 2026-11-14)
    #   fiveHoursAgo  = 2026-11-15T07:00:00Z (now - 18,000s)
    now_iso = "2026-11-15T12:00:00Z"
    upd_10m_s = iso_to_epoch_s("2026-11-15T11:50:00Z")

    # Hand-calculated literal expected values:
    EXPECTED_CLAUDE_WINDOWS = {
        # fiveHours [07:00:00Z, 12:00:00Z]: 256,000 + 512,000 = 768,000 (excludes 128k at 06:59:59Z & 1,024k at 12:00:01Z)
        "fiveHours": (768_000, 2),
        # today [00:00:00Z, 12:00:00Z]: 64,000 + 128,000 + 256,000 + 512,000 = 960,000 (excludes 32k at 23:59:59Z)
        "today": (960_000, 4),
        # sevenDays [2026-11-08T12:00:00Z, 12:00:00Z]: 8,000 + 16,000 + 32,000 + 960,000 = 1,016,000 (excludes 4k at 11:59:59Z)
        "sevenDays": (1_016_000, 7),
        # thirtyDays [2026-10-16T12:00:00Z, 12:00:00Z]: 2,000 + 4,000 + 1,016,000 = 1,022,000 (excludes 1k at 11:59:59Z)
        "thirtyDays": (1_022_000, 9),
    }
    EXPECTED_CLAUDE_DAYS = {
        "2026-11-13": 0,       # Must NOT get prevDayStart (16,000)
        "2026-11-14": 48_000,  # 16,000 + 32,000 = 48,000 (Must NOT get startOfToday = 64,000)
        "2026-11-15": 960_000, # 64,000 + 128,000 + 256,000 + 512,000 = 960,000 (excludes future 1,024,000)
    }
    EXPECTED_OTHER_5H = {
        # Each vendor has 1 turn at 06:59:59Z (fiveHoursAgo - 1s, excluded) and 1 turn at 07:00:00Z (fiveHoursAgo, included)
        "codex": 40_000,     # excludes 50k at 06:59:59Z, includes 40k delta at 07:00:00Z
        "opencode": 30_000,  # excludes 25k at 06:59:59Z, includes 30k at 07:00:00Z
        "vibe": 9_000,       # excludes 15k at 06:59:59Z, includes 9k at 07:00:00Z
    }

    with tempfile.TemporaryDirectory(prefix="agentbar-m1-row3-br3-") as tmpdir:
        thome = pathlib.Path(tmpdir) / "home"
        tws = pathlib.Path(tmpdir) / "ws"
        c_p = thome / ".claude" / "projects" / "-tmp-br3"
        x_p = thome / ".codex"
        o_p = thome / ".local" / "share" / "opencode"
        v_p = thome / ".vibe" / "logs" / "session" / "unified" / "v-5h" / "journal"
        for d in (c_p, x_p, o_p, v_p, tws):
            d.mkdir(parents=True, exist_ok=True)

        claude_events = [
            ("2026-10-16T11:59:59Z", 1_000),
            ("2026-10-16T12:00:00Z", 2_000),
            ("2026-11-08T11:59:59Z", 4_000),
            ("2026-11-08T12:00:00Z", 8_000),
            ("2026-11-14T00:00:00Z", 16_000),
            ("2026-11-14T23:59:59Z", 32_000),
            ("2026-11-15T00:00:00Z", 64_000),
            ("2026-11-15T06:59:59Z", 128_000),
            ("2026-11-15T07:00:00Z", 256_000),
            ("2026-11-15T12:00:00Z", 512_000),
            ("2026-11-15T12:00:01Z", 1_024_000),
        ]
        (c_p / "br3.jsonl").write_text(
            "\n".join(
                json.dumps(
                    {
                        "type": "assistant",
                        "timestamp": ts_s,
                        "sessionId": "s-br3",
                        "requestId": f"rq-{i}",
                        "message": {"id": f"m-{i}", "model": "claude-sonnet-5-5", "usage": {"input_tokens": tok, "output_tokens": 0}},
                    }
                )
                for i, (ts_s, tok) in enumerate(claude_events)
            )
            + "\n",
            encoding="utf-8",
        )

        roll5 = x_p / "roll5.jsonl"
        roll5.write_text(
            "\n".join(
                [
                    '{"timestamp":"2026-11-15T06:59:59Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}',
                    '{"timestamp":"2026-11-15T06:59:59Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":48000,"cached_input_tokens":40000,"cache_write_input_tokens":0,"output_tokens":2000,"total_tokens":50000}}}}',
                    '{"timestamp":"2026-11-15T07:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":86000,"cached_input_tokens":70000,"cache_write_input_tokens":0,"output_tokens":4000,"total_tokens":90000}}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        cx = sqlite3.connect(str(x_p / "state_5.sqlite"))
        cx.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT)")
        cx.execute("INSERT INTO threads VALUES ('th5', '/tmp/p', 90000, ?, 'gpt-6.1-sol', ?)", (upd_10m_s, str(roll5)))
        cx.commit()
        cx.close()

        oc = sqlite3.connect(str(o_p / "opencode.db"))
        oc.execute("CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, model TEXT, time_updated INTEGER)")
        oc.execute("CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT)")
        oc.execute("INSERT INTO session_v2 VALUES ('s5', '/tmp/p', 0.1, 10000, 5000, 0, 40000, 0, 'deepseek-v4.1-flash', ?)", (upd_10m_s * 1000,))
        for i, (ts_s, cr_tok) in enumerate([("2026-11-15T06:59:59Z", 20_000), ("2026-11-15T07:00:00Z", 25_000)], start=1):
            ms = iso_to_epoch_ms(ts_s)
            oc.execute(
                "INSERT INTO session_message VALUES (?, 's5', 'assistant', ?, ?, ?, ?)",
                (f"om-{i}", i, ms, ms, json.dumps({"model": {"id": "deepseek-v4.1-flash"}, "cost": 0.05, "time": {"created": ms}, "tokens": {"input": 3000, "output": 2000, "reasoning": 0, "cache": {"read": cr_tok, "write": 0}}})),
            )
        oc.commit()
        oc.close()

        (v_p.parent / "meta.json").write_text(
            '{"session_id":"v-5h","start_time":"2026-11-15T06:59:59Z","end_time":"2026-11-15T11:50:00Z","config":{"active_model":"deepseek-v4-1-flash-1017"}}\n',
            encoding="utf-8",
        )
        (v_p / "0000000000000001.jsonl").write_text(
            "\n".join(
                [
                    json.dumps({"sequence": 1, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": iso_to_epoch_ms("2026-11-15T06:59:59Z")}}}}),
                    '{"sequence":2,"type":"action_result","payload":{"action_id":"v1","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":14000,"cached_input_tokens":10000,"cache_write_tokens":0,"output_tokens":1000,"total_tokens":15000}}}}}',
                    json.dumps({"sequence": 3, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": iso_to_epoch_ms("2026-11-15T07:00:00Z")}}}}),
                    '{"sequence":4,"type":"action_result","payload":{"action_id":"v2","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":8000,"cached_input_tokens":6000,"cache_write_tokens":0,"output_tokens":1000,"total_tokens":9000}}}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        doc = run_cli_json(
            bin_path,
            "snapshot",
            ["--lang", "en", "--tz", "UTC", "--home", str(thome), "--workspace", str(tws), "--now", now_iso],
        )
        errs: list[str] = []
        cw = doc["vendors"]["claude"]["windows"]
        for w_name, (exp_tok, exp_rec) in EXPECTED_CLAUDE_WINDOWS.items():
            if cw[w_name]["totalTokens"] != exp_tok or cw[w_name]["recordCount"] != exp_rec:
                errs.append(f"claude.{w_name}: got=({cw[w_name]['totalTokens']},{cw[w_name]['recordCount']}), exp=({exp_tok},{exp_rec})")
        c_days = {d["date"]: d["vendors"]["claude"]["totalTokens"] for d in doc["dailyBreakdown"]}
        for dk, exp_tok in EXPECTED_CLAUDE_DAYS.items():
            if c_days[dk] != exp_tok:
                errs.append(f"claude.day[{dk}]: got={c_days[dk]}, exp={exp_tok}")
        for v_id, exp_5h in EXPECTED_OTHER_5H.items():
            got_5h = doc["vendors"][v_id]["windows"]["fiveHours"]["totalTokens"]
            if got_5h != exp_5h:
                errs.append(f"{v_id}.fiveHours: got={got_5h}, exp={exp_5h}")

        ok = len(errs) == 0
        msg = (
            "Exact second boundaries verified: claude(5h=768k, today=960k, 7d=1,016k, 30d=1,022k, d13=0, d14=48k, d15=960k), "
            "codex_5h=40k, opencode_5h=30k, vibe_5h=9k"
            if ok
            else "; ".join(errs)
        )
        return (ok, msg)


# ===========================================================================
# Check 4 (Row 4): Per-Day B14 Pricing, Per-Day B15 Mismatch, Structured B7 429
# ===========================================================================


def verify_row4_b14_b15_b7(bin_path: pathlib.Path) -> tuple[bool, str]:
    now_iso = "2026-11-15T12:00:00Z"
    t_curr_s = iso_to_epoch_s("2026-11-15T09:00:00Z")

    with tempfile.TemporaryDirectory(prefix="agentbar-m1-row4-") as tmpdir:
        thome = pathlib.Path(tmpdir) / "home"
        tws = pathlib.Path(tmpdir) / "ws"
        c_p = thome / ".claude" / "projects" / "-tmp-r4"
        x_p = thome / ".codex"
        r_p = tws / "p4" / ".relay"
        for d in (c_p, x_p, r_p):
            d.mkdir(parents=True, exist_ok=True)

        # 2026-11-13: 1 priced Sonnet ($4.50) + 1 unknown model -> singular/singular costNote
        # 2026-11-14: 1 priced Sonnet ($4.50) + 2 unknown models + prose 429 traps -> 0 rate limits!
        # 2026-11-15: 1 structured Claude 429
        (c_p / "r4.jsonl").write_text(
            "\n".join(
                [
                    '{"type":"assistant","timestamp":"2026-11-13T10:00:00Z","sessionId":"s13","requestId":"r0a","message":{"id":"m0a","model":"claude-sonnet-5-5","usage":{"input_tokens":1000000,"output_tokens":100000}}}',
                    '{"type":"assistant","timestamp":"2026-11-13T10:05:00Z","sessionId":"s13","requestId":"r0b","message":{"id":"m0b","model":"claude-fable-5-1","usage":{"input_tokens":50000,"output_tokens":5000}}}',
                    '{"type":"assistant","timestamp":"2026-11-14T10:00:00Z","sessionId":"s","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-5-5","content":[{"type":"text","text":"frame rate is 429 fps; corporate tax rate limit discussion"}],"usage":{"input_tokens":1000000,"output_tokens":100000}}}',
                    '{"type":"assistant","timestamp":"2026-11-14T10:05:00Z","sessionId":"s","requestId":"r2","message":{"id":"m2","model":"claude-fable-5-1","usage":{"input_tokens":50000,"output_tokens":5000}}}',
                    '{"type":"assistant","timestamp":"2026-11-14T10:10:00Z","sessionId":"s","requestId":"r3","message":{"id":"m3","model":"glm-5-3","usage":{"input_tokens":50000,"output_tokens":5000}}}',
                    '{"type":"assistant","isApiErrorMessage":true,"error":"invalid_request_error","timestamp":"2026-11-14T10:15:00Z","sessionId":"s","requestId":"r-non429","message":{"content":[{"type":"text","text":"rate limit 429 in body"}]}}',
                    '{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","timestamp":"2026-11-15T09:00:00Z","sessionId":"s","requestId":"r-real429"}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        # 2026-11-15: Codex rollout=12,000 vs sqlite=50,000 mismatch + 1 structured Codex 429
        rmis = x_p / "rmis.jsonl"
        rmis.write_text(
            "\n".join(
                [
                    '{"timestamp":"2026-11-15T09:00:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}',
                    '{"timestamp":"2026-11-15T09:01:00Z","type":"event_msg","payload":{"type":"error","error":{"type":"rate_limit_error","status":429}}}',
                    '{"timestamp":"2026-11-15T09:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":8000,"cache_write_input_tokens":0,"output_tokens":2000,"total_tokens":12000}}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        cx = sqlite3.connect(str(x_p / "state_5.sqlite"))
        cx.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT)")
        cx.execute("INSERT INTO threads VALUES ('th-mis-15', '/tmp/p', 50000, ?, 'gpt-6.1-sol', ?)", (t_curr_s, str(rmis)))
        cx.commit()
        cx.close()

        (r_p / "LOG.md").write_text(
            "# Agent Relay Log\n\n## 01-agy: ok, 20s, 2026-11-15 09:30\n- agy: model gemini-4-carbon-high, tokens 25,000\n",
            encoding="utf-8",
        )

        r4_en_raw = run_cli(bin_path, "snapshot", ["--json", "--lang", "en", "--tz", "UTC", "--home", str(thome), "--workspace", str(tws), "--now", now_iso])
        r4_en = json.loads(r4_en_raw)
        r4_zh = run_cli_json(bin_path, "snapshot", ["--lang", "zh", "--tz", "UTC", "--home", str(thome), "--workspace", str(tws), "--now", now_iso])
        en_days = {d["date"]: d for d in r4_en["dailyBreakdown"]}
        zh_days = {d["date"]: d for d in r4_zh["dailyBreakdown"]}
        c_vendor = r4_en["vendors"]["claude"]
        c_w30 = c_vendor["windows"]["thirtyDays"]

        ok = (
            "unknownModelRecordCount" not in r4_en_raw
            and c_vendor["unmatchedModelCount30d"] == 3
            and "unknownModelRecordCount30d" not in c_vendor
            and c_w30["pricedRecordCount"] == 2
            and c_w30["unmatchedModelCount"] == 3
            and "unknownModelRecordCount" not in c_w30
            and c_w30["costNote"] == "Covers 2 priced records only; 3 unknown-model records excluded"
            and en_days["2026-11-13"]["pricedRecordCount"] == 1
            and en_days["2026-11-13"]["unmatchedModelCount"] == 1
            and en_days["2026-11-13"]["costNote"] == "Covers 1 priced record only; 1 unknown-model record excluded"
            and en_days["2026-11-14"]["pricedRecordCount"] == 1
            and en_days["2026-11-14"]["unmatchedModelCount"] == 2
            and en_days["2026-11-14"]["costNote"] == "Covers 1 priced record only; 2 unknown-model records excluded"
            and zh_days["2026-11-14"]["costNote"] == "只含已计价的 1 条，另有 2 条未知型号未计入"
            and en_days["2026-11-14"]["hasCodexRolloutMismatch"] is False
            and en_days["2026-11-14"]["rateLimit429Count"] == 0
            and en_days["2026-11-15"]["hasCodexRolloutMismatch"] is True
            and "th-mis-15: rollout=12000 vs sqlite=50000" in (en_days["2026-11-15"]["codexMismatchNote"] or "")
            and "th-mis-15: rollout=12000 vs sqlite=50000" in (zh_days["2026-11-15"]["codexMismatchNote"] or "")
            and en_days["2026-11-15"]["rateLimit429Count"] == 2
            and r4_en["vendors"]["agy"]["completeness"] == "relayOnly"
            and r4_zh["vendors"]["agy"]["completeness"] != "complete"
        )
        msg = "prose_429=0, structured_429=2, canonical unmatchedModelCount, EN/ZH singular/plural costNote & mismatchNote verified, agy=relayOnly(!=complete)"
        return (ok, msg)


# ===========================================================================
# Check 5 (Row 5 + BR3 + BR1 + B12-B17): 14 Scripted Isolated Mutations
# ===========================================================================


def verify_row5_scripted_mutations() -> tuple[bool, str]:
    """Copy Package.swift + Sources + Tests to an isolated temp dir, run 14 targeted mutations (M1-M8 + B12-B17), verify each fails RED."""
    mutations = [
        (
            "M1-br3-day-upper-le",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "let daySlice = timedSamples.filter { $0.timestamp! >= dayStart && $0.timestamp! < dayEnd && $0.timestamp! <= now }",
            "let daySlice = timedSamples.filter { $0.timestamp! >= dayStart && $0.timestamp! <= dayEnd && $0.timestamp! <= now }",
            "AgentBarCoreTests.CollectorsTests/exactSecondWindowAndDayBoundaries",
            "M1 BR3: Exact boundary second checks for dayStart, nextDayStart, fiveHoursAgo, sevenDaysAgo, thirtyDaysAgo, and now",
        ),
        (
            "M2-br3-fivehours-gt",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "let fiveHourSlice = vSamples.filter { $0.timestamp! >= fiveHoursAgo && $0.timestamp! <= now }",
            "let fiveHourSlice = vSamples.filter { $0.timestamp! > fiveHoursAgo && $0.timestamp! <= now }",
            "AgentBarCoreTests.CollectorsTests/exactSecondWindowAndDayBoundaries",
            "M1 BR3: Exact boundary second checks for dayStart, nextDayStart, fiveHoursAgo, sevenDaysAgo, thirtyDaysAgo, and now",
        ),
        (
            "M3-br3-sevendays-gt",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "let sevenDaySlice = vSamples.filter { $0.timestamp! >= sevenDaysAgo && $0.timestamp! <= now }",
            "let sevenDaySlice = vSamples.filter { $0.timestamp! > sevenDaysAgo && $0.timestamp! <= now }",
            "AgentBarCoreTests.CollectorsTests/exactSecondWindowAndDayBoundaries",
            "M1 BR3: Exact boundary second checks for dayStart, nextDayStart, fiveHoursAgo, sevenDaysAgo, thirtyDaysAgo, and now",
        ),
        (
            "M4-br1-claude-ts-now",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "timestamp: parsedTS,",
            "timestamp: parsedTS ?? now,",
            "AgentBarCoreTests.CollectorsTests/missingAndCorruptTimestampsRouteStrictlyToUntimestamped",
            "M1 BR1: Missing or malformed timestamps across all 5 sources contribute 0 to windows and dated rows and tally strictly in untimestamped",
        ),
        (
            "M5-codex-session-ts",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "timestamp: ev.timestamp,",
            "timestamp: sessionTS,",
            "AgentBarCoreTests.CollectorsTests/codexCrossDayRolloutEventsAndPerDayMismatch",
            "M1 B3+B15: Codex cross-day rollout splits turns by event timestamp",
        ),
        (
            "M6-opencode-ignore-messages",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "if let msgTable {",
            "if false, let msgTable {",
            "AgentBarCoreTests.CollectorsTests/openCodeCrossDaySessionMessages",
            "M1 B3: OpenCode cross-day session_message splits events by per-message timestamp",
        ),
        (
            "M7-vibe-no-action-dedup",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "guard seenActionIDs.insert(actionID).inserted else { return }",
            "_ = seenActionIDs.insert(actionID)",
            "AgentBarCoreTests.CollectorsTests/vibeUnifiedJournalMultiSegmentAndActionDedup",
            "M1 B5: Mistral Vibe unified journal multi-segment reader deduplicates action_id",
        ),
        (
            "M8-prose-429-false-positive",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "if isStructured429, let rlTS = parsedTS",
            'if (isStructured429 || line.localizedCaseInsensitiveContains("rate")), let rlTS = parsedTS',
            "AgentBarCoreTests.CollectorsTests/structured429RateLimitCountingIgnoresProse",
            "M1 B7: Counts 429 rate limits strictly from structured status/error codes",
        ),
        (
            "B12-pricing-unverified",
            "Sources/AgentBarCore/Models/TelemetryModels.swift",
            'public static let pricingVersion = "unverified"',
            'public static let pricingVersion = "2026-11"',
            "AgentBarCoreTests.PricingTests/pricingCatalog2026_11ExactArithmeticAndDisclaimer",
            "Every PriceCatalog model row carries per-1M rates, official sourceURL, and honest unverified status",
        ),
        (
            "B13-zh-datasource-english",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            '        case .antigravity:\n            return language == .zhHans\n                ? "~/Projects/*/.relay/LOG.md（cli-*.log 无 Token 统计）"\n                : "~/Projects/*/.relay/LOG.md (cli-*.log lacks token stats)"',
            '        case .antigravity:\n            return "~/Projects/*/.relay/LOG.md (cli-*.log lacks token stats)"',
            "AgentBarCoreTests.CLITests/headlessSnapshotJSONBilingualAndNullHonesty",
            "Headless --cli snapshot --json outputs exact schema, explicit JSON nulls, and EN/ZH labels",
        ),
        (
            "B14-unmatched-model-count",
            "Sources/AgentBarCore/Models/TelemetryModels.swift",
            "self.unmatchedModelCount = (!hasValidRecordedCost && est == nil) ? 1 : 0",
            "self.unmatchedModelCount = 0",
            "AgentBarCoreTests.CLITests/dailyBreakdownCarriesPerDayB14PricingAndB15Mismatch",
            "M1 Part 2: Exposes 14-day dailyBreakdown in --cli snapshot and --cli daily with per-day B14 pricing counts, B15 Codex mismatch, B7 429s, and --tz UTC",
        ),
        (
            "B15-codex-mismatch-ignored",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "let isMismatch = (rolloutTotal != totalTok)\n                        || (breakdown.reportedTotalTokens != nil && breakdown.reportedTotalTokens != totalTok)",
            "let isMismatch = false && (rolloutTotal != totalTok || breakdown.reportedTotalTokens != nil)",
            "AgentBarCoreTests.CLITests/costCoverageNoteAndCodexMismatchInCLI",
            "Formats explicit priced N vs excluded unknown-model M beside cost and surfaces Codex rollout mismatch in EN/ZH CLI",
        ),
        (
            "B16-nonexistent-home-exit-zero",
            "Sources/AgentBarCore/CLI/CLIRunner.swift",
            "if !fm.fileExists(atPath: explicitHome.path, isDirectory: &isDir) || !isDir.boolValue {",
            "if false && (!fm.fileExists(atPath: explicitHome.path, isDirectory: &isDir) || !isDir.boolValue) {",
            "AgentBarCoreTests.CLITests/nonexistentHomeOrWorkspaceExitsNonZeroWithError",
            "Exits non-zero with stderr message when explicit --home or --workspace path does not exist or is not a directory",
        ),
        (
            "B17-singular-plural-grammar",
            "Sources/AgentBarCore/Models/TelemetryModels.swift",
            'let pricedPhrase = englishCount(pricedCount, singular: "priced record", plural: "priced records")',
            'let pricedPhrase = "\\(pricedCount) priced records"',
            "AgentBarCoreTests.CLITests/b17SingularPluralGrammarAndCanonicalUnmatchedModelCountKey",
            "B17: Singular/plural English grammar across CLI snapshot/daily/relay and single canonical unmatchedModelCount JSON key",
        ),
    ]

    pre_repo_diff = ""
    if (REPO_ROOT / ".git").exists():
        pre_repo_diff = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "diff", "--", "Sources", "Tests"],
            capture_output=True,
            text=True,
            check=False,
        ).stdout

    with tempfile.TemporaryDirectory(prefix="agentbar-m1-mutations-") as tmpdir:
        mut_root = pathlib.Path(tmpdir) / "repo"
        iso_home = pathlib.Path(tmpdir) / "empty_home"
        mut_root.mkdir(parents=True)
        iso_home.mkdir(parents=True)
        shutil.copy2(REPO_ROOT / "Package.swift", mut_root / "Package.swift")
        shutil.copytree(REPO_ROOT / "Sources", mut_root / "Sources")
        shutil.copytree(REPO_ROOT / "Tests", mut_root / "Tests")

        env = dict(os.environ)
        env["HOME"] = str(iso_home)

        subprocess.run(["git", "init", "-q"], cwd=str(mut_root), env=env, check=True)
        subprocess.run(["git", "config", "user.email", "mut@local"], cwd=str(mut_root), env=env, check=True)
        subprocess.run(["git", "config", "user.name", "mut"], cwd=str(mut_root), env=env, check=True)
        subprocess.run(["git", "add", "Package.swift", "Sources", "Tests"], cwd=str(mut_root), env=env, check=True)
        subprocess.run(["git", "commit", "-qm", "baseline"], cwd=str(mut_root), env=env, check=True)

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
                    env=env,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
                compiled = "Build complete!" in combined
                ran = "Test run started" in combined
                named_failed = (f'✘ Test "{test_display}' in combined) or (
                    (test_display in combined) and "recorded an issue" in combined
                )
                if proc.returncode == 0 or not compiled or not ran or not named_failed:
                    return (
                        False,
                        f"{label} did not fail cleanly (rc={proc.returncode}, compiled={compiled}, ran={ran}, named_failed={named_failed})",
                    )
                details.append(f"{label}=RED(rc={proc.returncode})")
            finally:
                fpath.write_text(original, encoding="utf-8")
                git_diff = subprocess.run(
                    ["git", "-C", str(mut_root), "diff", "--quiet", "--", "Package.swift", "Sources", "Tests"],
                    env=env,
                    check=False,
                )
                if fpath.read_text(encoding="utf-8") != original or git_diff.returncode != 0:
                    return (False, f"{label}: failed to restore {rel_file} (git diff rc={git_diff.returncode})")

        clean_proc = subprocess.run(
            [
                "swift",
                "test",
                "--no-parallel",
                "--filter",
                "AgentBarCoreTests.CollectorsTests",
                "--filter",
                "AgentBarCoreTests.PricingTests",
                "--filter",
                "AgentBarCoreTests.RelayLogTests",
                "--filter",
                "AgentBarCoreTests.CLITests",
            ],
            cwd=str(mut_root),
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        if clean_proc.returncode != 0:
            return (False, f"restored workspace failed (rc={clean_proc.returncode})")

    if (REPO_ROOT / ".git").exists():
        post_repo_diff = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "diff", "--", "Sources", "Tests"],
            capture_output=True,
            text=True,
            check=False,
        ).stdout
        if post_repo_diff != pre_repo_diff:
            return (False, "git diff on REPO_ROOT Sources/Tests changed during mutation suite")

    details.append("restored=GREEN(rc=0,git_diff=empty)")
    return (True, ", ".join(details))


# ===========================================================================
# Check 6 (BR1): Missing & Malformed Timestamps -> Strictly `untimestamped`
# ===========================================================================


def verify_row6_br1_untimestamped(bin_path: pathlib.Path) -> tuple[bool, str]:
    now_iso = "2026-11-15T12:00:00Z"

    # Hand-calculated literal expected untimestamped counts per vendor: (totalTokens, recordCount)
    EXPECTED_UNTIMESTAMPED_BY_VENDOR: dict[str, tuple[int, int]] = {
        # Claude: missing ts (800+200=1,000) + malformed ts "not-a-date" (1,000+310=1,310) = 2,310 (2 records)
        "claude": (2_310, 2),
        # Codex: rollout event missing ts (1,100; must NOT borrow threads.updated_at!) + session-only updated_at=0 (400) = 1,500 (2 records)
        "codex": (1_500, 2),
        # OpenCode: session_message missing ts (50+27=77; must NOT borrow session_v2.time_updated!) + session_v2-only time_updated=0 (200+30=230) = 307 (2 records)
        "opencode": (307, 2),
        # Vibe: journal no-ts action (500) + journal corrupt-ts action (250) + .relay/LOG.md no-ts step (600) = 1,350 (3 records)
        "vibe": (1_350, 3),
        # AGY: .relay/LOG.md no-ts step (900) + .relay/LOG.md invalid calendar date 2026-99-99 99:99 (350) = 1,250 (2 records)
        "agy": (1_250, 2),
    }
    # Hand sum across all 5 vendors: 2,310 + 1,500 + 307 + 1,350 + 1,250 = 6,717 tokens across 11 records
    EXPECTED_TOP_UNTIMESTAMPED = (6_717, 11)

    with tempfile.TemporaryDirectory(prefix="agentbar-m1-br1-") as tmpdir:
        thome = pathlib.Path(tmpdir) / "home"
        tws = pathlib.Path(tmpdir) / "ws"
        c_p = thome / ".claude" / "projects" / "-tmp-br1"
        x_p = thome / ".codex"
        o_p = thome / ".local" / "share" / "opencode"
        v_p = thome / ".vibe" / "logs" / "session" / "unified" / "vs-br1" / "journal"
        a_log = thome / ".gemini" / "antigravity-cli" / "log"
        r_p = tws / "pipe-br1" / ".relay"
        for d in (c_p, x_p, o_p, v_p, a_log, r_p):
            d.mkdir(parents=True, exist_ok=True)

        c_file = c_p / "br1.jsonl"
        c_file.write_text(
            "\n".join(
                [
                    '{"type":"assistant","sessionId":"sc1","requestId":"r1","cwd":"/tmp/br1","message":{"id":"m1","model":"claude-sonnet-4-6","usage":{"input_tokens":800,"output_tokens":200}}}',
                    '{"type":"assistant","timestamp":"not-a-date","sessionId":"sc1","requestId":"r2","cwd":"/tmp/br1","message":{"id":"m2","model":"claude-sonnet-4-6","usage":{"input_tokens":1000,"output_tokens":310}}}',
                    '{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","timestamp":"not-a-date","sessionId":"sc1","requestId":"r429"}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        old_ep = iso_to_epoch_s("2026-08-01T00:00:00Z")
        os.utime(c_file, (old_ep, old_ep))

        roll_nots = x_p / "roll-nots.jsonl"
        roll_nots.write_text(
            "\n".join(
                [
                    '{"type":"turn_context","payload":{"model":"gpt-5.4"}}',
                    '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":100,"total_tokens":1100}}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        cx = sqlite3.connect(str(x_p / "state_5.sqlite"))
        cx.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, created_at INTEGER, model TEXT, rollout_path TEXT)")
        cx.execute("INSERT INTO threads VALUES ('th-nots', '/tmp/br1', 1100, ?, ?, 'gpt-5.4', ?)", (iso_to_epoch_s("2026-11-14T12:00:00Z"), iso_to_epoch_s("2026-11-14T12:00:00Z"), str(roll_nots)))
        cx.execute("INSERT INTO threads VALUES ('th-agg0', '/tmp/br1', 400, 0, 0, 'gpt-5.4', '/nonexistent/missing.jsonl')")
        cx.commit()
        cx.close()

        oc = sqlite3.connect(str(o_p / "opencode.db"))
        oc.execute("CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, model TEXT, time_updated INTEGER)")
        oc.execute("CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT)")
        oc.execute("INSERT INTO session_v2 VALUES ('oc-nots', '/tmp/br1', 0.01, 50, 27, 0, 0, 0, 'claude-sonnet-4-6', ?)", (iso_to_epoch_ms("2026-11-13T12:00:00Z"),))
        oc.execute("INSERT INTO session_v2 VALUES ('oc-agg0', '/tmp/br1', 0.02, 200, 30, 0, 0, 0, 'claude-sonnet-4-6', 0)")
        oc.execute(
            "INSERT INTO session_message VALUES ('m-nots', 'oc-nots', 'assistant', 1, 0, 0, ?)",
            ('{"model":{"id":"claude-sonnet-4-6"},"tokens":{"input":50,"output":27,"reasoning":0,"cache":{"read":0,"write":0}}}',),
        )
        oc.commit()
        oc.close()

        (v_p.parent / "meta.json").write_text('{"session_id":"vs-br1","start_time":"2026-11-12T12:00:00Z","config":{"active_model":"deepseek-v4"}}\n', encoding="utf-8")
        (v_p / "0000000000000001.jsonl").write_text(
            "\n".join(
                [
                    '{"sequence":1,"type":"action_result","payload":{"action_id":"a-nots","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":400,"cached_input_tokens":0,"cache_write_tokens":0,"output_tokens":100,"total_tokens":500}}}}}',
                    '{"sequence":2,"type":"core_input","payload":{"input":{"determinism":{"time_unix_ms":"corrupt-ts"}}}}',
                    '{"sequence":3,"type":"action_result","payload":{"action_id":"a-badts","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":200,"cached_input_tokens":0,"cache_write_tokens":0,"output_tokens":50,"total_tokens":250}}}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        (a_log / "cli-br1.log").write_text("WARN request failed status=429 reason=rate_limit\n", encoding="utf-8")
        (r_p / "LOG.md").write_text(
            "\n".join(
                [
                    "# Agent Relay Log",
                    "",
                    "## 01-vibe: ok, 12s",
                    "- vibe: model deepseek-v4, tokens 600, cost $0.02",
                    "",
                    "## 02-agy: ok, 20s",
                    "- agy: model gemini-2.5-pro, tokens 900, cost $0.03",
                    "",
                    "## 03-agy: ok, 15s, 2026-99-99 99:99",
                    "- agy: model gemini-2.5-pro, tokens 350, cost $0.01",
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        common = ["--tz", "UTC", "--home", str(thome), "--workspace", str(tws), "--now", now_iso]
        en_doc = run_cli_json(bin_path, "snapshot", ["--lang", "en", *common])
        zh_doc = run_cli_json(bin_path, "daily", ["--lang", "zh", *common])
        en_txt = run_cli(bin_path, "daily", ["--lang", "en", *common])
        zh_txt = run_cli(bin_path, "daily", ["--lang", "zh", *common])

        errs: list[str] = []
        for v_id, (exp_tok, exp_rec) in EXPECTED_UNTIMESTAMPED_BY_VENDOR.items():
            v_obj = en_doc["vendors"][v_id]
            if v_obj["rateLimitHits24h"] != 0:
                errs.append(f"{v_id}.rateLimitHits24h={v_obj['rateLimitHits24h']}")
            for w_key in ("fiveHours", "today", "sevenDays", "thirtyDays"):
                wt = v_obj["windows"][w_key]["totalTokens"] or 0
                wr = v_obj["windows"][w_key]["recordCount"]
                if wt != 0 or wr != 0:
                    errs.append(f"{v_id}.{w_key} leaked ({wt},{wr})")
            u_obj = v_obj["untimestamped"]
            if u_obj["totalTokens"] != exp_tok or u_obj["recordCount"] != exp_rec:
                errs.append(f"{v_id}.untimestamped=({u_obj['totalTokens']},{u_obj['recordCount']}), exp=({exp_tok},{exp_rec})")

        for d_row in en_doc["dailyBreakdown"]:
            if d_row["totalTokens"] != 0 or d_row["recordCount"] != 0:
                errs.append(f"dated row {d_row['date']} leaked ({d_row['totalTokens']},{d_row['recordCount']})")

        top_en = en_doc["untimestamped"]
        top_zh = zh_doc["untimestamped"]
        if (top_en["date"], top_en["totalTokens"], top_en["recordCount"]) != ("No timestamp", *EXPECTED_TOP_UNTIMESTAMPED):
            errs.append(f"top_en={top_en}")
        if (top_zh["date"], top_zh["totalTokens"], top_zh["recordCount"]) != ("没有时间", *EXPECTED_TOP_UNTIMESTAMPED):
            errs.append(f"top_zh={top_zh}")
        if "No timestamp |" not in en_txt or "没有时间 |" not in zh_txt:
            errs.append("human-readable daily text missing 'No timestamp |' or '没有时间 |'")

        ok = len(errs) == 0
        msg = (
            "0 tokens leaked into 5h/today/7d/30d/14d-dated rows; untimestamped=6,717 tok (11 records) "
            "labeled 'No timestamp' (EN) & '没有时间' (ZH)"
            if ok
            else "; ".join(errs[:5])
        )
        return (ok, msg)


# ===========================================================================
# Check 7 (BR2): --tz Pacific/Auckland NZDT Start (23h), NZDT End (25h), Cross-Midnight
# ===========================================================================


def verify_row7_br2_pacific_auckland(bin_path: pathlib.Path) -> tuple[bool, str]:
    errs: list[str] = []

    # --- 7a. NZDT Start Day: 2026-09-27 (spring-forward 23-hour day: 01:59:59 +12:00 -> 03:00:00 +13:00) ---
    # Hand-calculated literal expected day totals under --tz Pacific/Auckland --now 2026-09-28T05:00:00Z:
    #   2026-09-26: claude 100 (23:59:59 +12:00) = 100
    #   2026-09-27: claude (200 + 400 + 800 + 1600 + 3200 + 6400 = 12,600)
    #             + codex  (1000 pre-jump 01:30 + 2000 post-jump 03:30 = 3,000)
    #             + agy    (300 at 01:30 + 500 at 03:30 = 800)
    #             = 16,400
    #   2026-09-28: claude 12,800 (00:00:00 +13:00) + codex 4,000 (00:00:00 +13:00) = 16,800
    #   untimestamped: agy 999 (non-existent local wall time 2026-09-27 02:30 during spring-forward jump!)
    EXPECTED_NZDT_START_DAYS = {
        "2026-09-26": 100,
        "2026-09-27": 16_400,
        "2026-09-28": 16_800,
    }
    EXPECTED_NZDT_START_UNTIMESTAMPED = 999

    with tempfile.TemporaryDirectory(prefix="agentbar-m1-nz-start-") as tmpdir:
        thome = pathlib.Path(tmpdir) / "home"
        tws = pathlib.Path(tmpdir) / "ws"
        c_p = thome / ".claude" / "projects" / "-tmp-nzs"
        x_p = thome / ".codex"
        r_p = tws / "nzs" / ".relay"
        for d in (c_p, x_p, r_p):
            d.mkdir(parents=True, exist_ok=True)

        spring_claude = [
            ("2026-09-26T11:59:59Z", 100),   # 2026-09-26 23:59:59 +12:00 -> 2026-09-26
            ("2026-09-26T12:00:00Z", 200),   # 2026-09-27 00:00:00 +12:00 -> 2026-09-27
            ("2026-09-26T13:30:00Z", 400),   # 2026-09-27 01:30:00 +12:00 -> 2026-09-27 (pre-jump)
            ("2026-09-26T13:59:59Z", 800),   # 2026-09-27 01:59:59 +12:00 -> 2026-09-27 (1s before jump)
            ("2026-09-26T14:00:00Z", 1_600), # 2026-09-27 03:00:00 +13:00 -> 2026-09-27 (jump landing)
            ("2026-09-26T14:30:00Z", 3_200), # 2026-09-27 03:30:00 +13:00 -> 2026-09-27 (post-jump)
            ("2026-09-27T10:59:59Z", 6_400), # 2026-09-27 23:59:59 +13:00 -> 2026-09-27 (end of 23h day)
            ("2026-09-27T11:00:00Z", 12_800),# 2026-09-28 00:00:00 +13:00 -> 2026-09-28
        ]
        (c_p / "nzs.jsonl").write_text(
            "\n".join(
                json.dumps({"type": "assistant", "timestamp": ts_s, "sessionId": "snz", "requestId": f"r{i}", "message": {"id": f"m{i}", "model": "claude-sonnet-5-5", "usage": {"input_tokens": tok, "output_tokens": 0}}})
                for i, (ts_s, tok) in enumerate(spring_claude)
            )
            + "\n",
            encoding="utf-8",
        )
        roll_nzs = x_p / "roll-nzs.jsonl"
        roll_nzs.write_text(
            "\n".join(
                [
                    '{"timestamp":"2026-09-26T13:30:00Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}',
                    '{"timestamp":"2026-09-26T13:30:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"total_tokens":1000}}}}',
                    '{"timestamp":"2026-09-26T14:30:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"total_tokens":3000}}}}',
                    '{"timestamp":"2026-09-27T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":7000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"total_tokens":7000}}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        cx = sqlite3.connect(str(x_p / "state_5.sqlite"))
        cx.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT)")
        cx.execute("INSERT INTO threads VALUES ('th-nzs', '/tmp/nz', 7000, ?, 'gpt-6.1-sol', ?)", (iso_to_epoch_s("2026-09-27T12:00:00Z"), str(roll_nzs)))
        cx.commit()
        cx.close()

        (r_p / "LOG.md").write_text(
            "\n".join(
                [
                    "# Agent Relay Log",
                    "",
                    "## 01-agy: ok, 10s, 2026-09-27 01:30",
                    "- agy: model gemini-4-carbon-high, tokens 300",
                    "",
                    "## 02-agy: ok, 10s, 2026-09-27 02:30",
                    "- agy: model gemini-4-carbon-high, tokens 999",
                    "",
                    "## 03-agy: ok, 10s, 2026-09-27 03:30",
                    "- agy: model gemini-4-carbon-high, tokens 500",
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        nzs_doc = run_cli_json(
            bin_path,
            "snapshot",
            ["--lang", "en", "--tz", "Pacific/Auckland", "--home", str(thome), "--workspace", str(tws), "--now", "2026-09-28T05:00:00Z"],
        )
        nzs_days = {d["date"]: d["totalTokens"] for d in nzs_doc["dailyBreakdown"]}
        for dk, exp_tok in EXPECTED_NZDT_START_DAYS.items():
            if nzs_days.get(dk) != exp_tok:
                errs.append(f"NZDT-start[{dk}]: got={nzs_days.get(dk)}, exp={exp_tok}")
        if nzs_doc["untimestamped"]["totalTokens"] != EXPECTED_NZDT_START_UNTIMESTAMPED:
            errs.append(f"NZDT-start untimestamped: got={nzs_doc['untimestamped']['totalTokens']}, exp={EXPECTED_NZDT_START_UNTIMESTAMPED}")

    # --- 7b. NZDT End Day: 2027-04-04 (fall-back 25-hour day: 02:00-02:59 repeats in +13:00 then +12:00) ---
    # Hand-calculated literal expected values:
    #   At --now 2027-04-03T18:00:00Z (2027-04-04 06:00:00 +12:00; fiveHoursAgo = 2027-04-03T13:00:00Z = 02:00:00 +13:00):
    #     claude.fiveHours = 800 (13:00Z) + 1600 (1st 02:30 at 13:30Z) + 3200 (2nd 02:30 at 14:30Z) = 5,600 (excludes 400 at 12:59:59Z)
    #     claude.today     = 200 (11:00Z) + 400 (12:59:59Z) + 5,600 = 6,200
    #     opencode.fiveHours = 500 (1st 02:30) + 700 (2nd 02:30) = 1,200
    #   At --now 2027-04-04T13:00:00Z (2027-04-05 01:00:00 +12:00):
    #     2027-04-03 = 100
    #     2027-04-04 = claude (200+400+800+1600+3200+6400 = 12,600) + opencode (500+700 = 1,200) = 13,800
    #     2027-04-05 = 12,800
    EXPECTED_NZDT_END_5H = {"claude_5h": 5_600, "claude_today": 6_200, "opencode_5h": 1_200}
    EXPECTED_NZDT_END_DAYS = {"2027-04-03": 100, "2027-04-04": 13_800, "2027-04-05": 12_800}

    with tempfile.TemporaryDirectory(prefix="agentbar-m1-nz-end-") as tmpdir:
        thome = pathlib.Path(tmpdir) / "home"
        tws = pathlib.Path(tmpdir) / "ws"
        c_p = thome / ".claude" / "projects" / "-tmp-nze"
        o_p = thome / ".local" / "share" / "opencode"
        for d in (c_p, o_p, tws):
            d.mkdir(parents=True, exist_ok=True)

        fall_claude = [
            ("2027-04-03T10:59:59Z", 100),   # 2027-04-03 23:59:59 +13:00 -> 2027-04-03
            ("2027-04-03T11:00:00Z", 200),   # 2027-04-04 00:00:00 +13:00 -> 2027-04-04
            ("2027-04-03T12:59:59Z", 400),   # 2027-04-04 01:59:59 +13:00 -> 2027-04-04 (18:00Z - 18001s, outside 5h)
            ("2027-04-03T13:00:00Z", 800),   # 2027-04-04 02:00:00 +13:00 -> 2027-04-04 (18:00Z - 18000s, inside 5h)
            ("2027-04-03T13:30:00Z", 1_600), # 2027-04-04 02:30:00 +13:00 -> 2027-04-04 (1st 02:30, inside 5h)
            ("2027-04-03T14:30:00Z", 3_200), # 2027-04-04 02:30:00 +12:00 -> 2027-04-04 (2nd 02:30, inside 5h)
            ("2027-04-04T11:59:59Z", 6_400), # 2027-04-04 23:59:59 +12:00 -> 2027-04-04 (end of 25h day)
            ("2027-04-04T12:00:00Z", 12_800),# 2027-04-05 00:00:00 +12:00 -> 2027-04-05
        ]
        (c_p / "nze.jsonl").write_text(
            "\n".join(
                json.dumps({"type": "assistant", "timestamp": ts_s, "sessionId": "snze", "requestId": f"r{i}", "message": {"id": f"m{i}", "model": "claude-sonnet-5-5", "usage": {"input_tokens": tok, "output_tokens": 0}}})
                for i, (ts_s, tok) in enumerate(fall_claude)
            )
            + "\n",
            encoding="utf-8",
        )
        oc = sqlite3.connect(str(o_p / "opencode.db"))
        oc.execute("CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, model TEXT, time_updated INTEGER)")
        oc.execute("CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT)")
        oc.execute("INSERT INTO session_v2 VALUES ('oc-nze', '/tmp/nz', 0.02, 1200, 0, 0, 0, 0, 'deepseek-v4.1-flash', ?)", (iso_to_epoch_ms("2027-04-03T15:00:00Z"),))
        for i, (ts_s, tok) in enumerate([("2027-04-03T13:30:00Z", 500), ("2027-04-03T14:30:00Z", 700)], start=1):
            ms = iso_to_epoch_ms(ts_s)
            oc.execute(
                "INSERT INTO session_message VALUES (?, 'oc-nze', 'assistant', ?, ?, ?, ?)",
                (f"m{i}", i, ms, ms, json.dumps({"model": {"id": "deepseek-v4.1-flash"}, "time": {"created": ms}, "tokens": {"input": tok, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}})),
            )
        oc.commit()
        oc.close()

        nze_5h = run_cli_json(
            bin_path,
            "snapshot",
            ["--lang", "en", "--tz", "Pacific/Auckland", "--home", str(thome), "--workspace", str(tws), "--now", "2027-04-03T18:00:00Z"],
        )
        if nze_5h["vendors"]["claude"]["windows"]["fiveHours"]["totalTokens"] != EXPECTED_NZDT_END_5H["claude_5h"]:
            errs.append(f"NZDT-end claude 5h={nze_5h['vendors']['claude']['windows']['fiveHours']['totalTokens']}")
        if nze_5h["vendors"]["claude"]["windows"]["today"]["totalTokens"] != EXPECTED_NZDT_END_5H["claude_today"]:
            errs.append(f"NZDT-end claude today={nze_5h['vendors']['claude']['windows']['today']['totalTokens']}")
        if nze_5h["vendors"]["opencode"]["windows"]["fiveHours"]["totalTokens"] != EXPECTED_NZDT_END_5H["opencode_5h"]:
            errs.append(f"NZDT-end opencode 5h={nze_5h['vendors']['opencode']['windows']['fiveHours']['totalTokens']}")

        nze_full = run_cli_json(
            bin_path,
            "snapshot",
            ["--lang", "en", "--tz", "Pacific/Auckland", "--home", str(thome), "--workspace", str(tws), "--now", "2027-04-04T13:00:00Z"],
        )
        nze_days = {d["date"]: d["totalTokens"] for d in nze_full["dailyBreakdown"]}
        for dk, exp_tok in EXPECTED_NZDT_END_DAYS.items():
            if nze_days.get(dk) != exp_tok:
                errs.append(f"NZDT-end[{dk}]: got={nze_days.get(dk)}, exp={exp_tok}")

    # --- 7c. Cross-Midnight Cases in Pacific/Auckland (+13:00) ---
    # Same UTC date (2026-11-14T10:59:59Z vs 2026-11-14T11:00:00Z) splits across 2026-11-14 and 2026-11-15 in NZ,
    # AND different UTC dates (2026-11-14T11:30:00Z and 2026-11-15T10:30:00Z) both land on 2026-11-15 in NZ:
    #   2026-11-14: claude 300 (10:59:59Z) + agy 410 (23:59:59 local) = 710
    #   2026-11-15: claude (700 + 1500 + 3100 = 5,300) + agy 820 (00:00:00 local) = 6,120
    EXPECTED_NZ_CROSS_MIDNIGHT = {"2026-11-14": 710, "2026-11-15": 6_120}

    with tempfile.TemporaryDirectory(prefix="agentbar-m1-nz-mid-") as tmpdir:
        thome = pathlib.Path(tmpdir) / "home"
        tws = pathlib.Path(tmpdir) / "ws"
        c_p = thome / ".claude" / "projects" / "-tmp-nzm"
        r_p = tws / "nzm" / ".relay"
        for d in (c_p, r_p):
            d.mkdir(parents=True, exist_ok=True)

        mid_claude = [
            ("2026-11-14T10:59:59Z", 300),
            ("2026-11-14T11:00:00Z", 700),
            ("2026-11-14T11:30:00Z", 1_500),
            ("2026-11-15T10:30:00Z", 3_100),
        ]
        (c_p / "nzm.jsonl").write_text(
            "\n".join(
                json.dumps({"type": "assistant", "timestamp": ts_s, "sessionId": "snzm", "requestId": f"r{i}", "message": {"id": f"m{i}", "model": "claude-sonnet-5-5", "usage": {"input_tokens": tok, "output_tokens": 0}}})
                for i, (ts_s, tok) in enumerate(mid_claude)
            )
            + "\n",
            encoding="utf-8",
        )
        (r_p / "LOG.md").write_text(
            "\n".join(
                [
                    "# Agent Relay Log",
                    "",
                    "## 01-agy: ok, 10s, 2026-11-14 23:59:59",
                    "- agy: model gemini-4-carbon-high, tokens 410",
                    "",
                    "## 02-agy: ok, 10s, 2026-11-15 00:00:00",
                    "- agy: model gemini-4-carbon-high, tokens 820",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        nzm_doc = run_cli_json(
            bin_path,
            "snapshot",
            ["--lang", "en", "--tz", "Pacific/Auckland", "--home", str(thome), "--workspace", str(tws), "--now", "2026-11-15T11:00:00Z"],
        )
        nzm_days = {d["date"]: d["totalTokens"] for d in nzm_doc["dailyBreakdown"]}
        for dk, exp_tok in EXPECTED_NZ_CROSS_MIDNIGHT.items():
            if nzm_days.get(dk) != exp_tok:
                errs.append(f"NZ-midnight[{dk}]: got={nzm_days.get(dk)}, exp={exp_tok}")

    ok = len(errs) == 0
    msg = (
        "Pacific/Auckland verified: NZDT start 2026-09-27 (23h)=16,400 (02:30 gap->untimestamped=999), "
        "NZDT end 2027-04-04 (25h)=13,800 (both 02:30s summed, 5h=5,600/1,200), cross-midnight=[710, 6,120]"
        if ok
        else "; ".join(errs)
    )
    return (ok, msg)


# ===========================================================================
# Check 8 (Opt-In): Read-Only Live-Host Structural Smoke Check (AGENTBAR_LIVE_HOST=1)
# ===========================================================================


def verify_row8_optional_live_host(bin_path: pathlib.Path) -> tuple[bool | None, str]:
    if os.environ.get("AGENTBAR_LIVE_HOST") != "1":
        return (
            None,
            "AGENTBAR_LIVE_HOST != 1; live-host read-only smoke check skipped (counted as skipped, never as passed)",
        )
    doc = run_cli_json(bin_path, "snapshot", ["--lang", "en", "--tz", "Pacific/Auckland"])
    ok = (
        doc.get("schemaVersion") == "1.1"
        and len(doc.get("dailyBreakdown", [])) == 14
        and "untimestamped" in doc
        and doc["vendors"]["agy"]["completeness"] != "complete"
    )
    tot_14d = sum(int(d["totalTokens"]) for d in doc["dailyBreakdown"])
    u_tok = int(doc["untimestamped"]["totalTokens"])
    return (
        ok,
        f"live-host Pacific/Auckland schemaVersion=1.1, 14d_tokens={tot_14d:,}, untimestamped={u_tok:,}, agy={doc['vendors']['agy']['completeness']}",
    )


def main() -> int:
    mtime_start = plist_mtime()
    bin_path = resolve_agentbar_bin()
    rel_bin = bin_path.relative_to(REPO_ROOT) if bin_path.is_relative_to(REPO_ROOT) else pathlib.Path(bin_path.name)

    print("=" * 78)
    print(f"AgentBar M1 Independent Acceptance Ledger (measurement date: {dt.date.today().isoformat()})")
    print(f"Binary: {rel_bin}")
    print("Oracle mode: Hand-calculated literal expected tables beside fixtures (zero collector re-implementation)")
    print("=" * 78)

    passed = 0
    skipped = 0
    failures: list[str] = []

    def record(row_label: str, status: bool | None, detail: str) -> None:
        nonlocal passed, skipped
        if status is None:
            skipped += 1
            print(f"[{row_label}] SKIP | {detail}")
        elif status:
            passed += 1
            print(f"[{row_label}] PASS | {detail}")
        else:
            failures.append(f"{row_label} ({detail})")
            print(f"[{row_label}] FAIL | {detail}")

    r1a_ok, r1a_msg, r1b_ok, r1b_msg = verify_row1_cross_day(bin_path)
    record("Row 1a", r1a_ok, f"Cross-day 3d sessions (.jsonl/SQLite/journal): {r1a_msg}")
    record("Row 1b", r1b_ok, f"Cross-day archived Codex .jsonl.zst: {r1b_msg}")

    r2_ok, r2_msg = verify_row2_14d_70cells(bin_path)
    record("Row 2 ", r2_ok, f"14d x 5-vendor 70-cell literal ledger: {r2_msg}")

    r3_ok, r3_msg = verify_row3_and_br3_exact_boundaries(bin_path)
    record("Row 3 ", r3_ok, f"fiveHours [now-5h, now] & BR3 exact-second boundaries: {r3_msg}")

    r4_ok, r4_msg = verify_row4_b14_b15_b7(bin_path)
    record("Row 4 ", r4_ok, f"Per-day B14/B15 + structured B7 429: {r4_msg}")

    r5_ok, r5_msg = verify_row5_scripted_mutations()
    record("Row 5 ", r5_ok, f"Scripted isolated M1 + BR1/BR3 + B12-B17 mutations (14): {r5_msg}")

    r6_ok, r6_msg = verify_row6_br1_untimestamped(bin_path)
    record("Row 6 ", r6_ok, f"BR1 missing/corrupt timestamps -> untimestamped: {r6_msg}")

    r7_ok, r7_msg = verify_row7_br2_pacific_auckland(bin_path)
    record("Row 7 ", r7_ok, f"BR2 --tz Pacific/Auckland DST & cross-midnight: {r7_msg}")

    r8_ok, r8_msg = verify_row8_optional_live_host(bin_path)
    record("Row 8 ", r8_ok, f"Optional live-host smoke check: {r8_msg}")

    mtime_end = plist_mtime()
    if mtime_start != mtime_end:
        failures.append(f"Preference plist mtime changed ({mtime_start} -> {mtime_end})")

    print("=" * 78)
    print(f"SUMMARY: passed={passed}, skipped={skipped}, failed={len(failures)} (skipped checks are never counted as passed)")
    if failures:
        print(f"RESULT: FAILED ({len(failures)} check(s): {', '.join(failures)})")
        return 1
    print(f"RESULT: PASSED ({passed} passed, {skipped} skipped, 0 failed; plist untouched).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
