# Earnest's Golf Brain — Claude Code Brief

Earnest is a season-long Shadow Leaderboard operator on the Mac Mini.
Telegram is the human read channel into a system that's already doing work
in the background: scheduling R reruns at meaningful state transitions,
deriving "heating up" signals during live rounds, and pushing intelligently
gated alerts when something matters.

This is a builder's brief for Cousin Claude Code. Earnest's runtime voice
and decision rules live in his SYSTEM_PROMPT (separate artifact), not here.

---

## 1. Identity & Context

- **Operator:** Earnest — always-on OpenClaw agent on a Mac Mini M4. Already
  runs the newsletter curator (Gmail + Yahoo → ChromaDB → Streamlit)
  bi-weekly and pushes the digest via Telegram. Has outbound Telegram
  wired through BotFather and a working Anthropic API key in 1Password.
- **Builder:** Cousin Claude Code — runs on the laptop, lives in the
  `shadow-leaderboard` repo. Writes code. Does not run R scripts; the user
  runs all R/bash pipeline scripts manually during development. Once
  Earnest is live, *he* fires R scripts on schedule (see §5).
- **Brand:** Merrittocracy. Sister projects: `nfl-draft-model`, `content`,
  `autopilot`, `OpenClaw-Ops`. Director-level data scientist, deep R
  expertise. Day job at Florida Blue (kept fully separate).
- **Launch event:** 2026 US Open at Shinnecock Hills (June 18–21, 2026).
- **Long-term:** all PGA Tour events, season-long always-on.

## 2. What "Shadow Leaderboard" Means

From `INSTRUCTIONS.md`, verbatim:

> A "Shadow Leaderboard" — players re-sorted by underlying SG performance
> instead of their actual score — plus residual decomposition
> (sticky vs. lucky) and updated win probabilities.

The R pipeline produces this after each completed round in
`output/live_leaderboard_after_r{1,2,3}.csv`. Columns include
`predicted_sg_total`, `predicted_sg_residual`, `player_skill_prior`,
`sg_r{1,2,3}`, `form_residual_mean_8`, `win_prob`, `top5_prob`,
`top10_prob`. Pretournament predictions live in
`output/{tournament}_preview_{year}.csv` with similar shape minus the
in-tournament SG columns.

Earnest's job is to make this artifact (a) conversational over Telegram
on demand, and (b) **proactive** — flagging mid-round heaters before the
broadcast notices.

## 3. What Already Exists in This Repo

| Component | Path | Purpose |
|---|---|---|
| R pipeline | `R/00_config.R` → `R/08_live_leaderboard.R` | Feature eng, training, tuning, brms stack, weather, live re-scoring |
| Pretournament previews | `output/{us_open,pga,memorial}_preview_2026.csv` | Pre-event predictions |
| Live shadow leaderboard | `output/live_leaderboard_after_r{1,2,3}.{csv,rds}` | Post-round refresh |
| Eval table exporter | `R/eval_export.R` | Builds `output/eval/predictions_<tournament>_<year>.parquet` joining preds + actuals + OWGR/DG/Vegas baselines |
| Retrospective harness | `harness/{harness.py,tools.py,loader.py}` | Claude-powered diagnostic agent with strong SYSTEM_PROMPT, prompt caching, dispatch pattern. Tools: `list_available_evals`, `get_headline_metrics`, `get_slice_metrics` |
| Course taxonomy | `config/course_taxonomy_weighted.csv` | Course archetype weights |
| Weather | `R/02d_weather_features.R`, `R/weather_forecast.R` | Per-player forecast features |
| Laptop secret loading | `.env.template` + `op run` | `GOLF_API_KEY`, `ANTHROPIC_API_KEY` via 1Password CLI (dev only) |
| Mini secret loading | `scripts/with-secrets.sh` | macOS Keychain via `autopilot` service. Earnest never sees 1Password (see §8.6) |

The retrospective harness's loop, dispatch table, caching, and prompt
structure are the templates to copy. Do not reinvent them.

## 4. What This Project Adds

Three layers, in increasing breadth:

1. **Live tools** in `harness/tools.py` — read live/preview artifacts +
   DataGolf live endpoint, derive heating-up signals.
2. **Live agent loop** in `harness/live_harness.py` — separate from the
   retrospective harness, separate SYSTEM_PROMPT tuned for live
   conversation, wider tool set (live + retrospective both available).
