"""
scheduler.py — Earnest's tournament state machine.

States:
  off_week       → daily 7am poll for upcoming events
  field_pending  → event within 7 days; poll every 6h for populated field;
                   send Telegram confirmation before firing R/07
  pretournament  → 07 fired; idle until round 1 starts
  in_round       → every 30 min: live check, heater/crasher push eval
  between_rounds → round complete; fire R/08, commit artifact
  post_event     → fire eval_export, send tournament wrap, back to off_week

State is persisted to data/cache/earnest_state.json (crash-safe).
Structured events logged to data/logs/earnest.jsonl.
"""

import hashlib
import json
import logging
import os
import re
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import requests
import schedule
import yaml

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

REPO_ROOT  = Path(__file__).resolve().parent.parent
STATE_FILE = REPO_ROOT / "data" / "cache" / "earnest_state.json"
LOG_FILE   = REPO_ROOT / "data" / "logs" / "earnest.jsonl"
RULES_FILE = REPO_ROOT / "config" / "earnest_push_rules.yaml"
SECRETS_SH = REPO_ROOT / "scripts" / "with-secrets.sh"

DG_BASE_URL = "https://feeds.datagolf.com"

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

DEFAULT_STATE: dict = {
    "mode":                    "off_week",
    "event_name":              None,
    "event_slug":              None,
    "event_year":              None,
    "tournament_start_date":   None,   # "YYYY-MM-DD" — set when event detected
    "tournament_end_date":     None,   # start + 3 days (Thu-Sun format)
    "completed_rounds":        0,
    "r07_fired":               False,
    "last_live_check":         0,
    "last_field_poll":         0,
    "last_alert_ts":           0,
    "round_alert_counts":      {},     # {"heater": N, "crasher": N} per round
    "last_r08_fail_notified":  {},     # {str(round): unix ts} — spam guard
    "muted_players":           [],
    "shakedown_mode":          True,
    "updated_at":              None,
}


def _load_state() -> dict:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            log.warning("State file corrupt — resetting to defaults")
    return dict(DEFAULT_STATE)


def _save_state(state: dict) -> None:
    state["updated_at"] = datetime.now(timezone.utc).isoformat()
    STATE_FILE.write_text(json.dumps(state, indent=2))


def _log_event(event_type: str, **kwargs) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    entry = {"ts": datetime.now(timezone.utc).isoformat(), "event": event_type, **kwargs}
    with open(LOG_FILE, "a") as f:
        f.write(json.dumps(entry) + "\n")
    log.info("[%s] %s", event_type, kwargs)


# ---------------------------------------------------------------------------
# DataGolf helpers
# ---------------------------------------------------------------------------

def _dg_api_key() -> str:
    key = os.environ.get("GOLF_API_KEY", "")
    if not key:
        raise RuntimeError("GOLF_API_KEY not set")
    return key


def _dg_get(path: str, params: dict) -> Any:
    params = {"key": _dg_api_key(), **params}
    resp = requests.get(f"{DG_BASE_URL}/{path}", params=params, timeout=15)
    resp.raise_for_status()
    return resp.json()


def _get_dg_schedule() -> list[dict]:
    """Return upcoming PGA Tour events from DataGolf."""
    try:
        data = _dg_get("get-schedule", {"tour": "pga", "file_format": "json"})
        return data.get("schedule", []) if isinstance(data, dict) else []
    except Exception as e:
        log.warning("DG schedule fetch failed: %s", e)
        return []


def _get_dg_field(event_id: str) -> list[dict]:
    """Return field players for a specific event."""
    try:
        data = _dg_get("field-updates", {"tour": "pga", "file_format": "json"})
        players = data.get("field", []) if isinstance(data, dict) else []
        return players
    except Exception as e:
        log.warning("DG field fetch failed: %s", e)
        return []


