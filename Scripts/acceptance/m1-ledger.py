#!/usr/bin/env python3
"""
AgentBar M1 Independent Acceptance Verifier (Strictly Read-Only, Aggregate Counts Only).

Verifies all M1 requirements from flagship-acceptance/tools/agentbar.md and 07-tools-m0-review.md Part 2:
  Row 1: Cross-day long sessions (Codex rollout deltas, OpenCode session_message, Vibe multi-segment journal)
         bucketed by per-event timestamp with 0-diff per day (synthetic 3-day + live host cross-day check).
  Row 2: 14-day x 5-vendor daily ledger reconciliation (< 1% diff on every day & vendor; synthetic 70-cell
         fixture + read-only live host stores, reporting exact maximum observed discrepancy).
  Row 3: Rolling 5-hour window (`fiveHours`: [now - 5h, now]) exact event-timestamp filtering (synthetic
         cross-boundary session updated 10m ago with 8h-old & 1h-old turns + live host 5h check).
  Row 4: Part 2 additions: per-day B14 (`pricedRecordCount`, `unmatchedModelCount`, bilingual `costNote`),
         per-day B15 (`hasCodexRolloutMismatch`, `codexMismatchNote`), and B7 structured `429` counting
         (prose `"frame rate is 429 fps"` / `"corporate tax rate limit"` -> 0; structured codes -> exact count).
  Row 5: W1 scripted isolated M1 mutations (5 targeted M1 regressions compile, run, and fail their named test,
         then restore cleanly to GREEN).

Privacy & Safety Invariants:
  - Opens local SQLite files strictly with ?mode=ro (immutable read-only URI).
  - Extracts only numeric token counters, model IDs, timestamps, error codes, and costs; never stores or prints conversation text.
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
VENDORS = ("claude", "codex", "opencode", "vibe", "agy")

RATE_LIMIT_CODES = {
    "429",
    "rate_limit",
    "rate_limit_error",
    "rate_limit_exceeded",
    "too_many_requests",
    "resource_exhausted",
}

# Independent price prefix table mirroring PriceCatalog.entries for independent B14 verification
PRICE_PREFIXES: list[tuple[str, str, tuple[float, float, float, float]]] = [
    ("claude-opus", "prefix", (15.0, 1.50, 18.75, 75.0)),
    ("claude-3-opus", "prefix", (15.0, 1.50, 18.75, 75.0)),
    ("claude-4-opus", "prefix", (15.0, 1.50, 18.75, 75.0)),
    ("claude-sonnet", "prefix", (3.0, 0.30, 3.75, 15.0)),
    ("claude-3-5-sonnet", "prefix", (3.0, 0.30, 3.75, 15.0)),
    ("claude-3-7-sonnet", "prefix", (3.0, 0.30, 3.75, 15.0)),
    ("claude-4-sonnet", "prefix", (3.0, 0.30, 3.75, 15.0)),
    ("claude-haiku", "prefix", (0.80, 0.08, 1.00, 4.00)),
    ("claude-3-haiku", "prefix", (0.80, 0.08, 1.00, 4.00)),
    ("claude-3-5-haiku", "prefix", (0.80, 0.08, 1.00, 4.00)),
    ("claude-4-haiku", "prefix", (0.80, 0.08, 1.00, 4.00)),
    ("gpt-6", "prefix", (2.0, 0.50, 2.0, 8.0)),
    ("gpt-5", "prefix", (2.0, 0.50, 2.0, 8.0)),
    ("codex-mini", "prefix", (2.0, 0.50, 2.0, 8.0)),
    ("o3", "exact_or_hyphen", (2.0, 0.50, 2.0, 8.0)),
    ("o4-mini", "prefix", (2.0, 0.50, 2.0, 8.0)),
    ("deepseek-v4", "prefix", (0.30, 0.007, 0.30, 1.20)),
    ("deepseek-v3", "prefix", (0.30, 0.007, 0.30, 1.20)),
    ("deepseek-chat", "prefix", (0.30, 0.007, 0.30, 1.20)),
    ("deepseek-reasoner", "prefix", (0.30, 0.007, 0.30, 1.20)),
    ("gemini-4-carbon", "prefix", (1.25, 0.30, 1.25, 5.0)),
    ("gemini 4 carbon", "prefix", (1.25, 0.30, 1.25, 5.0)),
    ("gemini-2.5-pro", "prefix", (1.25, 0.30, 1.25, 5.0)),
    ("gemini-3-pro", "prefix", (1.25, 0.30, 1.25, 5.0)),
    ("gemini-4-argon", "prefix", (0.30, 0.075, 0.30, 1.20)),
    ("gemini 4 argon", "prefix", (0.30, 0.075, 0.30, 1.20)),
    ("gemini-2.0-flash", "prefix", (0.30, 0.075, 0.30, 1.20)),
    ("gemini-2.5-flash", "prefix", (0.30, 0.075, 0.30, 1.20)),
    ("gemini-3-flash", "prefix", (0.30, 0.075, 0.30, 1.20)),
]


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


def run_cli_json(bin_path: pathlib.Path, subcmd: str, extra_args: list[str]) -> dict[str, Any]:
    cmd = [str(bin_path), "--cli", subcmd, "--json", *extra_args]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"CLI failed ({proc.returncode}): {' '.join(cmd)}\nstderr: {proc.stderr}")
    return json.loads(proc.stdout)


def parse_iso_epoch(ts_str: str | None) -> float | None:
    if not ts_str:
        return None
    s = ts_str.strip()
    if not s:
        return None
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def norm_epoch(val: int | float) -> float:
    return float(val) / 1000.0 if val > 10_000_000_000 else float(val)


def utc_date_str(epoch: float) -> str:
    return dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc).strftime("%Y-%m-%d")


def normalize_model_id(raw: str) -> str:
    s = (raw or "").strip()
    low = s.lower()
    idx = low.find(" (asked for ")
    if idx >= 0:
        s = s[:idx]
    if "," in s:
        s = s.split(",", 1)[0]
    if "/" in s and not s.endswith("/"):
        s = s.rsplit("/", 1)[-1]
    return s.strip().lower()


def is_model_recognized(model: str) -> bool:
    m = normalize_model_id(model)
    if not m:
        return False
    for pfx, kind, _rates in PRICE_PREFIXES:
        if kind == "prefix" and m.startswith(pfx):
            return True
        if kind == "exact_or_hyphen" and (m == pfx or m.startswith(pfx + "-")):
            return True
    return False


def int_or_zero(val: Any) -> int:
    if isinstance(val, bool):
        return 0
    if isinstance(val, (int, float)):
        return int(val)
    if isinstance(val, str):
        try:
            return int(val.strip())
        except ValueError:
            return 0
    return 0


def has_structured_429_status(d: dict[str, Any]) -> bool:
    for k in ("status", "status_code", "statusCode", "http_status", "httpStatus"):
        if k in d and int_or_zero(d[k]) == 429:
            return True
    return False


def is_structured_rate_limit(val: Any) -> bool:
    if val is None or isinstance(val, bool):
        return False
    if isinstance(val, str):
        return val.strip().lower() in RATE_LIMIT_CODES
    if isinstance(val, (int, float)):
        return int(val) == 429
    if isinstance(val, dict):
        if has_structured_429_status(val):
            return True
        for k in ("code", "type", "error_code", "errorCode", "reason"):
            v = val.get(k)
            if isinstance(v, str) and v.strip().lower() in RATE_LIMIT_CODES:
                return True
            if isinstance(v, (int, float)) and not isinstance(v, bool) and int(v) == 429:
                return True
        if isinstance(val.get("data"), dict) and is_structured_rate_limit(val["data"]):
            return True
        if "error" in val and is_structured_rate_limit(val["error"]):
            return True
    return False


# ---------------------------------------------------------------------------
# Independent Reference Collectors (Pure Python reading raw SQLite/JSONL/TOML)
# ---------------------------------------------------------------------------


def ref_collect_claude(claude_dir: pathlib.Path, cutoff: float, now_epoch: float) -> tuple[list[dict[str, Any]], list[float]]:
    if not claude_dir.is_dir():
        return ([], [])
    dedup: dict[str, dict[str, Any]] = {}
    rl_dedup: dict[str, float] = {}

    for path_str in sorted(glob.glob(str(claude_dir / "**" / "*.jsonl"), recursive=True)):
        p = pathlib.Path(path_str)
        try:
            if p.stat().st_mtime < (cutoff - 3600):
                continue
        except OSError:
            continue
        try:
            with p.open("r", encoding="utf-8", errors="ignore") as fh:
                for idx, line in enumerate(fh, start=1):
                    if not ('"assistant"' in line or '"error"' in line or "429" in line or "rate_limit" in line):
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(obj, dict):
                        continue
                    t = parse_iso_epoch(obj.get("timestamp") if isinstance(obj.get("timestamp"), str) else None)
                    ev_t = t if t is not None else now_epoch
                    msg = obj.get("message") if isinstance(obj.get("message"), dict) else {}
                    mid = str(msg.get("id") or "").strip()
                    rid = str(obj.get("requestId") or "").strip()

                    is_429 = False
                    if obj.get("isApiErrorMessage") is True:
                        is_429 = is_structured_rate_limit(obj.get("error")) or has_structured_429_status(obj)
                    elif obj.get("type") == "error":
                        is_429 = is_structured_rate_limit(obj.get("error")) or has_structured_429_status(obj)
                    elif isinstance(obj.get("error"), dict):
                        is_429 = is_structured_rate_limit(obj.get("error"))

                    if is_429 and cutoff <= ev_t <= now_epoch:
                        if mid and rid:
                            rk = f"mr:{mid}::{rid}"
                        elif rid:
                            rk = f"r:{rid}"
                        elif mid:
                            rk = f"m:{mid}"
                        elif obj.get("uuid"):
                            rk = f"u:{obj['uuid']}"
                        else:
                            rk = f"line:{path_str}::{idx}"
                        rl_dedup.setdefault(rk, ev_t)

                    if obj.get("type") != "assistant":
                        continue
                    usage = msg.get("usage")
                    if not isinstance(usage, dict):
                        continue
                    inp = max(0, int_or_zero(usage.get("input_tokens")))
                    out = max(0, int_or_zero(usage.get("output_tokens")))
                    cr = max(0, int_or_zero(usage.get("cache_read_input_tokens")))
                    cw = max(0, int_or_zero(usage.get("cache_creation_input_tokens")))
                    cost = float(obj.get("costUSD") or 0.0) if isinstance(obj.get("costUSD"), (int, float)) else 0.0
                    if inp == 0 and out == 0 and cr == 0 and cw == 0 and cost <= 0.0:
                        continue

                    if mid and rid:
                        dk = f"mr:{mid}::{rid}"
                    elif mid:
                        dk = f"m:{mid}"
                    elif rid:
                        dk = f"r:{rid}"
                    else:
                        dk = f"line:{path_str}::{idx}"

                    model = str(msg.get("model") or "")
                    if dk not in dedup:
                        dedup[dk] = {"ts": ev_t, "in": inp, "out": out, "cr": cr, "cw": cw, "cost": cost, "model": model}
                    else:
                        cur = dedup[dk]
                        cur["in"] = max(cur["in"], inp)
                        cur["out"] = max(cur["out"], out)
                        cur["cr"] = max(cur["cr"], cr)
                        cur["cw"] = max(cur["cw"], cw)
                        cur["cost"] = max(cur["cost"], cost)
                        if not cur["model"] and model:
                            cur["model"] = model
        except OSError:
            continue

    events: list[dict[str, Any]] = []
    for item in dedup.values():
        if cutoff <= item["ts"] <= now_epoch:
            has_cost = item["cost"] > 0.0 or is_model_recognized(item["model"])
            events.append(
                {
                    "vendor": "claude",
                    "ts": item["ts"],
                    "in": item["in"],
                    "cr": item["cr"],
                    "cw": item["cw"],
                    "out": item["out"],
                    "total": item["in"] + item["cr"] + item["cw"] + item["out"],
                    "priced": 1 if has_cost else 0,
                    "unmatched": 0 if has_cost else 1,
                    "mismatch": False,
                }
            )
    return (events, list(rl_dedup.values()))


def ref_read_codex_rollout(rollout_path: str, allow_zstd: bool = True) -> tuple[list[dict[str, Any]], list[float], int | None] | None:
    p = pathlib.Path(rollout_path)
    text: str | None = None
    if p.is_file():
        text = p.read_text(encoding="utf-8", errors="ignore")
    elif allow_zstd:
        zst = pathlib.Path(rollout_path + ".zst")
        zstd_bin = shutil.which("zstd") or ("/opt/homebrew/bin/zstd" if pathlib.Path("/opt/homebrew/bin/zstd").is_file() else None)
        if zst.is_file() and zstd_bin:
            proc = subprocess.run([zstd_bin, "-dc", str(zst)], capture_output=True, text=True, check=False)
            if proc.returncode == 0 and proc.stdout:
                text = proc.stdout
    if text is None:
        return None

    turns: list[dict[str, Any]] = []
    rls: list[float] = []
    cur_model: str | None = None
    prev_u = prev_c = prev_cw = prev_o = 0
    base_rep = 0
    last_rep: int | None = None

    for ln in text.splitlines():
        if not ('"token_count"' in ln or '"turn_context"' in ln or '"error"' in ln or "429" in ln or "rate_limit" in ln):
            continue
        try:
            obj = json.loads(ln)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        ts = parse_iso_epoch(obj.get("timestamp") if isinstance(obj.get("timestamp"), str) else None)
        top_type = obj.get("type")
        payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else None

        is_429 = has_structured_429_status(obj) or is_structured_rate_limit(obj.get("error"))
        if not is_429 and payload is not None:
            if has_structured_429_status(payload) or is_structured_rate_limit(payload.get("error")):
                is_429 = True
            elif payload.get("type") == "error" and is_structured_rate_limit(payload):
                is_429 = True
        if is_429 and ts is not None:
            rls.append(ts)

        if payload is None:
            continue
        if top_type == "turn_context":
            m = str(payload.get("model") or "").strip()
            if m:
                cur_model = m
        elif top_type == "event_msg" and payload.get("type") == "token_count":
            info = payload.get("info") if isinstance(payload.get("info"), dict) else {}
            tu = info.get("total_token_usage")
            if not (isinstance(tu, dict) and "input_tokens" in tu and "output_tokens" in tu):
                continue
            raw_in = max(0, int_or_zero(tu.get("input_tokens")))
            cached = max(0, int_or_zero(tu.get("cached_input_tokens")))
            cw = max(0, int_or_zero(tu.get("cache_write_input_tokens")))
            out = max(0, int_or_zero(tu.get("output_tokens")))
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
            if tu.get("total_tokens") is not None:
                last_rep = max(0, int_or_zero(tu.get("total_tokens")))

            if (du + dc + dcw + do) <= 0:
                continue
            turns.append({"ts": ts, "in": du, "cr": dc, "cw": dcw, "out": do, "model": cur_model})

    rep_total = (base_rep + last_rep) if last_rep is not None else None
    return (turns, rls, rep_total)


def ref_collect_codex(
    db_path: pathlib.Path, cutoff: float, now_epoch: float, allow_zstd: bool = True
) -> tuple[list[dict[str, Any]], list[float], int]:
    if not db_path.is_file():
        return ([], [], 0)
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        cols = {r[1] for r in conn.execute("PRAGMA table_info(threads)").fetchall()}
        m_expr = "model" if "model" in cols else "NULL"
        r_expr = "rollout_path" if "rollout_path" in cols else "NULL"
        c_expr = "created_at" if "created_at" in cols else "0"
        rows = conn.execute(
            f"SELECT id, tokens_used, updated_at, {c_expr}, {m_expr}, {r_expr} FROM threads WHERE tokens_used > 0"
        ).fetchall()
    finally:
        conn.close()

    events: list[dict[str, Any]] = []
    rls: list[float] = []
    cross_day_threads = 0

    for tid, tok_used, upd, crt, db_m, rpath in rows:
        ts = norm_epoch(upd if (upd or 0) > 0 else (crt or 0))
        db_model = str(db_m or "").strip()
        rpath_s = str(rpath or "").strip()

        if rpath_s and ts >= (cutoff - 86400):
            parsed = ref_read_codex_rollout(rpath_s, allow_zstd=allow_zstd)
            if parsed is not None:
                turns, turn_rls, rep_tot = parsed
                for rt in turn_rls:
                    if cutoff <= rt <= now_epoch:
                        rls.append(rt)
                if turns:
                    rtot = sum(t["in"] + t["cr"] + t["cw"] + t["out"] for t in turns)
                    is_mis = (rtot != int(tok_used)) or (rep_tot is not None and rep_tot != int(tok_used))
                    touched_days = {utc_date_str(t["ts"] if t["ts"] is not None else ts) for t in turns if cutoff <= (t["ts"] if t["ts"] is not None else ts) <= now_epoch}
                    if len(touched_days) >= 2:
                        cross_day_threads += 1
                    for t in turns:
                        ev_ts = t["ts"] if t["ts"] is not None else ts
                        if not (cutoff <= ev_ts <= now_epoch):
                            continue
                        m = t["model"] or db_model
                        priced = 1 if is_model_recognized(m) else 0
                        events.append(
                            {
                                "vendor": "codex",
                                "ts": ev_ts,
                                "in": t["in"],
                                "cr": t["cr"],
                                "cw": t["cw"],
                                "out": t["out"],
                                "total": t["in"] + t["cr"] + t["cw"] + t["out"],
                                "priced": priced,
                                "unmatched": 0 if priced else 1,
                                "mismatch": is_mis,
                                "thread_id": str(tid),
                            }
                        )
                    continue

        if cutoff <= ts <= now_epoch:
            unmatched = 1 if (db_model and db_model not in ("—", "unknown", "default", "?") and not is_model_recognized(db_model)) else 0
            events.append(
                {
                    "vendor": "codex",
                    "ts": ts,
                    "in": 0,
                    "cr": 0,
                    "cw": 0,
                    "out": 0,
                    "total": int(tok_used),
                    "priced": 0,
                    "unmatched": unmatched,
                    "mismatch": False,
                    "thread_id": str(tid),
                }
            )
    return (events, rls, cross_day_threads)


def ref_collect_opencode(db_path: pathlib.Path, cutoff: float, now_epoch: float) -> tuple[list[dict[str, Any]], list[float], int]:
    if not db_path.is_file():
        return ([], [], 0)
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
        sess_v2: dict[str, tuple[float, int, int, int, int, str, float]] = {}
        if "session_v2" in tables:
            for sid, cost, tin, tout, treas, tcr, tcw, raw_m, tupd in conn.execute(
                "SELECT id, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, model, time_updated FROM session_v2"
            ).fetchall():
                m_str = str(raw_m or "").strip()
                if m_str.startswith("{"):
                    try:
                        m_str = str(json.loads(m_str).get("id") or m_str)
                    except json.JSONDecodeError:
                        pass
                sess_v2[str(sid)] = (
                    float(cost or 0.0),
                    int(tin or 0),
                    int(tout or 0) + int(treas or 0),
                    int(tcr or 0),
                    int(tcw or 0),
                    m_str,
                    norm_epoch(int(tupd or 0)),
                )

        msg_table = "session_message" if "session_message" in tables else ("message" if "message" in tables else None)
        msg_rows: list[tuple[Any, ...]] = []
        if msg_table:
            cols = {r[1] for r in conn.execute(f"PRAGMA table_info({msg_table})").fetchall()}
            t_col = "type" if "type" in cols else "NULL"
            tc_col = "time_created" if "time_created" in cols else "0"
            where = "WHERE type IN ('assistant', 'compaction') OR instr(data, 'error') > 0 OR instr(data, '429') > 0" if "type" in cols else ""
            msg_rows = conn.execute(f"SELECT id, session_id, {t_col}, {tc_col}, data FROM {msg_table} {where}").fetchall()
    finally:
        conn.close()

    events: list[dict[str, Any]] = []
    rls: list[float] = []
    covered_sessions: set[str] = set()
    days_by_session: dict[str, set[str]] = {}

    for _mid, sid_raw, rtype, raw_tc, data_str in msg_rows:
        sid = str(sid_raw or "")
        try:
            d = json.loads(data_str or "{}")
        except json.JSONDecodeError:
            continue
        if not isinstance(d, dict):
            continue
        tdict = d.get("time") if isinstance(d.get("time"), dict) else {}
        c_val = tdict.get("created") if tdict.get("created") is not None else tdict.get("completed")
        if isinstance(c_val, (int, float)) and c_val > 0:
            mts = norm_epoch(c_val)
        elif raw_tc and int(raw_tc) > 0:
            mts = norm_epoch(int(raw_tc))
        else:
            mts = sess_v2.get(sid, (0, 0, 0, 0, 0, "", now_epoch))[6]

        if (is_structured_rate_limit(d.get("error")) or has_structured_429_status(d)) and cutoff <= mts <= now_epoch:
            rls.append(mts)

        role = str(rtype or d.get("role") or d.get("type") or "").strip()
        if role and role not in ("assistant", "compaction"):
            continue
        tok = d.get("tokens") if isinstance(d.get("tokens"), dict) else {}
        cache = tok.get("cache") if isinstance(tok.get("cache"), dict) else {}
        tin = max(0, int_or_zero(tok.get("input")))
        tout = max(0, int_or_zero(tok.get("output"))) + max(0, int_or_zero(tok.get("reasoning")))
        tcr = max(0, int_or_zero(cache.get("read")))
        tcw = max(0, int_or_zero(cache.get("write")))
        cost = float(d.get("cost") or 0.0) if isinstance(d.get("cost"), (int, float)) else 0.0
        if tin == 0 and tout == 0 and tcr == 0 and tcw == 0 and cost <= 0.0:
            continue
        covered_sessions.add(sid)
        if not (cutoff <= mts <= now_epoch):
            continue

        days_by_session.setdefault(sid, set()).add(utc_date_str(mts))
        m_field = d.get("model")
        if isinstance(m_field, dict):
            model = str(m_field.get("id") or m_field.get("modelID") or "")
        elif isinstance(m_field, str) and m_field:
            model = m_field
        else:
            model = str(d.get("modelID") or sess_v2.get(sid, (0, 0, 0, 0, 0, "", 0.0))[5])

        has_cost = cost > 0.0 or is_model_recognized(model)
        events.append(
            {
                "vendor": "opencode",
                "ts": mts,
                "in": tin,
                "cr": tcr,
                "cw": tcw,
                "out": tout,
                "total": tin + tcr + tcw + tout,
                "priced": 1 if has_cost else 0,
                "unmatched": 0 if has_cost else 1,
                "mismatch": False,
            }
        )

    for sid, (cost, tin, tout, tcr, tcw, model, tupd) in sess_v2.items():
        if sid in covered_sessions:
            continue
        if tin == 0 and tout == 0 and tcr == 0 and tcw == 0 and cost <= 0.0:
            continue
        if not (cutoff <= tupd <= now_epoch):
            continue
        has_cost = cost > 0.0 or is_model_recognized(model)
        events.append(
            {
                "vendor": "opencode",
                "ts": tupd,
                "in": tin,
                "cr": tcr,
                "cw": tcw,
                "out": tout,
                "total": tin + tcr + tcw + tout,
                "priced": 1 if has_cost else 0,
                "unmatched": 0 if has_cost else 1,
                "mismatch": False,
            }
        )

    cross_day = sum(1 for ds in days_by_session.values() if len(ds) >= 2)
    return (events, rls, cross_day)


def ref_extract_vibe_ts(obj: dict[str, Any]) -> float | None:
    for k in ("time_unix_ms", "timestamp", "created_at"):
        v = obj.get(k)
        if isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0:
            return norm_epoch(v)
        if isinstance(v, str):
            p = parse_iso_epoch(v)
            if p is not None:
                return p
    payload = obj.get("payload")
    if not isinstance(payload, dict):
        return None
    det = (payload.get("input") or {}).get("determinism") if isinstance(payload.get("input"), dict) else None
    if isinstance(det, dict):
        ms = det.get("time_unix_ms")
        if isinstance(ms, (int, float)) and ms > 0:
            return norm_epoch(ms)
    deltas = payload.get("delta")
    if isinstance(deltas, list):
        best_num = 0.0
        best_iso: float | None = None
        for d in deltas:
            entry = d.get("entry") if isinstance(d, dict) else None
            if not isinstance(entry, dict):
                continue
            for k in ("updatedAt", "createdAt"):
                v = entry.get(k)
                if isinstance(v, (int, float)) and v > best_num:
                    best_num = float(v)
                elif isinstance(v, str):
                    p = parse_iso_epoch(v)
                    if p is not None and (best_iso is None or p > best_iso):
                        best_iso = p
        if best_num > 0:
            return norm_epoch(best_num)
        if best_iso is not None:
            return best_iso
    sa = payload.get("session_api")
    if isinstance(sa, dict) and isinstance(sa.get("turn_outcomes"), dict):
        best = 0.0
        for tout in sa["turn_outcomes"].values():
            if isinstance(tout, dict) and isinstance(tout.get("completedAt"), (int, float)):
                best = max(best, float(tout["completedAt"]))
        if best > 0:
            return norm_epoch(best)
    return None


def ref_parse_relay_logs(ws_root: pathlib.Path) -> list[dict[str, Any]]:
    if not ws_root.is_dir():
        return []
    candidates: list[pathlib.Path] = []
    direct = ws_root / ".relay" / "LOG.md"
    if direct.is_file():
        candidates.append(direct)
    for child in sorted(ws_root.iterdir(), key=lambda p: p.name):
        if child.name.startswith("."):
            continue
        c = child / ".relay" / "LOG.md"
        if c.is_file():
            candidates.append(c)

    step_re = re.compile(r"^#{2,3}\s+([^\s:]+):\s*(.+)$")
    ts_re = re.compile(r"^(.*),\s*(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}(?::\d{2})?)\s*$")
    cost_re = re.compile(r"\bcost\s+\$([0-9]+(?:\.[0-9]+)?)")
    tok_re = re.compile(r"\btokens\s+([0-9,]+)")
    model_re = re.compile(r"\bmodel\s+(.+?)(?:,\s*(?:cost|tokens|session|outcome)\b|;|$)")
    ignored = ("- prompt:", "- files changed:", "- final message:", "- checks:", "- command:", "- workspace:", "- output")
    vmap = {"claude": "claude", "codex": "codex", "opencode": "opencode", "vibe": "vibe", "agy": "agy", "antigravity": "agy"}

    runs: list[dict[str, Any]] = []
    for log_p in candidates:
        mtime = log_p.stat().st_mtime
        steps: list[dict[str, Any]] = []
        cur: dict[str, Any] | None = None
        for line in log_p.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.startswith("#"):
                if cur is not None:
                    steps.append(cur)
                    cur = None
                m = step_re.match(line)
                if not m:
                    continue
                sid, rest = m.group(1), m.group(2).strip()
                vendor = next((vmap[pt] for pt in re.split(r"[-_]", sid.lower()) if pt in vmap), None)
                tm = ts_re.match(rest)
                ts_str = tm.group(2).strip() if tm else ""
                cur = {"stepID": sid, "vendor": vendor, "ts_str": ts_str, "model": "", "cost": None, "tokens": None}
                continue
            if cur is None or not line.startswith("- "):
                continue
            low = line.lower()
            if any(low.startswith(p) for p in ignored):
                continue
            mm = model_re.search(line)
            if mm:
                ms = mm.group(1).strip()
                if ms and ms != "?" and not ms.startswith("? "):
                    cur["model"] = ms
            cm = cost_re.search(line)
            if cm:
                cur["cost"] = float(cm.group(1))
            tkm = tok_re.search(line)
            if tkm:
                cur["tokens"] = int(tkm.group(1).replace(",", ""))
        if cur is not None:
            steps.append(cur)
        if steps:
            runs.append({"log_path": log_p, "mtime": mtime, "steps": steps})
    return runs


def ref_parse_local_relay_ts(ts_str: str, fallback: float) -> float:
    if not ts_str:
        return fallback
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S"):
        try:
            naive = dt.datetime.strptime(ts_str, fmt)
            return time.mktime(naive.timetuple())
        except ValueError:
            continue
    return fallback


def ref_collect_vibe_and_agy(
    home_dir: pathlib.Path, ws_root: pathlib.Path, cutoff: float, now_epoch: float
) -> tuple[list[dict[str, Any]], list[float], list[dict[str, Any]], list[float]]:
    vibe_dir = home_dir / ".vibe" / "logs" / "session" / "unified"
    cfg_toml = home_dir / ".vibe" / "config.toml"
    cfg_model = ""
    if cfg_toml.is_file():
        m_re = re.compile(r'^\s*active_model\s*=\s*"([^"]+)"')
        for ln in cfg_toml.read_text(encoding="utf-8", errors="ignore").splitlines():
            if ln.strip().startswith("["):
                break
            mm = m_re.match(ln)
            if mm:
                cfg_model = mm.group(1).strip()
                break

    vibe_events: list[dict[str, Any]] = []
    vibe_rls: list[float] = []
    unified_ids: set[str] = set()

    if vibe_dir.is_dir():
        for folder in sorted(vibe_dir.iterdir(), key=lambda p: p.name):
            if not folder.is_dir() or folder.name.startswith("."):
                continue
            meta_p = folder / "meta.json"
            meta = json.loads(meta_p.read_text(encoding="utf-8", errors="ignore")) if meta_p.is_file() else {}
            sid = str(meta.get("session_id") or folder.name).strip()
            unified_ids.add(sid)
            start_t = parse_iso_epoch(meta.get("start_time") if isinstance(meta.get("start_time"), str) else None)
            end_t = parse_iso_epoch(meta.get("end_time") if isinstance(meta.get("end_time"), str) else None)
            fallback_t = start_t or end_t or folder.stat().st_mtime
            m_cfg = meta.get("config") if isinstance(meta.get("config"), dict) else {}
            s_model = str(m_cfg.get("active_model") or m_cfg.get("model_name") or meta.get("model") or cfg_model or "").strip()

            jdir = folder / "journal"
            emitted = False
            if jdir.is_dir():
                seen_ok: set[str] = set()
                seen_err: set[str] = set()
                run_t = start_t or end_t
                for seg in sorted(jdir.glob("*.jsonl"), key=lambda p: p.name):
                    for ln in seg.read_text(encoding="utf-8", errors="ignore").splitlines():
                        try:
                            obj = json.loads(ln)
                        except json.JSONDecodeError:
                            continue
                        if not isinstance(obj, dict):
                            continue
                        rt = ref_extract_vibe_ts(obj)
                        if rt is not None:
                            run_t = rt
                        if obj.get("type") != "action_result":
                            continue
                        pl = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
                        aid = str(pl.get("action_id") or "").strip()
                        st = str(pl.get("state") or "")
                        res = pl.get("result") if isinstance(pl.get("result"), dict) else {}
                        ev_t = run_t if run_t is not None else fallback_t

                        if st == "succeeded" and res.get("type") == "completion_succeeded":
                            if aid:
                                if aid in seen_ok:
                                    continue
                                seen_ok.add(aid)
                            usage = (res.get("result") or {}).get("usage") if isinstance(res.get("result"), dict) else None
                            if not isinstance(usage, dict):
                                continue
                            rin = max(0, int_or_zero(usage.get("input_tokens")))
                            cin = max(0, int_or_zero(usage.get("cached_input_tokens")))
                            cw = max(0, int_or_zero(usage.get("cache_write_tokens")))
                            out = max(0, int_or_zero(usage.get("output_tokens")))
                            uin = max(0, rin - cin)
                            if (uin + cin + cw + out) <= 0:
                                continue
                            emitted = True
                            if cutoff <= ev_t <= now_epoch:
                                priced = 1 if is_model_recognized(s_model) else 0
                                vibe_events.append(
                                    {
                                        "vendor": "vibe",
                                        "ts": ev_t,
                                        "in": uin,
                                        "cr": cin,
                                        "cw": cw,
                                        "out": out,
                                        "total": uin + cin + cw + out,
                                        "priced": priced,
                                        "unmatched": 0 if priced else 1,
                                        "mismatch": False,
                                    }
                                )
                        elif st == "failed":
                            err_obj = res.get("error") if "error" in res else pl.get("error")
                            if is_structured_rate_limit(err_obj):
                                if aid:
                                    if aid in seen_err:
                                        continue
                                    seen_err.add(aid)
                                if cutoff <= ev_t <= now_epoch:
                                    vibe_rls.append(ev_t)

            if not emitted and isinstance(meta.get("stats"), dict) and cutoff <= fallback_t <= now_epoch:
                st_d = meta["stats"]
                it = int_or_zero(st_d.get("session_prompt_tokens")) + int_or_zero(st_d.get("prompt_tokens"))
                ot = int_or_zero(st_d.get("session_completion_tokens")) + int_or_zero(st_d.get("completion_tokens"))
                cs = float(st_d.get("session_cost") or 0.0)
                if it > 0 or ot > 0 or cs > 0:
                    vibe_events.append(
                        {
                            "vendor": "vibe",
                            "ts": fallback_t,
                            "in": 0,
                            "cr": 0,
                            "cw": 0,
                            "out": 0,
                            "total": it + ot,
                            "priced": 1 if cs > 0 else 0,
                            "unmatched": 0 if (cs > 0 or not s_model or is_model_recognized(s_model)) else 1,
                            "mismatch": False,
                        }
                    )

    runs = ref_parse_relay_logs(ws_root)
    agy_events: list[dict[str, Any]] = []
    for run in runs:
        rdir = run["log_path"].parent
        for st in run["steps"]:
            tok = st["tokens"] or 0
            cost = st["cost"] or 0.0
            if tok <= 0 and cost <= 0.0:
                continue
            ts = ref_parse_local_relay_ts(st["ts_str"], run["mtime"])
            if not (cutoff <= ts <= now_epoch):
                continue
            m = st["model"]
            has_model = bool(m and m not in ("—", "unknown", "default", "?"))
            unmatched = 1 if (cost <= 0.0 and has_model and not is_model_recognized(m)) else 0
            if st["vendor"] == "vibe":
                vibe_sid = None
                for cand in (
                    rdir / f"{st['stepID']}.vibe" / "export.json",
                    rdir / f"{st['stepID']}.vibe" / "session" / "meta.json",
                    rdir / f"{st['stepID']}.vibe" / "meta.json",
                ):
                    if cand.is_file():
                        try:
                            vibe_sid = str(json.loads(cand.read_text(encoding="utf-8")).get("session_id") or "").strip()
                        except Exception:
                            vibe_sid = None
                        if vibe_sid:
                            break
                if vibe_sid and vibe_sid in unified_ids:
                    continue
                vibe_events.append(
                    {
                        "vendor": "vibe",
                        "ts": ts,
                        "in": 0,
                        "cr": 0,
                        "cw": 0,
                        "out": 0,
                        "total": tok,
                        "priced": 1 if cost > 0 else 0,
                        "unmatched": unmatched,
                        "mismatch": False,
                    }
                )
            elif st["vendor"] == "agy":
                agy_events.append(
                    {
                        "vendor": "agy",
                        "ts": ts,
                        "in": 0,
                        "cr": 0,
                        "cw": 0,
                        "out": 0,
                        "total": tok,
                        "priced": 1 if cost > 0 else 0,
                        "unmatched": unmatched,
                        "mismatch": False,
                    }
                )

    agy_rls: list[float] = []
    agy_log_dir = home_dir / ".gemini" / "antigravity-cli" / "log"
    status_re = re.compile(r"(?:^|[\s,;(])(?:status|http_status|status_code)=429(?=$|[\s,;)])")
    iso_lead_re = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))")
    if agy_log_dir.is_dir():
        for lf in sorted(agy_log_dir.glob("*.log"), key=lambda p: p.name):
            mod = lf.stat().st_mtime
            if mod < cutoff:
                continue
            for ln in lf.read_text(encoding="utf-8", errors="ignore").splitlines():
                is429 = bool(status_re.search(ln))
                if not is429 and ln.startswith("{"):
                    try:
                        o = json.loads(ln)
                        is429 = isinstance(o, dict) and (has_structured_429_status(o) or is_structured_rate_limit(o.get("error")))
                    except json.JSONDecodeError:
                        pass
                if is429:
                    im = iso_lead_re.match(ln)
                    rt = parse_iso_epoch(im.group(1)) if im else None
                    ev_t = rt if rt is not None else mod
                    if cutoff <= ev_t <= now_epoch:
                        agy_rls.append(ev_t)

    return (vibe_events, vibe_rls, agy_events, agy_rls)


def ref_collect_all_utc(home_dir: pathlib.Path, ws_root: pathlib.Path, now_epoch: int) -> dict[str, Any]:
    cutoff = float(now_epoch - 30 * 86400)
    now_f = float(now_epoch)

    c_ev, c_rl = ref_collect_claude(home_dir / ".claude" / "projects", cutoff, now_f)
    x_ev, x_rl, x_cross = ref_collect_codex(home_dir / ".codex" / "state_5.sqlite", cutoff, now_f)
    o_ev, o_rl, o_cross = ref_collect_opencode(home_dir / ".local" / "share" / "opencode" / "opencode.db", cutoff, now_f)
    v_ev, v_rl, a_ev, a_rl = ref_collect_vibe_and_agy(home_dir, ws_root, cutoff, now_f)

    all_events = c_ev + x_ev + o_ev + v_ev + a_ev
    all_rls = [("claude", t) for t in c_rl] + [("codex", t) for t in x_rl] + [("opencode", t) for t in o_rl] + [("vibe", t) for t in v_rl] + [("agy", t) for t in a_rl]

    today_utc = dt.datetime.fromtimestamp(now_epoch, tz=dt.timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    day0 = today_utc - dt.timedelta(days=13)
    days: dict[str, dict[str, Any]] = {}
    for offset in range(14):
        d_start = day0 + dt.timedelta(days=offset)
        d_end = d_start + dt.timedelta(days=1)
        s_ep, e_ep = d_start.timestamp(), d_end.timestamp()
        d_key = d_start.strftime("%Y-%m-%d")

        v_cells: dict[str, dict[str, Any]] = {}
        for v in VENDORS:
            ve = [e for e in all_events if e["vendor"] == v and s_ep <= e["ts"] < e_ep and e["ts"] <= now_f]
            vrl = sum(1 for rv, rt in all_rls if rv == v and s_ep <= rt < e_ep and rt <= now_f)
            v_cells[v] = {
                "in": sum(e["in"] for e in ve),
                "cr": sum(e["cr"] for e in ve),
                "cw": sum(e["cw"] for e in ve),
                "out": sum(e["out"] for e in ve),
                "total": sum(e["total"] for e in ve),
                "records": len(ve),
                "priced": sum(e["priced"] for e in ve),
                "unmatched": sum(e["unmatched"] for e in ve),
                "mismatch": any(e["mismatch"] for e in ve),
                "rl429": vrl,
            }
        days[d_key] = {
            "vendors": v_cells,
            "total": sum(c["total"] for c in v_cells.values()),
            "priced": sum(c["priced"] for c in v_cells.values()),
            "unmatched": sum(c["unmatched"] for c in v_cells.values()),
            "codex_mismatch": v_cells["codex"]["mismatch"],
            "rl429": sum(c["rl429"] for c in v_cells.values()),
        }

    five_h_cutoff = now_f - 5 * 3600.0
    five_h_by_vendor: dict[str, dict[str, int]] = {}
    for v in VENDORS:
        ve5 = [e for e in all_events if e["vendor"] == v and five_h_cutoff <= e["ts"] <= now_f]
        five_h_by_vendor[v] = {
            "total": sum(e["total"] for e in ve5),
            "records": len(ve5),
        }

    return {
        "days": days,
        "five_hours": five_h_by_vendor,
        "codex_cross_day_threads": x_cross,
        "opencode_cross_day_sessions": o_cross,
        "total_events": len(all_events),
    }


def rel_diff(cli_val: int, ref_val: int) -> float:
    if cli_val == ref_val:
        return 0.0
    denom = max(1, abs(ref_val), abs(cli_val))
    return abs(cli_val - ref_val) / float(denom)


def compare_14d_matrix(cli_doc: dict[str, Any], ref_doc: dict[str, Any]) -> tuple[bool, float, int]:
    max_diff = 0.0
    cells_checked = 0
    ok = True
    cli_days = {d["date"]: d for d in cli_doc["dailyBreakdown"]}
    if set(cli_days.keys()) != set(ref_doc["days"].keys()):
        return (False, 1.0, 0)

    for d_key, r_day in ref_doc["days"].items():
        c_day = cli_days[d_key]
        for v in VENDORS:
            cells_checked += 1
            cv = c_day["vendors"][v]
            rv = r_day["vendors"][v]
            for c_field, r_field in (
                ("totalTokens", "total"),
                ("uncachedInputTokens", "in"),
                ("cachedInputTokens", "cr"),
                ("cacheWriteTokens", "cw"),
                ("outputTokens", "out"),
                ("recordCount", "records"),
            ):
                d = rel_diff(int(cv[c_field]), int(rv[r_field]))
                max_diff = max(max_diff, d)
                if d >= 0.01:
                    ok = False
    return (ok, max_diff, cells_checked)


def seed_rich_14d_5vendor_fixture(home_dir: pathlib.Path, ws_dir: pathlib.Path, now_epoch: int) -> None:
    c_dir = home_dir / ".claude" / "projects" / "-tmp-synth14"
    x_dir = home_dir / ".codex"
    o_dir = home_dir / ".local" / "share" / "opencode"
    v_root = home_dir / ".vibe"
    v_uni = v_root / "logs" / "session" / "unified" / "vibe-14d" / "journal"
    r_dir = ws_dir / "pipe14" / ".relay"
    r_vibe_exp = r_dir / "01-vibe.vibe"
    for d in (c_dir, x_dir, o_dir, v_uni, r_vibe_exp):
        d.mkdir(parents=True, exist_ok=True)

    today_utc = dt.datetime.fromtimestamp(now_epoch, tz=dt.timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    day0 = today_utc - dt.timedelta(days=13)

    # 1. Claude JSONL across all 14 days (including 2-chunk streaming dedup + 1 unknown model per odd day)
    c_lines: list[str] = []
    for i in range(14):
        ts = (day0 + dt.timedelta(days=i, hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        c_lines.append(
            json.dumps(
                {
                    "type": "assistant",
                    "timestamp": ts,
                    "sessionId": f"cs-{i // 3}",
                    "requestId": f"crq-{i}-a",
                    "message": {
                        "id": f"cm-{i}-a",
                        "model": "claude-sonnet-5-5",
                        "usage": {
                            "input_tokens": 1000 * (i + 1),
                            "output_tokens": 100,
                            "cache_read_input_tokens": 4000 * (i + 1),
                            "cache_creation_input_tokens": 200,
                        },
                    },
                }
            )
        )
        c_lines.append(
            json.dumps(
                {
                    "type": "assistant",
                    "timestamp": ts,
                    "sessionId": f"cs-{i // 3}",
                    "requestId": f"crq-{i}-a",
                    "message": {
                        "id": f"cm-{i}-a",
                        "model": "claude-sonnet-5-5",
                        "usage": {
                            "input_tokens": 1000 * (i + 1),
                            "output_tokens": 300 * (i + 1),
                            "cache_read_input_tokens": 4000 * (i + 1),
                            "cache_creation_input_tokens": 200,
                        },
                    },
                }
            )
        )
        if i % 2 == 1:
            c_lines.append(
                json.dumps(
                    {
                        "type": "assistant",
                        "timestamp": ts,
                        "sessionId": f"cs-{i // 3}",
                        "requestId": f"crq-{i}-u",
                        "message": {
                            "id": f"cm-{i}-u",
                            "model": "claude-fable-5-1",
                            "usage": {"input_tokens": 500, "output_tokens": 50},
                        },
                    }
                )
            )
    (c_dir / "s14.jsonl").write_text("\n".join(c_lines) + "\n", encoding="utf-8")

    # 2. Codex single cross-day rollout spanning all 14 days (with duplicate zero-delta events & turn_context model switch)
    roll_p = x_dir / "rollout-14d.jsonl"
    x_lines: list[str] = []
    cum_in = cum_cr = cum_out = 0
    for i in range(14):
        ts = (day0 + dt.timedelta(days=i, hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ")
        model = "gpt-6-luna" if i < 7 else "gpt-6.1-sol"
        x_lines.append(json.dumps({"timestamp": ts, "type": "turn_context", "payload": {"model": model}}))
        d_unc = 1500 * (i + 1)
        d_cr = 6000 * (i + 1)
        d_out = 250 * (i + 1)
        cum_in += d_unc + d_cr
        cum_cr += d_cr
        cum_out += d_out
        tot = cum_in + cum_out
        ev = {
            "timestamp": ts,
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "total_token_usage": {
                        "input_tokens": cum_in,
                        "cached_input_tokens": cum_cr,
                        "cache_write_input_tokens": 0,
                        "output_tokens": cum_out,
                        "total_tokens": tot,
                    }
                },
            },
        }
        x_lines.append(json.dumps(ev))
        if i % 4 == 0:
            x_lines.append(json.dumps(ev))  # duplicate consecutive zero-delta event
    roll_p.write_text("\n".join(x_lines) + "\n", encoding="utf-8")

    cx_conn = sqlite3.connect(str(x_dir / "state_5.sqlite"))
    cx_conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT)")
    cx_conn.execute("INSERT INTO threads VALUES ('th-14d', '/tmp/p', ?, ?, 'gpt-6.1-sol', ?)", (cum_in + cum_out, now_epoch - 120, str(roll_p)))
    cx_conn.commit()
    cx_conn.close()

    # 3. OpenCode cross-day session_message across days 1..13 + fallback session_v2 on day 0
    oc_conn = sqlite3.connect(str(o_dir / "opencode.db"))
    oc_conn.execute(
        "CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, model TEXT, time_updated INTEGER)"
    )
    oc_conn.execute(
        "CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT)"
    )
    d0_ms = int((day0 + dt.timedelta(hours=1)).timestamp() * 1000)
    oc_conn.execute("INSERT INTO session_v2 VALUES ('ses-fb', '/tmp/p', 0.05, 4000, 500, 0, 12000, 0, 'deepseek-v4.1-flash', ?)", (d0_ms,))
    oc_conn.execute("INSERT INTO session_v2 VALUES ('ses-13d', '/tmp/p', 1.20, 90000, 15000, 2000, 300000, 1000, 'deepseek-v4.1-flash', ?)", ((now_epoch - 60) * 1000,))
    for i in range(1, 14):
        ms = int((day0 + dt.timedelta(days=i, hours=2, minutes=30)).timestamp() * 1000)
        rtype = "compaction" if i == 6 else "assistant"
        data_json = json.dumps(
            {
                "model": {"id": "deepseek-v4.1-flash", "providerID": "opencode-go"},
                "cost": 0.02 * i,
                "time": {"created": ms},
                "tokens": {"input": 2000 * i, "output": 300 * i, "reasoning": 50, "cache": {"read": 8000 * i, "write": 100}},
            }
        )
        oc_conn.execute("INSERT INTO session_message VALUES (?, 'ses-13d', ?, ?, ?, ?, ?)", (f"om-{i}", rtype, i, ms, ms, data_json))
    oc_conn.commit()
    oc_conn.close()

    # 4. Mistral Vibe unified session with 2 journal segments spanning all 14 days + relay export.json dedup
    (v_root / "config.toml").write_text('active_model = "deepseek-v4-1-flash-1017"\n', encoding="utf-8")
    (v_uni.parent / "meta.json").write_text(
        json.dumps({"session_id": "vibe-14d", "start_time": day0.strftime("%Y-%m-%dT%H:%M:%SZ"), "config": {}}),
        encoding="utf-8",
    )
    seg1: list[str] = []
    seg2: list[str] = []
    seq = 1
    for i in range(14):
        ms = int((day0 + dt.timedelta(days=i, hours=1, minutes=45)).timestamp() * 1000)
        target = seg1 if i < 7 else seg2
        target.append(json.dumps({"sequence": seq, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": ms}}}}))
        seq += 1
        rec = json.dumps(
            {
                "sequence": seq,
                "type": "action_result",
                "payload": {
                    "action_id": f"va-{i}",
                    "state": "succeeded",
                    "result": {
                        "type": "completion_succeeded",
                        "result": {
                            "usage": {
                                "input_tokens": 10000 + i * 500,
                                "cached_input_tokens": 7000 + i * 300,
                                "cache_write_tokens": 100,
                                "output_tokens": 400 + i * 20,
                                "reasoning_tokens": 80,
                                "total_tokens": 10500 + i * 520,
                            }
                        },
                    },
                },
            }
        )
        target.append(rec)
        if i == 6:
            seg2.append(rec)  # duplicate action_id replayed across segment boundary
        seq += 1
    (v_uni / "0000000000000001.jsonl").write_text("\n".join(seg1) + "\n", encoding="utf-8")
    (v_uni / "0000000000000050.jsonl").write_text("\n".join(seg2) + "\n", encoding="utf-8")
    (r_vibe_exp / "export.json").write_text('{"session_id":"vibe-14d"}\n', encoding="utf-8")

    # 5. Antigravity steps in .relay/LOG.md + 01-vibe step deduplicated via 01-vibe.vibe/export.json
    r_lines = [
        "# Agent Relay Log",
        "",
        f"## 01-vibe: ok, 40s, {(today_utc + dt.timedelta(hours=1)).strftime('%Y-%m-%d %H:%M')}",
        "- vibe: model deepseek-v4-1-flash-1017, tokens 99,999, cost $0.25",
        "",
    ]
    for i in range(2, 12):
        local_dt = dt.datetime.fromtimestamp((day0 + dt.timedelta(days=i, hours=2)).timestamp())
        r_lines += [
            f"## {i:02d}-agy: ok, 55s, {local_dt.strftime('%Y-%m-%d %H:%M')}",
            f"- agy: model gemini-4-carbon-high, tokens {80000 + i * 1000:,}",
            "",
        ]
    (r_dir / "LOG.md").write_text("\n".join(r_lines) + "\n", encoding="utf-8")


def run_m1_scripted_mutations() -> tuple[bool, str]:
    """W1: Copy Package.swift + Sources + Tests to an isolated temp dir, run 5 M1-specific mutations, verify each fails its named test."""
    mutations = [
        (
            "M1-codex-session-ts",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "let evTS = ev.timestamp ?? ts",
            "let evTS = ts",
            "AgentBarCoreTests.CollectorsTests/codexCrossDayRolloutEventsAndPerDayMismatch",
            "M1 B3+B15: Codex cross-day rollout splits turns by event timestamp",
        ),
        (
            "M2-opencode-ignore-messages",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "if let msgTable {",
            "if false, let msgTable {",
            "AgentBarCoreTests.CollectorsTests/openCodeCrossDaySessionMessages",
            "M1 B3: OpenCode cross-day session_message splits events by per-message timestamp",
        ),
        (
            "M3-vibe-no-action-dedup",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "guard seenActionIDs.insert(actionID).inserted else { return }",
            "_ = seenActionIDs.insert(actionID)",
            "AgentBarCoreTests.CollectorsTests/vibeUnifiedJournalMultiSegmentAndActionDedup",
            "M1 B5: Mistral Vibe unified journal multi-segment reader deduplicates action_id",
        ),
        (
            "M4-prose-429-false-positive",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "if isStructured429 {",
            'if isStructured429 || line.localizedCaseInsensitiveContains("rate") {',
            "AgentBarCoreTests.CollectorsTests/structured429RateLimitCountingIgnoresProse",
            "M1 B7: Counts 429 rate limits strictly from structured status/error codes",
        ),
        (
            "M5-drop-daily-b15-mismatch",
            "Sources/AgentBarCore/Collectors/LocalCollectors.swift",
            "hasCodexRolloutMismatch: codexDay.hasRolloutMismatch,",
            "hasCodexRolloutMismatch: false,",
            "AgentBarCoreTests.CLITests/dailyBreakdownCarriesPerDayB14PricingAndB15Mismatch",
            "M1 Part 2: Exposes 14-day dailyBreakdown in --cli snapshot and --cli daily",
        ),
    ]

    with tempfile.TemporaryDirectory(prefix="agentbar-m1-mutations-") as tmpdir:
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
                named_failed = (test_display in combined) and (
                    "✘ Test" in combined or "recorded an issue" in combined or "failed" in combined
                )
                if proc.returncode == 0 or not compiled or not ran or not named_failed:
                    return (
                        False,
                        f"{label} did not fail cleanly (rc={proc.returncode}, compiled={compiled}, ran={ran}, named_failed={named_failed})",
                    )
                details.append(f"{label}=RED(rc={proc.returncode})")
            finally:
                fpath.write_text(original, encoding="utf-8")

        clean_proc = subprocess.run(
            [
                "swift",
                "test",
                "--no-parallel",
                "--filter",
                "AgentBarCoreTests.CollectorsTests",
                "--filter",
                "AgentBarCoreTests.CLITests",
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
    print(f"AgentBar M1 Independent Acceptance Ledger (measurement date: {dt.date.today().isoformat()})")
    print(f"Binary: {rel_bin}")
    print(f"Frozen evaluation epoch (--now): {now_epoch} (UTC day={utc_date_str(now_epoch)})")
    print("=" * 78)

    # ------------------------------------------------------------------
    # Row 1: Cross-day long session per-event splitting (Codex, OpenCode, Vibe)
    # ------------------------------------------------------------------
    with tempfile.TemporaryDirectory(prefix="agentbar-m1-row1-") as tmpdir:
        thome = pathlib.Path(tmpdir) / "home"
        tws = pathlib.Path(tmpdir) / "ws"
        (thome / ".codex").mkdir(parents=True)
        (thome / ".local" / "share" / "opencode").mkdir(parents=True)
        v_jdir = thome / ".vibe" / "logs" / "session" / "unified" / "vs-3d" / "journal"
        v_jdir.mkdir(parents=True)
        tws.mkdir(parents=True)

        today_utc = dt.datetime.fromtimestamp(now_epoch, tz=dt.timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
        d_m2 = today_utc - dt.timedelta(days=2)
        d_m1 = today_utc - dt.timedelta(days=1)
        d_0 = today_utc
        # Pick timestamps guaranteed <= now_epoch on d_0
        t_d2 = d_m2.timestamp() + 3600
        t_d1 = d_m1.timestamp() + 3600
        t_d0 = min(float(now_epoch - 30), d_0.timestamp() + max(1.0, (now_epoch - d_0.timestamp()) * 0.5))

        iso_d2 = dt.datetime.fromtimestamp(t_d2, tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        iso_d1 = dt.datetime.fromtimestamp(t_d1, tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        iso_d0 = dt.datetime.fromtimestamp(t_d0, tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        # 3-day Codex rollout (105k, 157k, 63k -> sum=325k)
        roll_3d = thome / ".codex" / "rollout-3d.jsonl"
        roll_3d.write_text(
            "\n".join(
                [
                    json.dumps({"timestamp": iso_d2, "type": "turn_context", "payload": {"model": "gpt-6-luna"}}),
                    json.dumps({"timestamp": iso_d2, "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 100000, "cached_input_tokens": 80000, "cache_write_input_tokens": 0, "output_tokens": 5000, "total_tokens": 105000}}}}),
                    json.dumps({"timestamp": iso_d2, "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 100000, "cached_input_tokens": 80000, "cache_write_input_tokens": 0, "output_tokens": 5000, "total_tokens": 105000}}}}),
                    json.dumps({"timestamp": iso_d1, "type": "turn_context", "payload": {"model": "gpt-6.1-sol"}}),
                    json.dumps({"timestamp": iso_d1, "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 250000, "cached_input_tokens": 200000, "cache_write_input_tokens": 0, "output_tokens": 12000, "total_tokens": 262000}}}}),
                    json.dumps({"timestamp": iso_d0, "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 310000, "cached_input_tokens": 240000, "cache_write_input_tokens": 0, "output_tokens": 15000, "total_tokens": 325000}}}}),
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        cx_c = sqlite3.connect(str(thome / ".codex" / "state_5.sqlite"))
        cx_c.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT)")
        cx_c.execute("INSERT INTO threads VALUES ('th-3d', '/tmp/p', 325000, ?, 'gpt-6.1-sol', ?)", (int(t_d0), str(roll_3d)))
        cx_c.commit()
        cx_c.close()

        # 3-day OpenCode session_message (50k, 80k, 90k -> 220k)
        oc_c = sqlite3.connect(str(thome / ".local" / "share" / "opencode" / "opencode.db"))
        oc_c.execute("CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, model TEXT, time_updated INTEGER)")
        oc_c.execute("CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT)")
        oc_c.execute("INSERT INTO session_v2 VALUES ('oc-3d', '/tmp/p', 0.30, 30000, 10000, 0, 180000, 0, 'deepseek-v4.1-flash', ?)", (int(t_d0 * 1000),))
        for seq_i, (ep, tot_cr) in enumerate([(t_d2, 40000), (t_d1, 65000), (t_d0, 75000)], start=1):
            ms = int(ep * 1000)
            oc_c.execute(
                "INSERT INTO session_message VALUES (?, 'oc-3d', 'assistant', ?, ?, ?, ?)",
                (f"m{seq_i}", seq_i, ms, ms, json.dumps({"model": {"id": "deepseek-v4.1-flash"}, "cost": 0.1, "time": {"created": ms}, "tokens": {"input": 8000 if seq_i == 1 else (10000 if seq_i == 2 else 12000), "output": 2000 if seq_i == 1 else (5000 if seq_i == 2 else 3000), "reasoning": 0, "cache": {"read": tot_cr, "write": 0}}})),
            )
        oc_c.commit()
        oc_c.close()

        # 3-day Vibe unified multi-segment journal (12.5k, 22k, 31k)
        (v_jdir.parent / "meta.json").write_text(json.dumps({"session_id": "vs-3d", "start_time": iso_d2, "config": {"active_model": "deepseek-v4-1-flash-1017"}}), encoding="utf-8")
        (v_jdir / "0000000000000001.jsonl").write_text(
            "\n".join(
                [
                    json.dumps({"sequence": 1, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": int(t_d2 * 1000)}}}}),
                    json.dumps({"sequence": 2, "type": "action_result", "payload": {"action_id": "a1", "state": "succeeded", "result": {"type": "completion_succeeded", "result": {"usage": {"input_tokens": 12000, "cached_input_tokens": 8000, "cache_write_tokens": 0, "output_tokens": 500, "total_tokens": 12500}}}}}),
                    json.dumps({"sequence": 3, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": int(t_d1 * 1000)}}}}),
                    json.dumps({"sequence": 4, "type": "action_result", "payload": {"action_id": "a2", "state": "succeeded", "result": {"type": "completion_succeeded", "result": {"usage": {"input_tokens": 20000, "cached_input_tokens": 15000, "cache_write_tokens": 1000, "output_tokens": 1000, "total_tokens": 22000}}}}}),
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        (v_jdir / "0000000000000020.jsonl").write_text(
            "\n".join(
                [
                    json.dumps({"sequence": 20, "type": "action_result", "payload": {"action_id": "a2", "state": "succeeded", "result": {"type": "completion_succeeded", "result": {"usage": {"input_tokens": 20000, "cached_input_tokens": 15000, "cache_write_tokens": 1000, "output_tokens": 1000, "total_tokens": 22000}}}}}),
                    json.dumps({"sequence": 21, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": int(t_d0 * 1000)}}}}),
                    json.dumps({"sequence": 22, "type": "action_result", "payload": {"action_id": "a3", "state": "succeeded", "result": {"type": "completion_succeeded", "result": {"usage": {"input_tokens": 30000, "cached_input_tokens": 25000, "cache_write_tokens": 0, "output_tokens": 1000, "total_tokens": 31000}}}}}),
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        r1_cli = run_cli_json(bin_path, "snapshot", ["--lang", "en", "--tz", "UTC", "--home", str(thome), "--workspace", str(tws), "--now", str(now_epoch)])
        r1_ref = ref_collect_all_utc(thome, tws, now_epoch)
        row1_ok, row1_max_diff, _ = compare_14d_matrix(r1_cli, r1_ref)
        k2, k1, k0 = d_m2.strftime("%Y-%m-%d"), d_m1.strftime("%Y-%m-%d"), d_0.strftime("%Y-%m-%d")
        c_by_day = {d["date"]: d for d in r1_cli["dailyBreakdown"]}
        row1_ok = (
            row1_ok
            and row1_max_diff == 0.0
            and c_by_day[k2]["vendors"]["codex"]["totalTokens"] == 105000
            and c_by_day[k1]["vendors"]["codex"]["totalTokens"] == 157000
            and c_by_day[k0]["vendors"]["codex"]["totalTokens"] == 63000
            and c_by_day[k2]["vendors"]["opencode"]["totalTokens"] == 50000
            and c_by_day[k1]["vendors"]["opencode"]["totalTokens"] == 80000
            and c_by_day[k0]["vendors"]["opencode"]["totalTokens"] == 90000
            and c_by_day[k2]["vendors"]["vibe"]["totalTokens"] == 12500
            and c_by_day[k1]["vendors"]["vibe"]["totalTokens"] == 22000
            and c_by_day[k0]["vendors"]["vibe"]["totalTokens"] == 31000
        )

    if not row1_ok:
        failures.append("Row 1 (Cross-day per-event timestamp splitting)")
    print(
        f"[Row 1] {'PASS' if row1_ok else 'FAIL'} | Cross-day 3d sessions ({k2}..{k0}): "
        f"Codex=[105k, 157k, 63k], OpenCode=[50k, 80k, 90k], Vibe=[12.5k, 22k, 31k], max_diff={row1_max_diff:.4%}"
    )

    # ------------------------------------------------------------------
    # Row 2: 14-day x 5-vendor daily ledger (< 1% diff; synthetic + live host)
    # ------------------------------------------------------------------
    with tempfile.TemporaryDirectory(prefix="agentbar-m1-row2-synth-") as tmpdir:
        shome = pathlib.Path(tmpdir) / "home"
        sws = pathlib.Path(tmpdir) / "ws"
        seed_rich_14d_5vendor_fixture(shome, sws, now_epoch)
        synth_daily_cli = run_cli_json(bin_path, "daily", ["--lang", "en", "--tz", "UTC", "--home", str(shome), "--workspace", str(sws), "--now", str(now_epoch)])
        synth_daily_ref = ref_collect_all_utc(shome, sws, now_epoch)
        synth14_ok, synth14_max_diff, synth14_cells = compare_14d_matrix(synth_daily_cli, synth_daily_ref)

    live_ws = EFFECTIVE_HOME / "Projects"
    live_cli_en = run_cli_json(bin_path, "snapshot", ["--lang", "en", "--tz", "UTC", "--now", str(now_epoch)])
    live_cli_zh = run_cli_json(bin_path, "snapshot", ["--lang", "zh", "--tz", "UTC", "--now", str(now_epoch)])
    live_ref = ref_collect_all_utc(EFFECTIVE_HOME, live_ws, now_epoch)
    live14_ok, live14_max_diff, live14_cells = compare_14d_matrix(live_cli_en, live_ref)

    if live_ref["total_events"] > 0:
        v_14d_totals = {
            v: sum(int(d["vendors"][v]["totalTokens"]) for d in live_cli_en["dailyBreakdown"])
            for v in VENDORS
        }
        live_summary = (
            f"live {live14_cells} cells max_diff={live14_max_diff:.4%} "
            f"(cross-day threads: codex={live_ref['codex_cross_day_threads']}, opencode={live_ref['opencode_cross_day_sessions']}; "
            f"14d tokens: claude={v_14d_totals['claude']:,}, codex={v_14d_totals['codex']:,}, "
            f"opencode={v_14d_totals['opencode']:,}, vibe={v_14d_totals['vibe']:,}, agy={v_14d_totals['agy']:,})"
        )
    else:
        live_summary = f"empty HOME -> all {live14_cells} cells=0 (max_diff={live14_max_diff:.4%})"

    row2_ok = synth14_ok and live14_ok
    if not row2_ok:
        failures.append(f"Row 2 (14d x 5-vendor daily ledger: synth_diff={synth14_max_diff:.4%}, live_diff={live14_max_diff:.4%})")
    print(
        f"[Row 2] {'PASS' if row2_ok else 'FAIL'} | 14d x 5-vendor ledger: "
        f"synth {synth14_cells} cells max_diff={synth14_max_diff:.4%}; {live_summary}"
    )

    # ------------------------------------------------------------------
    # Row 3: Rolling 5-hour window (`fiveHours`: [now - 5h, now])
    # ------------------------------------------------------------------
    with tempfile.TemporaryDirectory(prefix="agentbar-m1-row3-5h-") as tmpdir:
        thome = pathlib.Path(tmpdir) / "home"
        tws = pathlib.Path(tmpdir) / "ws"
        c_p = thome / ".claude" / "projects" / "-tmp-5h"
        x_p = thome / ".codex"
        o_p = thome / ".local" / "share" / "opencode"
        v_p = thome / ".vibe" / "logs" / "session" / "unified" / "v-5h" / "journal"
        for d in (c_p, x_p, o_p, v_p, tws):
            d.mkdir(parents=True, exist_ok=True)

        t_8h = now_epoch - 8 * 3600
        t_outside = now_epoch - 5 * 3600 - 120
        t_inside = now_epoch - 5 * 3600 + 120
        t_1h = now_epoch - 3600
        upd_10m = now_epoch - 600

        fmt_z = lambda ep: dt.datetime.fromtimestamp(ep, tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        # Claude: 2 old turns (10k each) + 2 turns inside 5h (7k + 3k = 10k)
        (c_p / "c5h.jsonl").write_text(
            "\n".join(
                json.dumps({"type": "assistant", "timestamp": fmt_z(ep), "sessionId": "sc", "requestId": f"r{idx}", "message": {"id": f"m{idx}", "model": "claude-sonnet-5-5", "usage": {"input_tokens": tok - 1000, "output_tokens": 1000}}})
                for idx, (ep, tok) in enumerate([(t_8h, 10000), (t_outside, 10000), (t_inside, 7000), (t_1h, 3000)])
            )
            + "\n",
            encoding="utf-8",
        )

        # Codex: updated_at = 10m ago; turns at 8h (50k), outside (40k), inside (25k), 1h (15k) -> 5h = 40k, total = 130k
        roll5 = x_p / "roll5.jsonl"
        roll5.write_text(
            "\n".join(
                [
                    json.dumps({"timestamp": fmt_z(t_8h), "type": "turn_context", "payload": {"model": "gpt-6.1-sol"}}),
                    json.dumps({"timestamp": fmt_z(t_8h), "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 48000, "cached_input_tokens": 40000, "cache_write_input_tokens": 0, "output_tokens": 2000, "total_tokens": 50000}}}}),
                    json.dumps({"timestamp": fmt_z(t_outside), "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 86000, "cached_input_tokens": 70000, "cache_write_input_tokens": 0, "output_tokens": 4000, "total_tokens": 90000}}}}),
                    json.dumps({"timestamp": fmt_z(t_inside), "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 110000, "cached_input_tokens": 90000, "cache_write_input_tokens": 0, "output_tokens": 5000, "total_tokens": 115000}}}}),
                    json.dumps({"timestamp": fmt_z(t_1h), "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 124000, "cached_input_tokens": 100000, "cache_write_input_tokens": 0, "output_tokens": 6000, "total_tokens": 130000}}}}),
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        cxc = sqlite3.connect(str(x_p / "state_5.sqlite"))
        cxc.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT)")
        cxc.execute("INSERT INTO threads VALUES ('th5', '/tmp/p', 130000, ?, 'gpt-6.1-sol', ?)", (upd_10m, str(roll5)))
        cxc.commit()
        cxc.close()

        # OpenCode: time_updated = 10m ago; 2 outside turns (30k each) + 2 inside turns (18k + 12k = 30k)
        occ = sqlite3.connect(str(o_p / "opencode.db"))
        occ.execute("CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, model TEXT, time_updated INTEGER)")
        occ.execute("CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT)")
        occ.execute("INSERT INTO session_v2 VALUES ('s5', '/tmp/p', 0.2, 20000, 4000, 0, 66000, 0, 'deepseek-v4.1-flash', ?)", (upd_10m * 1000,))
        for idx, (ep, tok) in enumerate([(t_8h, 30000), (t_outside, 30000), (t_inside, 18000), (t_1h, 12000)], start=1):
            ms = ep * 1000
            occ.execute(
                "INSERT INTO session_message VALUES (?, 's5', 'assistant', ?, ?, ?, ?)",
                (f"om{idx}", idx, ms, ms, json.dumps({"model": {"id": "deepseek-v4.1-flash"}, "cost": 0.05, "time": {"created": ms}, "tokens": {"input": 2000, "output": 1000, "reasoning": 0, "cache": {"read": tok - 3000, "write": 0}}})),
            )
        occ.commit()
        occ.close()

        # Vibe: 1 outside turn (15k) + 1 inside turn (9k)
        (v_p.parent / "meta.json").write_text(json.dumps({"session_id": "v-5h", "start_time": fmt_z(t_8h), "end_time": fmt_z(upd_10m), "config": {"active_model": "deepseek-v4-1-flash-1017"}}), encoding="utf-8")
        (v_p / "0000000000000001.jsonl").write_text(
            "\n".join(
                [
                    json.dumps({"sequence": 1, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": t_outside * 1000}}}}),
                    json.dumps({"sequence": 2, "type": "action_result", "payload": {"action_id": "v1", "state": "succeeded", "result": {"type": "completion_succeeded", "result": {"usage": {"input_tokens": 14000, "cached_input_tokens": 10000, "cache_write_tokens": 0, "output_tokens": 1000, "total_tokens": 15000}}}}}),
                    json.dumps({"sequence": 3, "type": "core_input", "payload": {"input": {"determinism": {"time_unix_ms": t_1h * 1000}}}}),
                    json.dumps({"sequence": 4, "type": "action_result", "payload": {"action_id": "v2", "state": "succeeded", "result": {"type": "completion_succeeded", "result": {"usage": {"input_tokens": 8000, "cached_input_tokens": 6000, "cache_write_tokens": 0, "output_tokens": 1000, "total_tokens": 9000}}}}}),
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        s5_cli = run_cli_json(bin_path, "snapshot", ["--lang", "en", "--tz", "UTC", "--home", str(thome), "--workspace", str(tws), "--now", str(now_epoch)])
        synth5h_ok = (
            s5_cli["vendors"]["claude"]["windows"]["fiveHours"]["totalTokens"] == 10000
            and s5_cli["vendors"]["codex"]["windows"]["fiveHours"]["totalTokens"] == 40000
            and s5_cli["vendors"]["opencode"]["windows"]["fiveHours"]["totalTokens"] == 30000
            and s5_cli["vendors"]["vibe"]["windows"]["fiveHours"]["totalTokens"] == 9000
        )

    live5h_max_diff = 0.0
    live5h_ok = True
    for v in VENDORS:
        cli_5h_tok = int(live_cli_en["vendors"][v]["windows"]["fiveHours"]["totalTokens"] or 0)
        ref_5h_tok = int(live_ref["five_hours"][v]["total"])
        d = rel_diff(cli_5h_tok, ref_5h_tok)
        live5h_max_diff = max(live5h_max_diff, d)
        if d >= 0.01:
            live5h_ok = False

    row3_ok = synth5h_ok and live5h_ok
    if not row3_ok:
        failures.append("Row 3 (fiveHours rolling window event filtering)")
    print(
        f"[Row 3] {'PASS' if row3_ok else 'FAIL'} | fiveHours [now-5h, now]: "
        f"synth boundary (claude=10k, codex=40k, opencode=30k, vibe=9k) exact; live 5-vendor max_diff={live5h_max_diff:.4%}"
    )

    # ------------------------------------------------------------------
    # Row 4: Part 2 per-day B14, per-day B15, and structured B7 (429)
    # ------------------------------------------------------------------
    with tempfile.TemporaryDirectory(prefix="agentbar-m1-row4-") as tmpdir:
        thome = pathlib.Path(tmpdir) / "home"
        tws = pathlib.Path(tmpdir) / "ws"
        c_p = thome / ".claude" / "projects" / "-tmp-r4"
        x_p = thome / ".codex"
        for d in (c_p, x_p, tws):
            d.mkdir(parents=True, exist_ok=True)

        today_utc = dt.datetime.fromtimestamp(now_epoch, tz=dt.timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
        d_prev = today_utc - dt.timedelta(days=1)
        k_prev = d_prev.strftime("%Y-%m-%d")
        k_curr = today_utc.strftime("%Y-%m-%d")
        t_prev = d_prev.timestamp() + 3600
        t_curr = min(float(now_epoch - 30), today_utc.timestamp() + max(1.0, (now_epoch - today_utc.timestamp()) * 0.5))
        iso_prev = dt.datetime.fromtimestamp(t_prev, tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        iso_curr = dt.datetime.fromtimestamp(t_curr, tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        # Prose 429 traps on k_prev + 1 priced + 2 unknown models; structured 429 on k_curr
        (c_p / "r4.jsonl").write_text(
            "\n".join(
                [
                    json.dumps({"type": "assistant", "timestamp": iso_prev, "sessionId": "s", "requestId": "r1", "message": {"id": "m1", "model": "claude-sonnet-5-5", "content": [{"type": "text", "text": "frame rate is 429 fps; corporate tax rate limit discussion"}], "usage": {"input_tokens": 1000000, "output_tokens": 100000}}}),
                    json.dumps({"type": "assistant", "timestamp": iso_prev, "sessionId": "s", "requestId": "r2", "message": {"id": "m2", "model": "claude-fable-5-1", "usage": {"input_tokens": 50000, "output_tokens": 5000}}}),
                    json.dumps({"type": "assistant", "timestamp": iso_prev, "sessionId": "s", "requestId": "r3", "message": {"id": "m3", "model": "glm-5-3", "usage": {"input_tokens": 50000, "output_tokens": 5000}}}),
                    json.dumps({"type": "assistant", "isApiErrorMessage": True, "error": "invalid_request_error", "timestamp": iso_prev, "sessionId": "s", "requestId": "r-non429", "message": {"content": [{"type": "text", "text": "rate limit 429 in body"}]}}),
                    json.dumps({"type": "assistant", "isApiErrorMessage": True, "error": "rate_limit", "timestamp": iso_curr, "sessionId": "s", "requestId": "r-real429"}),
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        # Codex mismatch ONLY on k_curr (rollout=12000 vs sqlite=50000) + structured Codex 429 on k_curr
        rmis = x_p / "rmis.jsonl"
        rmis.write_text(
            "\n".join(
                [
                    json.dumps({"timestamp": iso_curr, "type": "turn_context", "payload": {"model": "gpt-6.1-sol"}}),
                    json.dumps({"timestamp": iso_curr, "type": "event_msg", "payload": {"type": "error", "error": {"type": "rate_limit_error", "status": 429}}}),
                    json.dumps({"timestamp": iso_curr, "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": 10000, "cached_input_tokens": 8000, "cache_write_input_tokens": 0, "output_tokens": 2000, "total_tokens": 12000}}}}),
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        cxc = sqlite3.connect(str(x_p / "state_5.sqlite"))
        cxc.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT)")
        cxc.execute("INSERT INTO threads VALUES ('th-mis-curr', '/tmp/p', 50000, ?, 'gpt-6.1-sol', ?)", (int(t_curr), str(rmis)))
        cxc.commit()
        cxc.close()

        r4_en = run_cli_json(bin_path, "daily", ["--lang", "en", "--tz", "UTC", "--home", str(thome), "--workspace", str(tws), "--now", str(now_epoch)])
        r4_zh = run_cli_json(bin_path, "daily", ["--lang", "zh", "--tz", "UTC", "--home", str(thome), "--workspace", str(tws), "--now", str(now_epoch)])
        en_days = {d["date"]: d for d in r4_en["dailyBreakdown"]}
        zh_days = {d["date"]: d for d in r4_zh["dailyBreakdown"]}

        synth_r4_ok = (
            en_days[k_prev]["pricedRecordCount"] == 1
            and en_days[k_prev]["unmatchedModelCount"] == 2
            and en_days[k_prev]["costNote"] == "Covers 1 priced records only; 2 unknown-model records excluded"
            and zh_days[k_prev]["costNote"] == "只含已计价的 1 条，另有 2 条未知型号未计入"
            and en_days[k_prev]["hasCodexRolloutMismatch"] is False
            and en_days[k_prev]["rateLimit429Count"] == 0
            and en_days[k_curr]["hasCodexRolloutMismatch"] is True
            and "th-mis-curr: rollout=12000 vs sqlite=50000" in (en_days[k_curr]["codexMismatchNote"] or "")
            and "th-mis-curr: rollout=12000 vs sqlite=50000" in (zh_days[k_curr]["codexMismatchNote"] or "")
            and en_days[k_curr]["rateLimit429Count"] == 2
        )

    # Live host per-day B14/B15/B7 exact match against Python oracle
    live_meta_ok = True
    for d_entry in live_cli_en["dailyBreakdown"]:
        dk = d_entry["date"]
        rd = live_ref["days"][dk]
        if (
            int(d_entry["pricedRecordCount"]) != rd["priced"]
            or int(d_entry["unmatchedModelCount"]) != rd["unmatched"]
            or bool(d_entry["hasCodexRolloutMismatch"]) != rd["codex_mismatch"]
            or int(d_entry["rateLimit429Count"]) != rd["rl429"]
        ):
            live_meta_ok = False
            break

    live_14d_unmatched = sum(int(d["unmatchedModelCount"]) for d in live_cli_en["dailyBreakdown"])
    live_14d_429 = sum(int(d["rateLimit429Count"]) for d in live_cli_en["dailyBreakdown"])
    live_14d_mis_days = sum(1 for d in live_cli_en["dailyBreakdown"] if d["hasCodexRolloutMismatch"])
    agy_not_complete = live_cli_en["vendors"]["agy"]["completeness"] != "complete" and live_cli_zh["vendors"]["agy"]["completeness"] != "complete"

    row4_ok = synth_r4_ok and live_meta_ok and agy_not_complete
    if not row4_ok:
        failures.append("Row 4 (Per-day B14/B15 & structured B7 429 counting)")
    print(
        f"[Row 4] {'PASS' if row4_ok else 'FAIL'} | Per-day B14/B15 + structured B7: "
        f"prose_429=0, structured_429=2, per-day costNote & mismatchNote EN/ZH verified; "
        f"live 14d unmatched={live_14d_unmatched}, 429s={live_14d_429}, mismatch_days={live_14d_mis_days}, agy={live_cli_en['vendors']['agy']['completeness']}"
    )

    # ------------------------------------------------------------------
    # Row 5: W1 Scripted isolated M1 mutations
    # ------------------------------------------------------------------
    mut_ok, mut_summary = run_m1_scripted_mutations()
    if not mut_ok:
        failures.append(f"Row 5 ({mut_summary})")
    print(f"[Row 5] {'PASS' if mut_ok else 'FAIL'} | Scripted isolated M1 mutations: {mut_summary}")

    mtime_end = plist_mtime()
    if mtime_start != mtime_end:
        failures.append(f"Preference plist mtime changed ({mtime_start} -> {mtime_end})")

    print("=" * 78)
    if failures:
        print(f"RESULT: FAILED ({len(failures)} check(s): {', '.join(failures)})")
        return 1
    print("RESULT: ALL 5 M1 ACCEPTANCE ROWS + PART 2 PER-DAY B14/B15 + STRUCTURED B7 + W1 PASSED (read-only verified).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