3. **Earnest the season-long operator** in `harness/main.py` +
   `harness/telegram_bot.py` + `harness/scheduler.py` — runs continuously
   on the Mini. Long-polls Telegram for inbound queries, ticks a state
   machine every 15 minutes that fires R scripts at state transitions and
   evaluates push-notification thresholds during live play.

## 5. The Two Refresh Tiers

The most important architectural distinction in this project:

### Tier A — R-pipeline reruns (rare, state-driven, artifact-producing)

Earnest fires R scripts at **state transitions**, not on a clock. Roughly
5–6 R fires per tournament week:

| Trigger | R Script | Notes |
|---|---|---|
| DG field endpoint populates for next event | `R/07_pga_preview.R` | Typically Mon evening / Tue AM |
| Round 1 completes (auto-detected from DG live) | `R/08_live_leaderboard.R 1` | |
| Round 2 completes | `R/08_live_leaderboard.R 2` | |
| Round 3 completes | `R/08_live_leaderboard.R 3` | |
| Round 4 completes (tournament ends) | `R/eval_export.R <slug> <year>` | Then triggers retrospective harness via existing path |

R fires write to `output/` and commit. Each is expensive (especially the
brms stack); none should fire on a wall clock.

### Tier B — Python derivations (frequent, cheap, in-memory)

Pure Python against (already-computed predictions) + (fresh DataGolf live
SG). No R rerun. Runs every 15 minutes during live play to:

- Refresh the heating-up board (current in-progress SG vs. predicted SG
  distribution per player).
- Evaluate push-notification thresholds (§7).
- Cache live DG response for 60s so on-demand Telegram queries don't
  re-hit the API.

The heating-up signal is **percentile-based**, not probability-based —
we are not re-running win/top10 probabilities mid-round (that's a 2027
season investment, see §13).

## 6. The Earnest State Machine

One process on the Mini. Internal scheduler ticks every 15 min. State
lives in `data/cache/earnest_state.json` (crash-safe: next tick
reconstructs from DG endpoints + filesystem).

```
off_week        → Daily 7am poll of DG schedule. If event starts within
                  7 days and has a populated field, transition to
                  field_pending.

field_pending   → Poll DG field endpoint every 6 hours. When populated,
                  send Telegram confirmation: "📅 Looks like next event
                  is <name> at <venue>, <dates>. Fire R/07? 👍/👎."
                  On 👍: fire R/07_pga_preview.R, commit artifact,
                  transition to pretournament. On 👎: log skip, stay in
                  off_week until next Monday poll. Prevents false-fire
                  on weeks Steve isn't covering (LIV, Korn Ferry, etc.).

pretournament   → Idle. Telegram tools answer "who's the model on?" from
                  the fresh preview CSV. Wait for Thursday tee times.

in_round        → Every 30 min: pull DG live (60s cached), refresh
                  heater/crasher boards, evaluate push thresholds, send
                  alerts if triggered. (30 min ≈ ~2 holes per player —
                  the right grain to catch a hot/cold stretch without
                  re-firing on every hole.) Detect "round complete" →
                  transition to between_rounds.

between_rounds  → Fire R/08_live_leaderboard.R with completed_round,
                  commit, transition back to in_round (or to post_event
                  if round 4 just completed).

post_event      → Fire R/eval_export.R, run retrospective harness, push
                  a "tournament wrap" message via Telegram with
                  headline_metrics output. Transition to off_week.
```

State transitions log to a structured log (`data/logs/earnest.jsonl`) so
post-hoc debugging of "why didn't Earnest fire R/08?" is tractable.

## 7. Push Notification Rules (Heaters & Crashers)

Earnest proactively pushes to Telegram on two symmetric signals:
**heaters** (players blowing past model expectations) and **crashers**
(top-of-leaderboard players falling apart). Rules live in
`config/earnest_push_rules.yaml` so they can be tuned without code
changes.

| Param | Heater | Crasher |
|---|---|---|
| SG percentile gate | **P95** of predicted SG distribution | **P5** of predicted SG distribution |
| Minimum holes played | `thru >= 9` | `thru >= 9` |
| Position gate | (none) | **`current_position <= 30`** — nobody cares about a backmarker dropping further |
| Per-round cap | Top **3** | Top **2** |
| Per-player dedupe | One push per player per round | Same |
| Global cooldown | 90 min between any push (heater or crasher) | Same |
| Scheffler clause | Top-5 pre-round predicted SG → raise to **P98** (only flag *exceptional* days from expected great players) | **Not inverted** — equity weight handles it; a top player crashing is exactly the Merrittocracy angle |
| Equity weight | Rank crossers by `predicted_win_prob × percentile_excess` | Same — a Scheffler P5 day is high-equity newsworthy; a longshot P5 day filters out automatically |