def _get_dg_live() -> dict:
    """Return current live tournament stats."""
    try:
        return _dg_get("preds/live-tournament-stats",
                        {"stats": "sg_total", "round": "event_avg",
                         "display": "value", "file_format": "json"})
    except Exception as e:
        log.warning("DG live fetch failed: %s", e)
        return {}

# Alias used by _detect_active_tournament
_dg_live = _get_dg_live


def _detect_round_complete(live_data: dict) -> tuple[bool, int]:
    """Return (round_is_complete, completed_round_number)."""
    players = (live_data.get("live_stats") or live_data.get("rankings") or
               live_data.get("data") or [])
    if not players:
        return False, 0
    # Round complete when all players have thru == 18 (or F)
    thru_vals = []
    for p in players:
        thru = str(p.get("thru", "")).strip()
        if thru in ("F", "18"):
            thru_vals.append(18)
        else:
            try:
                thru_vals.append(int(thru))
            except ValueError:
                pass
    if not thru_vals:
        return False, 0
    # >90% of field finished → call the round complete
    pct_finished = sum(1 for t in thru_vals if t == 18) / len(thru_vals)
    # Infer round number from live data header
    round_num = int(live_data.get("round", 1) or 1)
    return pct_finished >= 0.90, round_num


def _field_fingerprint(live_data: dict) -> str:
    """Hash of current SG totals + thru values — changes when play resumes."""
    players = (live_data.get("live_stats") or live_data.get("rankings") or
               live_data.get("data") or [])
    key = "|".join(
        f"{p.get('player_name','')},{p.get('sg_total','')},{p.get('thru','')}"
        for p in sorted(players, key=lambda x: x.get("player_name", ""))
    )
    return hashlib.md5(key.encode()).hexdigest()


def _is_play_suspended(state: dict, live_data: dict) -> bool:
    """
    Return True if live data looks frozen (play suspended).
    Two consecutive identical field fingerprints = likely suspended.
    Resets automatically when data changes (play resumes).
    """
    fp = _field_fingerprint(live_data)
    history: list = state.setdefault("field_fingerprint_history", [])
    history.append(fp)
    if len(history) > 2:
        history.pop(0)
    state["field_fingerprint_history"] = history
    if len(history) < 2:
        return False
    suspended = history[0] == history[1]
    if suspended:
        log.info("Field fingerprint unchanged — play likely suspended, skipping alert eval")
    elif state.get("_was_suspended") and not suspended:
        log.info("Field fingerprint changed — play has resumed")
        if _bot_module:
            _bot_module.send_push(f"⛈️ Play has resumed at *{state.get('event_name', 'the tournament')}*!")
    state["_was_suspended"] = suspended
    return suspended


# ---------------------------------------------------------------------------
# R subprocess fire
# ---------------------------------------------------------------------------

def _fire_r(script_rel: str, *args: str, dry_run: bool = False) -> bool:
    """Run `scripts/with-secrets.sh Rscript R/<script>` from repo root."""
    cmd = [str(SECRETS_SH), "Rscript", str(REPO_ROOT / script_rel)] + list(args)
    log.info("Firing R: %s", " ".join(cmd))
    if dry_run:
        log.info("[DRY RUN] would exec: %s", cmd)
        return True
    try:
        result = subprocess.run(cmd, cwd=str(REPO_ROOT), capture_output=True,
                                 text=True, timeout=3600)
        if result.returncode != 0:
            log.error("R script failed (rc=%d): %s", result.returncode, result.stderr[-2000:])
            return False
        log.info("R script completed: %s", script_rel)
        return True
    except subprocess.TimeoutExpired:
        log.error("R script timed out: %s", script_rel)
        return False
    except Exception as e:
        log.error("R script error: %s", e)
        return False


def _git_commit_and_push(message: str) -> None:
    for cmd in (
        ["git", "add", "output/"],
        ["git", "commit", "-m", message],
        ["git", "push"],
    ):
        result = subprocess.run(cmd, cwd=str(REPO_ROOT), capture_output=True, text=True)
        if result.returncode != 0:
            log.warning("git %s failed: %s", cmd[1], result.stderr[:500])


