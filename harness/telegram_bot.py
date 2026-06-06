"""
telegram_bot.py — Earnest's Telegram interface.

Long-polls the Bot API for messages from Steve, dispatches to
live_harness.run_query, and provides send_push() for scheduler-initiated
alerts.

Three update types handled:
  1. message      — text query from Steve → ack + query + reply
  2. callback_query — inline button tap (shakedown feedback / field confirm)
  3. errors       — surfaced as plaintext to Steve so failures aren't silent
"""

import json
import logging
import os
import threading
import time
from typing import Any, Callable

import requests

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

_BOT_TOKEN: str = ""
_CHAT_ID: str   = ""
_ALLOWLIST: set[str] = set()

_BASE: str = ""

_poll_offset: int = 0
_poll_lock = threading.Lock()

TIMEOUT_S = 30   # long-poll timeout


def init(bot_token: str, chat_id: str) -> None:
    """Call once from main.py before starting poll()."""
    global _BOT_TOKEN, _CHAT_ID, _ALLOWLIST, _BASE
    _BOT_TOKEN = bot_token
    _CHAT_ID   = str(chat_id)
    _ALLOWLIST = {_CHAT_ID}
    _BASE      = f"https://api.telegram.org/bot{_BOT_TOKEN}"


# ---------------------------------------------------------------------------
# Low-level HTTP helpers
# ---------------------------------------------------------------------------

def _api(method: str, payload: dict | None = None, **kwargs) -> dict:
    url  = f"{_BASE}/{method}"
    resp = requests.post(url, json=payload or {}, timeout=20, **kwargs)
    data = resp.json()
    if not data.get("ok"):
        log.warning("Telegram API error (%s): %s", method, data)
    return data


def _get_updates(offset: int) -> list[dict]:
    resp = requests.get(
        f"{_BASE}/getUpdates",
        params={"offset": offset, "timeout": TIMEOUT_S, "allowed_updates": ["message", "callback_query"]},
        timeout=TIMEOUT_S + 10,
    )
    data = resp.json()
    if data.get("ok"):
        return data.get("result", [])
    log.warning("getUpdates error: %s", data)
    return []


# ---------------------------------------------------------------------------
# Send helpers (used by scheduler and bot loop)
# ---------------------------------------------------------------------------

def send_message(text: str, chat_id: str | None = None, reply_markup: dict | None = None) -> dict:
    payload: dict[str, Any] = {
        "chat_id": chat_id or _CHAT_ID,
        "text":    text[:4096],
        "parse_mode": "Markdown",
    }
    if reply_markup:
        payload["reply_markup"] = reply_markup
    return _api("sendMessage", payload)


def send_push(text: str, inline_keyboard: list | None = None) -> dict:
    """Send a proactive push alert to Steve (called by scheduler)."""
    markup = {"inline_keyboard": inline_keyboard} if inline_keyboard else None
    return send_message(text, reply_markup=markup)


def edit_message_text(chat_id: str, message_id: int, new_text: str) -> dict:
    return _api("editMessageText", {
        "chat_id":    chat_id,
        "message_id": message_id,
        "text":       new_text[:4096],
    })


# ---------------------------------------------------------------------------
# Inline keyboard builders
# ---------------------------------------------------------------------------

def build_shakedown_keyboard(alert_id: str) -> list:
    return [[
        {"text": "👍 keeper",      "callback_data": f"shake:{alert_id}:keeper"},
        {"text": "👎 noise",       "callback_data": f"shake:{alert_id}:noise"},
        {"text": "🔇 mute player", "callback_data": f"shake:{alert_id}:mute"},
    ]]


def build_confirm_keyboard(prompt_id: str) -> list:
    return [[
        {"text": "👍 yes, fire it", "callback_data": f"confirm:{prompt_id}:yes"},
        {"text": "👎 skip",         "callback_data": f"confirm:{prompt_id}:no"},
    ]]


# ---------------------------------------------------------------------------
# Shakedown feedback logger
# ---------------------------------------------------------------------------

_feedback_log_path: str = ""


def _init_feedback_log(path: str) -> None:
    global _feedback_log_path
    import pathlib
    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    _feedback_log_path = path