### Alert format

Templated, not LLM-rendered — voice-vetted templates avoid LLM variance
on time-sensitive sends and keep cost trivial across a 24/7 season.
Two-sentence ceiling. Numeric. Model-aware. Voice anchored to SOUL.md
(narrative-flip, visceral data, short sentences land punches).

**Heater example:**
> Spaun is +4.1 SG through 13 — 96th percentile per the model. Pre-round
> win prob was 4%; top-10 was 22%.

**Crasher example:**
> Scheffler is +2.8 SG below expectation through 13 — 3rd percentile day
> per the model. Pre-round win prob was 18%. Stuff happens.

### Earnest does NOT push

- During pretournament idle (no live data)
- For made/missed cut bubble drama (v2 feature)
- For leaders heating up unless they've crossed P98 (the leader is
  already on screen — Earnest only chimes in when it's genuinely
  exceptional)
- For players outside position ≤ 30 on the crasher side
- During or after the 90-min global cooldown window

## 7.1 Shakedown Mode (US Open 2026 only)

The first event runs in **shakedown mode** — every push lands in the
real Telegram chat *with an inline keyboard for labeling*. This is not
a gating layer (alerts still go through); it's a feedback-capture layer
that gives us a real labeled dataset for retuning thresholds before the
next event.

### Mechanism

Each push message ends with three inline keyboard buttons:

```
👍 keeper    👎 noise    🔇 mute player (rest of event)
```

Tapping fires a Telegram `callback_query`. The bot:

- Logs the action to `data/logs/earnest_alert_feedback.jsonl` with shape:
  ```json
  {"ts": "2026-06-19T14:32:11Z",
   "alert_id": "us_open_2026_r1_xander_a3f9",
   "player": "Schauffele, Xander",
   "signal": "heater",
   "percentile": 0.97,
   "equity_score": 0.043,
   "predicted_win_prob": 0.043,
   "thru": 13,
   "action": "keeper"}
  ```
- On `mute`: adds `(event_id, player_id)` to the session mute list. The
  threshold evaluator skips muted players for the rest of the event.
- Acknowledges the tap by editing the original message to append a small
  tag: `(👍 logged)` / `(👎 logged)` / `(🔇 muted)`. No new message — keeps
  the chat clean.

### Alert ID

Short stable hash of `event + round + player_id + ts_bucketed_to_minute`.
Stored on the message via the inline keyboard's `callback_data` field.
Lets the callback handler route feedback back to the right log entry
even if multiple alerts are open at once.

### Post-event review

After the US Open, Steve + Cousin Claude review `earnest_alert_feedback.jsonl`
and retune `config/earnest_push_rules.yaml` against the labels. Look for
patterns like:
- Are P95 heaters consistently `noise`? Raise to P97.
- Are crashers at position 25–30 mostly `noise`? Tighten to ≤ 20.
- Is the Scheffler clause too aggressive? Look at top-5-pred labels.

### Post-shakedown mode

After the first event the shakedown flag flips off in config. **Optional
continuation:** keep the buttons in lower-friction form (just `👎`) so
the calibration loop keeps running across the season at near-zero
friction. The thresholds get sharper over time. This is the more
interesting long-term arc than ever fully "trusting" the rules.

Shakedown flag location: `config/earnest_push_rules.yaml`:
```yaml
shakedown_mode: true          # US Open 2026 only
feedback_log: data/logs/earnest_alert_feedback.jsonl
```

## 8. Architectural Decisions

### 8.1 Code lives in this repo, under `harness/`

The retrospective harness is already here with the right patterns. The
artifacts the live tools read live in `output/`. One repo to keep in
sync — no parallel `golf-harness/` repo.

### 8.2 R runs on the Mini