# ---------------------------------------------------------------------------
# Push alert engine
# ---------------------------------------------------------------------------

def _load_rules() -> dict:
    try:
        return yaml.safe_load(RULES_FILE.read_text())
    except Exception:
        log.warning("Could not load push rules; using defaults")
        return {}


def _alert_id(event_slug: str, round_num: int, player: str, signal: str) -> str:
    raw = f"{event_slug}_r{round_num}_{player}_{signal}_{int(time.time() // 60)}"
    return hashlib.md5(raw.encode()).hexdigest()[:12]


def _format_alert(template: str, player: str, sg_val: float, percentile: float,
                   win_prob: float, top10_prob: float, thru: int) -> str:
    pct_label = f"{round(percentile * 100)}th"
    sg_str    = f"+{sg_val:.1f}" if sg_val >= 0 else f"{sg_val:.1f}"
    return (template
            .replace("{player}", player)
            .replace("{sg_value}", sg_str)
            .replace("{percentile_pct}", pct_label)
            .replace("{win_prob_pct}", f"{round(win_prob * 100)}%")
            .replace("{top10_prob_pct}", f"{round(top10_prob * 100)}%")
            .replace("{thru}", str(thru)))


def evaluate_push_alerts(state: dict, bot_module, dry_run: bool = False) -> None:
    """Run the heater/crasher evaluation and fire alerts if thresholds met."""
    rules  = _load_rules()
    now    = time.time()
    cooldown = rules.get("global_cooldown_minutes", 90) * 60
    if now - state.get("last_alert_ts", 0) < cooldown:
        log.debug("Global cooldown active, skipping push eval")
        return

    try:
        sys.path.insert(0, str(REPO_ROOT / "harness"))
        from tools import get_heating_up
        result = get_heating_up(
            state["event_slug"],
            state["event_year"],
            top_n=5,
            percentile_gate=rules.get("heater", {}).get("percentile_gate", 0.95),
        )
    except Exception as e:
        log.warning("get_heating_up failed: %s", e)
        return

    heater_rules  = rules.get("heater", {})
    crasher_rules = rules.get("crasher", {})
    round_num     = state.get("completed_rounds", 1) + 1
    round_key     = str(round_num)
    counts        = state.setdefault("round_alert_counts", {}).setdefault(round_key, {"heater": 0, "crasher": 0})
    shakedown     = rules.get("shakedown_mode", True) and state.get("shakedown_mode", True)
    muted         = set(state.get("muted_players", []))
    heater_tmpl   = rules.get("heater_template", "{player} {sg_value} SG thru {thru}, {percentile_pct} percentile. Win prob: {win_prob_pct}.")
    crasher_tmpl  = rules.get("crasher_template", "{player} {sg_value} SG below expectation thru {thru}, {percentile_pct} percentile. Win prob: {win_prob_pct}.")

    heater_cap  = heater_rules.get("per_round_cap", 3)
    crasher_cap = crasher_rules.get("per_round_cap", 2)

    sent_any = False

    for signal, players, cap, tmpl in [
        ("heater",  result.get("heaters", []),  heater_cap,  heater_tmpl),
        ("crasher", result.get("crashers", []), crasher_cap, crasher_tmpl),
    ]:
        if counts.get(signal, 0) >= cap:
            continue
        for p in players:
            if counts.get(signal, 0) >= cap:
                break
            name = p["player_name"]
            if name in muted:
                continue
            aid = _alert_id(state["event_slug"], round_num, name, signal)
            text = _format_alert(
                tmpl,
                player=name,
                sg_val=p.get("live_sg_total", 0),
                percentile=p.get("percentile", 0.5),
                win_prob=p.get("win_prob", 0),
                top10_prob=p.get("win_prob", 0),  # top10 not in heating_up result; use win_prob
                thru=p.get("thru", 0),
            )
            keyboard = None
            if shakedown:
                keyboard = bot_module.build_shakedown_keyboard(aid)
            if not dry_run:
                bot_module.send_push(text, inline_keyboard=keyboard)
                counts[signal] = counts.get(signal, 0) + 1
                state["last_alert_ts"] = int(now)
                sent_any = True
                _log_event("push_alert", signal=signal, player=name,
                            alert_id=aid, percentile=p.get("percentile"),
                            win_prob=p.get("win_prob"), thru=p.get("thru"))
            else:
                log.info("[DRY RUN] would send %s alert for %s", signal, name)

    if sent_any:
        _save_state(state)