def _log_feedback(entry: dict) -> None:
    if not _feedback_log_path:
        return
    with open(_feedback_log_path, "a") as f:
        f.write(json.dumps(entry) + "\n")


# ---------------------------------------------------------------------------
# Update handlers
# ---------------------------------------------------------------------------

# External callback for scheduler-side confirm taps
_confirm_callbacks: dict[str, Callable[[str, str], None]] = {}


def register_confirm_callback(prompt_id: str, fn: Callable[[str, str], None]) -> None:
    """Register a one-shot callback for a field-set confirmation button tap."""
    _confirm_callbacks[prompt_id] = fn


def _handle_message(update: dict) -> None:
    msg     = update["message"]
    chat_id = str(msg["chat"]["id"])
    text    = msg.get("text", "").strip()
    msg_id  = msg["message_id"]

    if chat_id not in _ALLOWLIST:
        log.warning("Message from unlisted chat_id %s — ignoring", chat_id)
        return

    if not text or text.startswith("/"):
        return  # ignore commands and empty messages

    log.info("Inbound from %s: %s", chat_id, text[:120])

    # Acknowledge
    ack = send_message("⛳ thinking...", chat_id=chat_id)
    ack_id = ack.get("result", {}).get("message_id")

    # Run query
    try:
        from live_harness import run_query
        answer = run_query(text)
    except Exception as e:
        answer = f"⚠️ Query failed: {type(e).__name__}: {str(e)[:200]}"
        log.exception("live_harness.run_query failed")

    # Delete ack, send answer
    if ack_id:
        _api("deleteMessage", {"chat_id": chat_id, "message_id": ack_id})
    send_message(answer, chat_id=chat_id)


def _handle_callback_query(update: dict) -> None:
    cq      = update["callback_query"]
    chat_id = str(cq["message"]["chat"]["id"])
    msg_id  = cq["message"]["message_id"]
    data    = cq.get("data", "")
    cq_id   = cq["id"]

    # Acknowledge the tap to stop the spinner
    _api("answerCallbackQuery", {"callback_query_id": cq_id})

    if chat_id not in _ALLOWLIST:
        return

    parts = data.split(":")

    if parts[0] == "shake" and len(parts) == 3:
        _, alert_id, action = parts
        _log_feedback({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                        "alert_id": alert_id, "action": action})
        tag = {"keeper": "👍 logged", "noise": "👎 logged", "mute": "🔇 muted"}.get(action, "✓")
        orig_text = cq["message"].get("text", "")
        edit_message_text(chat_id, msg_id, f"{orig_text}\n\n({tag})")

    elif parts[0] == "confirm" and len(parts) == 3:
        _, prompt_id, answer = parts
        fn = _confirm_callbacks.pop(prompt_id, None)
        if fn:
            try:
                fn(prompt_id, answer)
            except Exception:
                log.exception("confirm callback failed")
        orig_text = cq["message"].get("text", "")
        tag = "👍 confirmed" if answer == "yes" else "👎 skipped"
        edit_message_text(chat_id, msg_id, f"{orig_text}\n\n({tag})")


# ---------------------------------------------------------------------------
# Main poll loop (runs in its own thread)
# ---------------------------------------------------------------------------

_running = True


def stop() -> None:
    global _running
    _running = False


def poll(feedback_log: str = "") -> None:
    """Long-poll Telegram indefinitely. Call this in a daemon thread."""
    global _poll_offset, _running
    if feedback_log:
        _init_feedback_log(feedback_log)

    log.info("Telegram bot polling started (chat_id=%s)", _CHAT_ID)
    while _running:
        try:
            updates = _get_updates(_poll_offset)
        except Exception:
            log.exception("getUpdates failed, retrying in 5s")
            time.sleep(5)
            continue

        for upd in updates:
            _poll_offset = upd["update_id"] + 1
            try:
                if "message" in upd:
                    _handle_message(upd)
                elif "callback_query" in upd:
                    _handle_callback_query(upd)
            except Exception:
                log.exception("Update handler crashed for update_id=%s", upd.get("update_id"))