Earnest is the orchestrator. He fires R scripts via `subprocess` →
`scripts/with-secrets.sh Rscript R/0X_name.R` (the wrapper injects
Keychain-backed env vars before exec'ing R; see §8.6). He owns the
artifact lifecycle: trigger, wait, verify, commit. The Mini is the
canonical artifact location during the season.

For dev work on the laptop, the user pulls. During development of new R
features, the user runs R locally with the existing `op run` pattern;
once stable, Earnest takes over orchestration in production.

### 8.3 Git is the cross-machine sync

Earnest commits artifacts after each R fire. Push to remote. Laptop
pulls when the user wants to inspect. No S3, no rsync.

The committed-CSV noise concern is mitigated by Tier-A scarcity: 5–6
commits per tournament week, not 48.

### 8.4 R↔Python contract: existing artifacts only

Live tools read:
- `output/live_leaderboard_after_r{N}.csv`
- `output/{tournament}_preview_{year}.csv`
- `output/eval/predictions_<tournament>_<year>.parquet`
- DataGolf live endpoint via `requests` for in-flight data

No new R-side exporters. The shapes already serve.

### 8.5 Single agent for v1

Earnest answers human Telegram queries. Cousin Claude Code builds
Earnest's brain. No agent-to-agent path in v1 — it adds protocol/auth/
loop-safety problems without clear payoff. Defer to v2 with a separate
signed-HTTP channel if needed.

### 8.6 Secrets: 1Password on laptop, Keychain on Mini

Earnest must not have access to the full 1Password stack. On the Mini,
all secrets live in the macOS Keychain under service `autopilot`
(the same service the existing autopilot pipeline uses). Two scripts in
`~/autopilot/scripts/` manage this:

- `keychain-sync.sh` — interactive secret manager. Its `SECRETS` array
  is the **master list** of every secret on the Mini; we added
  `GOLF_API_KEY` and `TELEGRAM_CHAT_ID` here.
- `autopilot-env.sh` — launchd wrapper that reads only what *autopilot*
  needs.

Shadow-leaderboard has its own analogous wrapper, `scripts/with-secrets.sh`,
that reads only what *this project* needs (`GOLF_API_KEY`,
`ANTHROPIC_API_KEY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`) from the
same Keychain service. This keeps Earnest's read scope tight while
sharing one secret store across projects.

| Env | Secret store | Invocation pattern |
|---|---|---|
| Laptop (dev) | 1Password CLI | `op run --env-file=.env.template -- Rscript R/...` |
| Mini (prod) | macOS Keychain | `scripts/with-secrets.sh Rscript R/...` |

R scripts themselves are unchanged — they read env vars and don't care
how they got there. The wrapper is the only thing that differs across
environments.

To rotate or add a secret on the Mini:
```bash
~/autopilot/scripts/keychain-sync.sh GOLF_API_KEY <value>
~/autopilot/scripts/keychain-sync.sh --verify
```

## 9. Tool Spec

Add to `harness/tools.py` (alongside existing retrospective tools, all
of which stay reachable from the live loop).

### `get_pretournament_predictions(tournament, year, top_n=20)`
Reads preview CSV. Returns ranked list with `player_name`, `win_prob`,
`top5_prob`, `top10_prob`, `predicted_sg_total`,
`predicted_sg_residual`, `player_skill_prior`, `form_residual_mean_8`.

### `get_shadow_leaderboard(tournament, year, after_round)`
Reads `output/live_leaderboard_after_r{after_round}.csv`. Joins to DG
live for current actual finish position. Returns each player's
predicted-vs-actual rank delta and residual decomposition.

### `get_heating_up(tournament, year, top_n=5)`
Pure Python derivation. Inputs: most recent predictions for the round in
progress + live DG per-player in-round SG (cached 60s). Returns players
above P90 of their predicted SG distribution, gated by `thru >= 9`,
ranked by equity-weighted score (§7). Used both by the conversational
layer (on demand) and by the push evaluator.

### `get_live_field(tournament, year)`
Raw DG `/preds/live-tournament-stats`. 60s in-process cache. For
questions that don't need the model layer.

### `compare_to_baseline(tournament, year, baseline)`
Wraps the retrospective harness. `baseline ∈ {owgr, dg, vegas}`. Guard
against being called mid-tournament; brier vs. completed events only.

### Existing retrospective tools (unchanged)
`list_available_evals`, `get_headline_metrics`, `get_slice_metrics`.
Reachable from the live loop so Earnest can answer "how did we do at
the Memorial?" the same way the retrospective harness does today.

## 10. The Live Agent Loop (`harness/live_harness.py`)

Copy `harness/harness.py` structure exactly. Changes:

- `SYSTEM_PROMPT`: new content, tuned for live conversational use (see
  Earnest's voice in §11 — drafted separately).
- `TOOL_SCHEMAS` / `TOOL_DISPATCH`: union of live + retrospective tools.
- `MAX_TOOL_TURNS`: keep at 15. Most live queries are 2–4 calls.
- `model`: `claude-sonnet-4-6`, same as retrospective.
- Apply `cache_control` to the last tool schema — high cache hit rate
  expected since system + tools are stable across queries.

`run_query(prompt) -> str` is the public function Telegram calls.

### Three surfaces for analytical discussion

The original purpose of `harness/` — providing analytical discussion
behind predictions and results — is preserved and extended across
three surfaces:

| Surface | Trigger | SYSTEM_PROMPT | Output shape |
|---|---|---|---|
| **CLI: `python harness/harness.py "..."`** | Steve manually | Existing diagnostic (probe / chain / multi-paragraph) | Long-form analytical write-up |
| **Telegram conversational** | Steve asks via Telegram | New live prompt | 3–6 sentence Earnest-voiced read |
| **Auto-fire at `post_event`** | Scheduler triggers after tournament ends | Existing diagnostic | Headline summary pushed to Telegram |

The live SYSTEM_PROMPT explicitly directs Earnest to offer the CLI
escape hatch when a Telegram question needs depth Telegram can't carry:
"Want the full breakdown? Run `python harness/harness.py "..."` for the
deep dive."

This division of labor is intentional: light analytical reads live in
the conversational loop; heavy diagnostic sessions live in the CLI.

## 11. Earnest's Voice (handled in SYSTEM_PROMPT, not here)

This brief intentionally does **not** specify Earnest's prose voice. That
belongs in his SYSTEM_PROMPT and should be continuous with how he
already sounds in the newsletter curator. The user will provide the
voice anchor; the SYSTEM_PROMPT will be a separate artifact.

What the SYSTEM_PROMPT must cover:
- Audience is the user (competent golf fan), not DFS players. No
  "lean," "fade," "GPP."
- Reference model probabilities and SG explicitly. Quote numbers.
- 3–6 sentences for conversational replies; 1–2 for push alerts.
- Don't summarize the leaderboard — the user can read positions.
- Statistical humility for small samples (single rounds, n < 20).

## 12. Telegram Bot, Scheduler, Main, Deployment

### `harness/telegram_bot.py`
Long polling. Allowlist on `TELEGRAM_CHAT_ID`. Three update types
handled:

1. **`message`** (text from Steve) — ack ("⛳ thinking..."), route to
   `live_harness.run_query`, send response.
2. **`callback_query`** (button tap from a shakedown alert or a field-set
   confirmation) — parse `callback_data`, dispatch to the appropriate
   handler (`shakedown_feedback.record` / `scheduler.confirm_field_set`),
   edit the original message to acknowledge the tap.
3. **Exceptions** — send `type(e).__name__: str(e)[:200]` so failures
   aren't silent.

Exposes:
- `send_push(text, inline_keyboard=None)` — used by the scheduler for
  push alerts and field-set confirmations.
- `build_shakedown_keyboard(alert_id)` — helper returning the
  `👍 / 👎 / 🔇` inline markup with `callback_data` set to
  `f"shake:{alert_id}:keeper"` etc.
- `build_confirm_keyboard(prompt_id)` — `👍 / 👎` for field-set
  confirmations.

### `harness/scheduler.py`
The state machine (§6). Ticks every 15 min via `schedule`. Reads/writes
state to `data/cache/earnest_state.json`. Exposes one entry point
`tick()` that the main loop drives.

### `harness/main.py`
Two concurrent loops via threads:
- `telegram_bot.poll()` — long polling, blocks on `getUpdates`
- `scheduler.run()` — 15-min ticks of state machine

No webhooks. No external orchestration.

### Deployment
`~/Library/LaunchAgents/earnest.golf.plist` on the Mini. KeepAlive.
Runs `<repo>/scripts/with-secrets.sh /opt/homebrew/bin/python3 harness/main.py`.
Logs to `~/Library/Logs/earnest-golf.{out,err}.log` and structured
events to `data/logs/earnest.jsonl`.

### Env contract

Earnest reads `GOLF_API_KEY`, `ANTHROPIC_API_KEY`, `TELEGRAM_BOT_TOKEN`,
`TELEGRAM_CHAT_ID` from the process environment. `with-secrets.sh`
injects them from the Mini's Keychain (`autopilot` service) before
`exec`. No code in `harness/` ever touches Keychain or 1Password
directly — env vars are the only contract.

Laptop dev path keeps `op run --env-file=.env.template -- python ...`
working for smoke tests; `.env.template` retains the `op://` references
for those two original keys.

## 13. Reuse, Don't Reinvent

- Retrospective tools: reuse via dispatch.
- `R/eval_export.R` parquet contract: no new contract for retrospective data.
- `INSTRUCTIONS.md` Shadow Leaderboard definition: cite, don't redefine.
- Secret loading: `op run` on laptop, Keychain via `scripts/with-secrets.sh`
  on Mini. Don't introduce dotenv. Don't have Python code touch
  Keychain directly — env vars are the contract.
- `harness.py` SYSTEM_PROMPT structure (probe / stop conditions /
  output): port the structure, change the content.
- Existing Telegram outbound: reuse bot token, do not create a second bot.
- Existing `R/08_live_leaderboard.R` completed-round auto-detection: the
  scheduler can call the same detection path before deciding to fire R/08.

## 14. Build Order

1. **Tools (`harness/tools.py`)** — add `get_pretournament_predictions`,
   `get_shadow_leaderboard`, `get_live_field`, `get_heating_up`. Smoke
   test each against the existing US Open 2026 artifacts.
2. **`harness/live_harness.py`** — copy retrospective harness, swap
   SYSTEM_PROMPT, union the tool dispatch. Smoke test with
   `python harness/live_harness.py "Who's the model on for the US Open 2026?"`
3. **`harness/scheduler.py`** — state machine, R subprocess fires,
   `data/cache/earnest_state.json`. Test state transitions with a dry-run
   mode that logs instead of firing R.
4. **`harness/telegram_bot.py`** — long poll, allowlist, ack + reply,
   `send_push`.
5. **`harness/main.py`** — thread the two loops together.
6. **Push rule config** — `config/earnest_push_rules.yaml` with §7
   defaults.
7. **launchd plist** on the Mini, smoke test full season idle state.
8. **First real-event dress rehearsal** at the US Open.

## 15. 2027 Season Investments (Explicitly Out of Scope for v1)

These come up naturally but should not bloat v1:

- **Intra-round model refresh** (`R/08b_intraround.R`) — re-runs brms
  with partial-round SG as features, gives updated win/top10 probs
  mid-round. Real modeling work (partial-round weighting, course-position
  adjustment). Would unlock probability-jump push triggers instead of
  percentile-only.
- **Push for cut-line drama** — bubble players on Friday afternoon.
- **Agent-to-agent path** — Cousin Claude Code on the laptop tasking
  Earnest on the Mini over a signed-HTTP channel.
- **Proactive content drafts** — Earnest writes a Substack draft after
  the event ends and routes to the autopilot human-approval flow.
- **Multi-event awareness** — DP World Tour events running in parallel,
  Korn Ferry, LIV.

## 16. Open Questions — Status

All design questions resolved as of 2026-06-06. Remaining work is
one-time operational setup on the Mini:

- [ ] **Keychain population (Mini, one-time)** — after pulling the
      updated `~/autopilot/scripts/keychain-sync.sh`:
      ```bash
      ~/autopilot/scripts/keychain-sync.sh GOLF_API_KEY <value>
      ~/autopilot/scripts/keychain-sync.sh TELEGRAM_CHAT_ID <value>
      ~/autopilot/scripts/keychain-sync.sh --verify
      ```

### Resolutions log

- [x] R script docstrings — leave `op run` lines for laptop dev; Mini
      invocation lives in `scripts/with-secrets.sh`.
- [x] Voice anchor — SOUL.md from autopilot is the canonical anchor;
      live SYSTEM_PROMPT in `docs/earnest_live_system_prompt.md`.
- [x] Mini repo path — `~/shadow-leaderboard`.
- [x] Active event config — auto-detected from DG schedule with
      Telegram-button confirmation per event (see §6 `field_pending`).
- [x] DataGolf live endpoint — mirror `R/datagolf_api.R` contract in
      Python.
- [x] Live loop model — `claude-sonnet-4-6`. Retrospective stays on
      Sonnet too; upgrade to Opus 4.7 only if wrap-ups need more nuance.
- [x] Push defaults — P95 heater / P5 crasher across the board with
      shakedown labeling (§7.1).
- [x] State-machine cadence — 30 min in-round, daily 7am off-week.
- [x] Git push frequency — auto-push after every artifact commit.
- [x] Shakedown mode — labeled-alert mode for US Open 2026 only (§7.1).