# ---------------------------------------------------------------------------
# State machine tick
# ---------------------------------------------------------------------------

_state: dict = {}
_bot_module = None
_dry_run: bool = False


def _detect_active_tournament() -> dict | None:
    """
    Check if a tournament is currently in progress by querying DG live.
    Returns a partial state dict if one is found, else None.
    """
    try:
        live = _dg_live()
        players = (live.get("live_stats") or live.get("rankings") or
                   live.get("data") or [])
        if not players:
            return None
        # Any players with thru > 0 means a round is in progress or just finished
        active = any(
            str(p.get("thru", "0")).strip() not in ("0", "", "None")
            for p in players[:10]
        )
        if not active:
            return None
        event_name = live.get("event_name", "Unknown Event")
        event_slug = live.get("event_id", "").replace(" ", "_").lower() or "unknown"
        event_year = int(live.get("calendar_year", datetime.now().year))
        # Infer completed rounds from existing artifacts
        completed = 0
        for r in (3, 2, 1):
            if (REPO_ROOT / "output" / f"live_leaderboard_after_r{r}.rds").exists() or \
               (REPO_ROOT / "output" / f"live_leaderboard_after_r{r}.csv").exists():
                completed = r
                break
        log.info("Active tournament detected: %s (completed rounds: %d)", event_name, completed)

        # Try to get tournament dates from the schedule for the date-window guard.
        # DG's schedule API returns all season events, so recently completed
        # events are still present. Normalize both sides to avoid
        # case/punctuation mismatches between live and schedule responses.
        def _norm(s: str) -> str:
            return re.sub(r"[^a-z0-9]", "", s.lower())

        start_date = end_date = None
        try:
            for ev in _get_dg_schedule():
                if (_norm(ev.get("event_id",   "")) == _norm(event_slug) or
                        _norm(ev.get("event_name", "")) == _norm(event_name)):
                    start_str = ev.get("date", ev.get("start_date", ""))
                    if start_str:
                        start_dt   = _parse_date(start_str)
                        start_date = start_dt.strftime("%Y-%m-%d")
                        end_date   = (start_dt + timedelta(days=3)).strftime("%Y-%m-%d")
                    break
        except Exception:
            pass

        return {
            "event_name":            event_name,
            "event_slug":            event_slug,
            "event_year":            event_year,
            "completed_rounds":      completed,
            "r07_fired":             True,
            "tournament_start_date": start_date,
            "tournament_end_date":   end_date,
        }
    except Exception as e:
        log.warning("Active tournament detection failed: %s", e)
        return None


