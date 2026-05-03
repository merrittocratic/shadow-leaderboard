# Shadow Leaderboard — Content Guide (Golf Delta)

This is a delta to the Merrittocracy core `CONTENT_GUIDE.md`. The core voice
rules apply here unchanged — narrative-checker identity, conversational tone,
ranges-not-points on uncertainty, "our model" voice, no betting-advice
framing. Read that document first. This document covers what's different
about golf coverage.

---

## What's the Same

- Voice and persona: the smart friend at the bar with the regression model
- Lead with the narrative being challenged, not the methodology
- Always show probability ranges, never point estimates
- "Our model" — first person plural, brand voice
- Methodology footers link to the GitHub repo for analytics readers
- Published articles in `content/drafts/` (later `content/published/golf/`)
  are the canonical voice reference, not this guide

## What's Different

### The Audience Already Knows SG
Golf fans who are reading us either know strokes-gained or are willing to
learn it on the way through. Don't condescend. Define new acronyms
(SG-OTT, SG-APP, SG-ARG, SG-PUTT) on first use in any single piece, then
use freely. Use plain English ("strokes gained off the tee") in titles and
hooks; abbreviations in body and tables.

### The Push-Back Targets Are Different
NFL Draft content pushes back on draft-media consensus — mock drafters,
analyst boards. Golf content pushes back on **broadcast narratives**: what
the booth is saying, in real time, during the round. The format is more
"Feherty just said X, here's why the data disagrees" than "the consensus
mock has X at pick 5, here's why we differ."

### The Update Cadence Is Tournament-Bound
NFL Draft content built up over weeks toward a single event. Golf content
clusters around the four days of a tournament — pre-tournament setup,
post-Round 1, post-Round 2 (cut-line analysis), post-Round 3, post-Round 4
(grades and post-mortem). Then quiet until the next event we cover.

---

## Broadcaster-Narrative Tropes (Primary Targets)

These are the recurring broadcast-booth narratives we should be ready to
narrative-check whenever the data warrants:

- **"Course horse"** — usually overstated. DataGolf's own work says course
  fit is weak signal. We have a feature for it; it usually doesn't move the
  needle much. The trope generates content either way: confirm it for the
  rare genuine fit (Mickelson at Augusta) or challenge it for the lazy
  versions (X has played here twice, finished T15 both times, must be a
  course horse).
- **"Hot putter"** — the most regression-prone signal in our model.
  Putting residuals fade. When the broadcast tells you someone's putting
  has unlocked their game, the model usually disagrees about tomorrow.
- **"He's playing well coming in"** — recent form has signal but less than
  the broadcast implies. Quantify: how much do the last 4 events actually
  shift our prior?
- **"Experience matters at majors"** — selectively true. Depends on player
  archetype and situation. A model with player skill priors and situational
  features can decompose this rather than nodding along.
- **"Sunday pressure"** — leader-board-pressure spread is a real feature.
  It's also quantifiable. "Pressure" without numbers is vibes.
- **"He's got the game for this course"** — usually a vibes call dressed
  as analysis. Specific to which conditions? Driving distance? Approach
  proximity? Putting on bent? Force the specifics.

These are not rules to mechanically follow. They are the recurring shapes
of broadcast narrative that are worth being ready to test against the data.

---

## The Shadow Leaderboard Format

This is the recurring content franchise. It runs after every round of every
event we cover. Visual format and narrative structure should be consistent
across rounds and tournaments so it builds recognition.

### Visual Specs
- `gt` table or `ggplot`, brand colors
- Top 20 by underlying SG (the "shadow" rank)
- Columns: shadow rank | player | actual score | score-vs-expected residual |
  sticky/fade tag | one-line "stick or fade" call
- Image exported as PNG to `/graphics/` for X embed and Substack image upload

### Narrative Wrap (per round, ~700–1,200 words for Substack)
1. **Headline finding** — one sentence: who's overperforming the leaderboard,
   who's underperforming
2. **Sustainability calls** — 3–4 player callouts with SG decomposition.
   "Player X shot 65; SG-PUTT residual was +3.8; expect tomorrow back near 70."
3. **One narrative-check** — broadcast said X, model says Y. Just one. Saving
   them up.
4. **Tomorrow's setup** — who's positioned for what, with WP ranges
5. **Methodology footer** — link to GitHub

### X Post Templates
- **Shadow Leaderboard image** + 1-line headline + thread teaser → Substack
- **Sustainability call** — "Player X went 65 today. Putting residual: +3.8.
  Don't expect tomorrow to look like today." [SG bars image]
- **Narrative-check** — "Booth all day on [Player]'s collapse. Model says his
  ball-striking was identical to round 1. Bad luck on putts and a couple
  unlucky lies. Watch tomorrow."

---

## Vocabulary

- **"Shadow Leaderboard"** — branded term, capitalized when referring to the
  franchise. Lowercase when generic ("the shadow leaderboard for round 2
  shows...").
- **"Sticky"** / **"fade"** — sustainability tags. Sticky = ball-striking
  residual (sticks). Fade = putting residual (regresses). Use them
  consistently.
- **"Residual"** — preferred over "luck" or "fortune" in headers and tables.
  "Lucky/unlucky" fine in narrative voice but don't lean on it.
- **"Setup-aware"** — for US Open and major contexts. Signals we're modeling
  course conditions, not just the course as a static venue.
- **"Joint expected"** — internal model term for the DV baseline.
  **Don't surface to readers.** Talk about "what the model expected given
  who's playing and what conditions look like" instead.
- **"Course-class"** — internal taxonomy term. Mention to analytics readers
  in methodology posts; in fan-facing content say "US Open setups" or
  "links-style brutal-rough courses."

---

## What Claude NEVER Generates as Golf Content

- **Anything resembling betting picks, value bets, or odds analysis.** That's
  DataGolf's lane. Also legal/ethical concerns. We don't go there.
- **Specific score predictions** ("he'll shoot 68"). Probability ranges on
  outcomes (cut, top-10, top-5, win) are fine. Point predictions on individual
  rounds are not.
- **Player character claims** — work ethic, mental game, "wants it more,"
  "doesn't have the killer instinct." The model sees SG and conditions, not
  people.
- **Course history breathlessly cited as predictive** — DataGolf's own research
  says course fit is a weak signal. Our content reflects that. We can cite
  course history; we shouldn't lean on it as a primary driver.
- **Hot takes about specific players' losses or chokes.** Sunday meltdowns are
  not the brand. The Shadow Leaderboard might quietly note that the leader
  was sticky and the chasers were lucky, which is a much more interesting
  framing than "X choked."
- **Comparisons to historical greats without explicit data backing.** "He
  reminds me of Tiger" is exactly the kind of vibes-analysis we're
  positioning against.

---

## Substack Post Types (Golf)

1. **Pre-tournament preview** — field assessment, expected scoring
   conditions, course-class priors, top contenders with WP ranges
2. **Post-round Shadow Leaderboard** — the recurring franchise (one per
   round, four per tournament for events we cover end-to-end)
3. **Post-tournament wrap** — what the model got right, what it missed,
   what the residuals tell us about the eventual winner
4. **Methodology posts** — model build, course-class taxonomy walkthrough,
   validation results (audience: analytics community)
5. **Cross-event narrative-check** — when a broadcast trope shows up in
   multiple events, a standalone piece tracking it across tournaments
   (e.g., "How often is the 'hot putter' actually predictive?")

Target lengths follow the core guide: 700–1,200 for weekday/post-round
pieces, 1,400+ saved for weekend/wrap-up reads.
