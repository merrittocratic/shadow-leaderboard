#!/bin/bash
# ============================================================================
# with-secrets.sh — Keychain-based secret injection for shadow-leaderboard
# ============================================================================
# Reads only the secrets shadow-leaderboard needs from the macOS Keychain
# (service: "autopilot") and exports them, then exec's the given command.
#
# Used by Earnest on the Mac Mini to fire R scripts and the Python harness
# without exposing the full 1Password stack.
#
# Master secret management lives in ~/autopilot/scripts/keychain-sync.sh.
# This wrapper only READS — it does not add/update secrets.
#
# Usage (from Earnest's scheduler, launchd, or interactively on the Mini):
#   /Users/<user>/shadow-leaderboard/scripts/with-secrets.sh \
#       /opt/homebrew/bin/Rscript R/08_live_leaderboard.R
#
#   /Users/<user>/shadow-leaderboard/scripts/with-secrets.sh \
#       python harness/main.py
#
# On the laptop (dev), prefer the existing pattern:
#   op run --env-file=.env.template -- Rscript R/<script>.R
# ============================================================================

set -euo pipefail

KEYCHAIN_SERVICE="autopilot"

# Only the secrets shadow-leaderboard itself reads.
SECRETS=(
  GOLF_API_KEY
  ANTHROPIC_API_KEY
  TELEGRAM_BOT_TOKEN
  TELEGRAM_CHAT_ID
)

FAILED=()
for SECRET in "${SECRETS[@]}"; do
  VALUE=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$SECRET" -w 2>/dev/null) || true
  if [ -z "$VALUE" ]; then
    FAILED+=("$SECRET")
  else
    export "$SECRET"="$VALUE"
  fi
done

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "[with-secrets] WARNING: Missing Keychain secrets: ${FAILED[*]}" >&2
  echo "[with-secrets] Set them with: ~/autopilot/scripts/keychain-sync.sh <KEY> <VALUE>" >&2
fi

exec "$@"