def init(bot_module, dry_run: bool = False) -> None:
    global _state, _bot_module, _dry_run
    _bot_module = bot_module
    _dry_run    = dry_run
    _state      = _load_state()
    # If we're in off_week but a tournament is actually running, recover into in_round.
    # Apply the same date-window guard used in _tick_between_rounds so that stale
    # post-tournament DG data cannot trigger a recovery on Mon/Tue/Wed.
    if _state["mode"] == "off_week":
        detected = _detect_active_tournament()
        if detected:
            start_str = detected.get("tournament_start_date")
            end_str   = detected.get("tournament_end_date")
            if not (start_str and end_str):
                # Fail closed: if we can't confirm the tournament window,
                # block recovery. Scheduler stays off_week and picks up the
                # real active event on the next normal poll cycle.
                log.warning(
                    "Startup recovery: could not resolve tournament dates for "
                    "'%s' (slug='%s') — blocking recovery to prevent stale-data "
                    "run. Will retry on next poll.",
                    detected.get("event_name"), detected.get("event_slug"),
                )
                _log_event("startup_recovery_blocked",
                           reason="dates_unresolvable",
                           event=detected.get("event_name"),
                           slug=detected.get("event_slug"))
                detected = None
            else:
                today      = datetime.now(timezone.utc).date()
                start_date = _parse_date(start_str).date()
                end_date   = _parse_date(end_str).date()
                if not (start_date <= today <= end_date + timedelta(days=1)):
                    log.warning(
                        "Startup recovery date-window guard: today %s outside "
                        "[%s, %s+1] — staying off_week", today, start_date, end_date,
                    )
                    _log_event("startup_recovery_blocked",
                               reason="outside_window",
                               today=str(today), event=detected.get("event_name"),
                               window_end=str(end_date))
                    detected = None
        if detected:
            _state.update(detected)
            _state["mode"] = "in_round"
            _save_state(_state)
            _log_event("startup_recovery", to="in_round", **detected)
    _log_event("scheduler_init", mode=_state["mode"])


def tick() -> None:
    """Called every 15 minutes by the schedule loop."""
    global _state
    mode = _state.get("mode", "off_week")
    now  = time.time()
    _log_event("tick", mode=mode)

    if mode == "off_week":
        _tick_off_week(now)
    elif mode == "field_pending":
        _tick_field_pending(now)
    elif mode == "pretournament":
        _tick_pretournament(now)
    elif mode == "in_round":
        _tick_in_round(now)
    elif mode == "between_rounds":
        _tick_between_rounds(now)
    elif mode == "post_event":
        _tick_post_event(now)
    else:
        log.warning("Unknown mode: %s — resetting to off_week", mode)
        _state["mode"] = "off_week"
        _save_state(_state)


def _tick_off_week(now: float) -> None:
    # Daily 7am check for upcoming events — only run once per day
    last = _state.get("last_field_poll", 0)
    if now - last < 20 * 3600:  # ~20h throttle (covers 24h with drift)
        return
    _state["last_field_poll"] = now
    schedule_data = _get_dg_schedule()
    # Look for events starting within 7 days
    today_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    for ev in schedule_data:
        start = ev.get("date", ev.get("start_date", ""))
        if not start:
            continue
        days_until = (_parse_date(start) - datetime.now(timezone.utc)).days
        if 0 <= days_until <= 7:
            _state["mode"]       = "field_pending"
            _state["event_name"] = ev.get("event_name", "Unknown Event")
            _state["event_slug"] = ev.get("event_id",   "unknown")
            _state["event_year"] = int(ev.get("calendar_year", datetime.now().year))
            start_dt = _parse_date(start)
            _state["tournament_start_date"] = start_dt.strftime("%Y-%m-%d")
            _state["tournament_end_date"]   = (start_dt + timedelta(days=3)).strftime("%Y-%m-%d")
            _save_state(_state)
            _log_event("transition", to="field_pending",
                        event=_state["event_name"], starts_in_days=days_until)
            return
    _save_state(_state)


