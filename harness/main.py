"""
main.py — Earnest's golf brain entry point.

Threads two concurrent loops:
  1. telegram_bot.poll()  — long-polls Telegram, handles Steve's queries
  2. scheduler.run()      — 15-min ticks of the tournament state machine

Secrets injected via scripts/with-secrets.sh before exec.
Logs: ~/Library/Logs/earnest-golf.{out,err}.log + data/logs/earnest.jsonl

Usage:
    scripts/with-secrets.sh python harness/main.py [--dry-run]
"""

import logging
import os
import sys
import threading
from pathlib import Path

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("earnest.main")

# Ensure harness/ is on the path
sys.path.insert(0, str(Path(__file__).parent))

import telegram_bot
import scheduler


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(description="Earnest's Golf Brain")
    parser.add_argument("--dry-run", action="store_true",
                        help="Log R subprocess calls instead of executing them")
    args = parser.parse_args()

    # Pull secrets from environment (injected by with-secrets.sh)
    bot_token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    chat_id   = os.environ.get("TELEGRAM_CHAT_ID", "")

    if not bot_token or not chat_id:
        log.error("TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set. "
                  "Run via: scripts/with-secrets.sh python harness/main.py")
        sys.exit(1)

    # Load push rules feedback log path
    from pathlib import Path
    import yaml
    rules_path = Path(__file__).resolve().parent.parent / "config" / "earnest_push_rules.yaml"
    try:
        rules = yaml.safe_load(rules_path.read_text())
        feedback_log = str(Path(__file__).resolve().parent.parent /
                           rules.get("feedback_log", "data/logs/earnest_alert_feedback.jsonl"))
    except Exception:
        feedback_log = ""

    # Init modules
    telegram_bot.init(bot_token=bot_token, chat_id=chat_id)
    scheduler.init(bot_module=telegram_bot, dry_run=args.dry_run)

    log.info("Earnest golf brain starting up (dry_run=%s)", args.dry_run)

    # Thread 1: scheduler state machine (daemon — exits when main exits)
    sched_thread = threading.Thread(
        target=scheduler.run,
        kwargs={"interval_minutes": 15},
        name="scheduler",
        daemon=True,
    )
    sched_thread.start()
    log.info("Scheduler thread started")

    # Thread 2: Telegram long poll (main thread blocks here)
    log.info("Starting Telegram long poll...")
    try:
        telegram_bot.poll(feedback_log=feedback_log)
    except KeyboardInterrupt:
        log.info("Shutting down")
        telegram_bot.stop()
        scheduler.stop()


if __name__ == "__main__":
    main()