def _tick_field_pending(now: float) -> None:
    last = _state.get("last_field_poll", 0)
    if now - last < 6 * 3600:
        return  # poll every 6h
    _state["last_field_poll"] = now
    field = _get_dg_field(_state.get("event_slug", ""))
    if len(field) >= 50:  # field is populated
        event_name = _state["event_name"]
        event_slug = _state["event_slug"]
        # Ask Steve for confirmation before firing R/07
        import uuid
        prompt_id = uuid.uuid4().hex[:8]

        def _on_confirm(pid: str, answer: str) -> None:
            if answer == "yes":
                success = _fire_r("R/07_pga_preview.R", dry_run=_dry_run)
                if success:
                    _state["mode"]      = "pretournament"
                    _state["r07_fired"] = True
                    _git_commit_and_push(f"chore: {event_slug} preview artifact")
                    _log_event("transition", to="pretournament", event=event_name)
                    if _bot_module:
                        _bot_module.send_push(f"✅ Preview generated for *{event_name}*. "
                                               "Ask me 'who's the model on?' when you're ready.")
                else:
                    if _bot_module:
                        _bot_module.send_push(f"⚠️ R/07_pga_preview.R failed for {event_name}. "
                                               "Check logs: `data/logs/earnest.jsonl`")
            else:
                _state["mode"] = "off_week"
                _log_event("field_confirm_skipped", event=event_name)
            _save_state(_state)

        if _bot_module:
            _bot_module.register_confirm_callback(prompt_id, _on_confirm)
            keyboard = _bot_module.build_confirm_keyboard(prompt_id)
            _bot_module.send_push(
                f"📅 *{event_name}* field is populated. Fire R/07 to generate the preview?",
                inline_keyboard=keyboard,
            )
        _save_state(_state)
    _save_state(_state)


def _tick_pretournament(now: float) -> None:
    # Idle — just check if round 1 has started
    live = _get_dg_live()
    players = (live.get("live_stats") or live.get("rankings") or live.get("data") or [])
    if players and any(str(p.get("thru", "0")) not in ("0", "", "None") for p in players[:5]):
        _state["mode"] = "in_round"
        _state["completed_rounds"] = 0
        _save_state(_state)
        _log_event("transition", to="in_round", event=_state["event_name"])


def _tick_in_round(now: float) -> None:
    last = _state.get("last_live_check", 0)
    if now - last < 30 * 60:  # 30-minute cadence for live checks
        return
    _state["last_live_check"] = now

    live = _get_dg_live()
    is_complete, round_num = _detect_round_complete(live)

    if is_complete:
        # Floor guard: DG can return stale/ambiguous round numbers after a
        # tournament ends. Never allow completed_rounds to regress.
        floor = _state.get("completed_rounds", 0)
        if round_num <= floor:
            log.warning(
                "Round-complete detection returned round %d but state floor is %d — ignoring",
                round_num, floor,
            )
        else:
            _state["mode"]             = "between_rounds"
            _state["completed_rounds"] = round_num
            _save_state(_state)
            _log_event("transition", to="between_rounds", completed_round=round_num)
            return

    # Not complete — check for suspension before running alert eval
    if _is_play_suspended(_state, live):
        _save_state(_state)
        return

    if _bot_module:
        evaluate_push_alerts(_state, _bot_module, dry_run=_dry_run)
    _save_state(_state)


def _tick_between_rounds(now: float) -> None:
    completed = _state.get("completed_rounds", 1)
    if completed >= 4:
        _state["mode"] = "post_event"
        _save_state(_state)
        _log_event("transition", to="post_event")
        return

    # Date-window guard: only fire R/08 during the tournament window.
    # Prevents stale post-tournament DG data from triggering spurious runs
    # on Mon/Tue/Wed after the event ends. Guard is skipped if dates were not
    # stored (e.g. startup recovery — those sessions are already in-window).
    start_str = _state.get("tournament_start_date")
    end_str   = _state.get("tournament_end_date")
    if start_str and end_str:
        today      = datetime.now(timezone.utc).date()
        start_date = _parse_date(start_str).date()
        end_date   = _parse_date(end_str).date()
        # Allow 1-day buffer after end for late finishes / slow DG updates
        if not (start_date <= today <= end_date + timedelta(days=1)):
            log.warning(
                "R/08 date-window guard: today %s is outside [%s, %s+1] — "
                "resetting to off_week to avoid stale-data run",
                today, start_date, end_date,
            )
            for key in ("event_name", "event_slug", "event_year", "r07_fired",
                        "tournament_start_date", "tournament_end_date",
                        "last_live_check", "round_alert_counts", "muted_players"):
                _state[key] = DEFAULT_STATE.get(key)
            _state["completed_rounds"] = 0
            _state["mode"] = "off_week"
            _save_state(_state)
            _log_event("date_window_guard", reset_to="off_week", today=str(today))
            return

    # Allow manual pause of R/08 retries (e.g. while data files are being synced)
    if _state.get("r08_paused"):
        log.info("R/08 paused (r08_paused=true in state) — skipping retry for round %d", completed)
        return

    # Fire R/08
    success = _fire_r("R/08_live_leaderboard.R", str(completed), dry_run=_dry_run)
    if success:
        _git_commit_and_push(f"chore: {_state['event_slug']} shadow leaderboard after R{completed}")
        if _bot_module:
            _bot_module.send_push(
                f"📊 Shadow Leaderboard updated after Round {completed} "
                f"(*{_state['event_name']}*). Ask me where things stand!"
            )
        _state["mode"] = "in_round"
        # Reset per-round alert counts for the new round
        round_key = str(completed + 1)
        _state.setdefault("round_alert_counts", {})[round_key] = {"heater": 0, "crasher": 0}
        _save_state(_state)
        _log_event("transition", to="in_round", next_round=completed + 1)
    else:
        log.error("R/08 failed for round %d — staying in between_rounds to retry", completed)
        # Rate-limit failure notifications to once per hour per round
        fail_log     = _state.setdefault("last_r08_fail_notified", {})
        last_notified = fail_log.get(str(completed), 0)
        if now - last_notified >= 3600:
            if _bot_module:
                _bot_module.send_push(
                    f"⚠️ R/08_live_leaderboard.R failed for Round {completed}. "
                    "Check `data/logs/earnest.jsonl`."
                )
            fail_log[str(completed)] = now
            _save_state(_state)


def _tick_post_event(now: float) -> None:
    slug = _state.get("event_slug", "unknown")
    year = _state.get("event_year", datetime.now().year)
    success = _fire_r("R/eval_export.R", slug, str(year), dry_run=_dry_run)
    if success:
        _git_commit_and_push(f"chore: {slug} {year} eval export")
        # Fire retrospective harness for tournament wrap
        try:
            sys.path.insert(0, str(REPO_ROOT / "harness"))
            from harness import run_eval
            wrap = run_eval(f"Give me a tournament wrap for {slug} {year}.", verbose=False)
            if _bot_module:
                _bot_module.send_push(f"🏆 *{_state['event_name']} wrap-up*\n\n{wrap}")
        except Exception as e:
            log.exception("Retrospective harness wrap failed: %s", e)
    # Return to off_week, reset event state
    for key in ("event_name", "event_slug", "event_year", "r07_fired",
                 "last_live_check", "round_alert_counts", "muted_players"):
        _state[key] = DEFAULT_STATE.get(key)
    _state["completed_rounds"] = 0
    _state["mode"] = "off_week"
    _save_state(_state)
    _log_event("transition", to="off_week")


def _parse_date(date_str: str):
    from datetime import datetime, timezone
    for fmt in ("%Y-%m-%d", "%Y/%m/%d", "%m/%d/%Y"):
        try:
            return datetime.strptime(date_str[:10], fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return datetime.now(timezone.utc)


# ---------------------------------------------------------------------------
# Schedule runner
# ---------------------------------------------------------------------------

_sched_running = True


def stop() -> None:
    global _sched_running
    _sched_running = False


def run(interval_minutes: int = 15) -> None:
    """Tick every interval_minutes. Runs forever; call in a daemon thread."""
    schedule.every(interval_minutes).minutes.do(tick)
    # Fire one tick immediately on startup
    tick()
    while _sched_running:
        schedule.run_pending()
        time.sleep(30)
