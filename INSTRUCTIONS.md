# Shadow Leaderboard — Project Instructions

## What This Is
A live-ish (end-of-round) golf prediction model under the Merrittocracy brand.
Sister project to `nfl-draft-model`. The model produces a "Shadow Leaderboard"
— players re-sorted by underlying SG performance instead of their actual score
— plus residual decomposition (sticky vs. lucky) and updated win probabilities.

The model is the engine. The takes Merrittocracy publishes from it are the
product. Launch event: **2026 US Open at Shinnecock Hills (June 18–21, 2026)**.
Long-term: extends to other majors and high-profile tour stops.

## Background
- Director-level data scientist with deep R expertise (tidymodels, Shiny, dplyr)
- Strong NFL domain knowledge; competent golf fan, less expert than NFL
- Former Navy H-60 pilot (separate from the brand but informs the spatial-
  disorientation metaphor that runs through Merrittocracy content)
- Primary AI tools: Claude Code ("Cousin Claude Code"), OpenClaw on Mac Mini M4
- DataGolf top-tier subscriber — gates the API we depend on
- Day job: Florida Blue (health insurance) — keep completely separate

## Brand Stack
| Platform    | Handle / Name                     | URL                                                  |
|-------------|-----------------------------------|------------------------------------------------------|
| X (Twitter) | @Merrittocratic                   | x.com/Merrittocratic                                 |
| Email       | themerrittocratic@gmail.com       |                                                      |
| Substack    | @themerrittocracy / Merrittocracy | themerrittocracy.substack.com                        |
| Domain      | merrittocracy.org                 | merrittocracy.org                                    |
| GitHub Org  | merrittocratic                    | github.com/merrittocratic                            |
| GitHub Repo | shadow-leaderboard                | github.com/merrittocratic/shadow-leaderboard         |

---

## Target Audience
Same two-layer audience as the NFL Draft model — analytics community + sports
fans — with one important sub-segment to **explicitly NOT chase**:

**We are not building for DFS / betting players.** They already use DataGolf
directly. They have no need for a thin layer on top. Trying to serve them puts
us in DataGolf's lane and we lose. We are building for golf fans who watch the
broadcast and want smarter analysis than the announcers provide.

---

## Tech Stack
- **Modeling:** R + tidymodels with four engines for empirical comparison
  (see Architecture below). Tier 2 / post-launch: TabPFN, stacked ensemble.
- **Data:** DataGolf API (top tier, gated). Env var: `GOLF_API_KEY`.
- **Reporting:** Quarto HTML report (master document) + ggplot2 / gt PNG
  outputs to `/graphics/` for reuse in Substack and X
- **Secrets:** 1Password 8 CLI with `op run` injection (mirror NFL pattern;
  DataGolf API key as an API Credential item, surfaced as `GOLF_API_KEY`)
- **Code hosting:** github.com/merrittocratic/shadow-leaderboard (public)
- **Distribution:** Same Substack (themerrittocracy.substack.com) and X
  (@Merrittocratic) channels as the rest of Merrittocracy

---

## The Model

### Outcome Variable
- **Target:** per-round SG residual = `actual_sg_total - expected_sg_total`,
  where `expected` is conditional on player skill × conditions (joint baseline)
- **Decomposition:** the residual is decomposed by SG category at scoring time:
  putting residual (regresses, "fades") vs. ball-striking residual (sticks)
- **Output for content:** per-player tag — sticky / fade / mixed — drives
  the sustainability calls in the post-round report

### Why Residual-vs-Expected
Direct mirror of the NFL Draft model's residual-on-AV approach. Same boom/bust
DNA in a different sport. Golf is uniquely well-suited because SG already gives
us a clean baseline that football doesn't have. The leaderboard tells you what
just happened; the model tells you whether to believe it.

### Sub-Models
**Single model.** Golf is a single "position." Sub-models per round-type
(majors vs. regular events) or course-class were considered and rejected for
MVP — feature-level handling is sufficient. Revisit only if validation shows
clear regime differences.

### Architecture: Four-Engine Empirical Comparison
**No a-priori favorite.** We fit and tune all four Tier 1 candidates against
the same training set and held-out validation events, then pick the winner
empirically. The methodology comparison itself is publishable content — the
brand-intro Substack post for golf coverage is "four models, four answers,
here's which one we trust and why."

#### Tier 1 — Production Candidates (all R-native)

1. **XGBoost** — `xgboost` + `tune_race_anova()`, 50-point grid. Tree-based
   gradient boosting baseline. Comfortable, well-understood, fast to iterate.
   Mirrors the NFL Draft model architecture for direct comparison.
2. **LightGBM** — via `bonsai` parsnip wrapper. Faster training than XGBoost
   on data of this shape; leaf-wise growth strategy. Tunable through the same
   tidymodels infrastructure as XGBoost.
3. **Hierarchical Bayesian** via `brms` / Stan. Golf-native methodology
   mirroring DataGolf's published approach (Bayesian updating with regression-
   to-mean) and the academic literature (Broadie, Drappi & Co Ting Keh 2019,
   the 2025 empirical-Bayes-of-PGA-skill paper). Two-level Gaussian
   hierarchical structure: per-player-season latent skill nested under
   population-level priors, with course-class as an additional hierarchical
   group. **Produces uncertainty intervals natively** — fits Merrittocracy's
   "always show the range, never a point estimate" content rule without
   separate calibration work.
4. **Mixed-effects** via `lme4`. Frequentist analog of #3. Much faster to fit
   (hours rather than days). Serves as the partial-pooling baseline that the
   Bayesian model has to justify its computational cost against.

#### Tier 2 — Post-Launch / Phase 2

5. **TabPFN** — zero-shot foundation model for tabular data. Carried over from
   the NFL spec; interesting comparison point but not load-bearing for MVP.
6. **Stacked ensemble** via the `stacks` package — combine the four Tier 1
   base learners with a meta-learner. Becomes more compelling with the
   diverse base models we're committing to.

#### Dropped from Original Spec
- **TabNet** — was in the NFL stack to handle small-sample sub-models with
  attention-based interpretability. Golf doesn't have the small-sample
  problem, and TabNet rarely wins on this kind of structured tabular data.
- **Single-engine XGBoost commitment** — replaced by the comparison framework.

#### Decision Criteria for Picking the Winner
1. **Out-of-sample residual MSE on held-out events** (primary) — 2025 US
   Open at Oakmont and 2026 Masters as held-out tournaments
2. **Calibration of uncertainty intervals** (secondary) — Bayesian and
   stacked candidates have a natural advantage here; check coverage of
   prediction intervals against held-out outcomes
3. **Interpretability for content generation** (tertiary) — can the model
   support per-player residual decomposition and sustainability tagging?

### Venue Handling
Course-class taxonomy + within-class empirical Bayes shrinkage. Manual
classification of every venue in the 2010+ training set is a required
one-time setup task. Class examples: US Open links-rough setups, traditional
parkland, modern long-yardage, modular Florida-style. Within each class,
shrinkage proportional to within-venue sample size. The hierarchical Bayesian
candidate handles this structure most naturally; the GBDT candidates encode
it as features.

### Features
- **Player skill priors:** DataGolf SG total + by category (OTT / APP / ARG / PUTT)
- **Conditions:** wind, AM/PM wave assignment (DataGolf where available; open
  weather API as supplement)
- **Course:** course-class indicator + within-class course-fit with shrinkage
- **Situational:** cut-line proximity (R2-specific), leader-board pressure
  spread (R4-specific)
- **Recent form:** three-layer hot-streak / regime-change detection (see
  Form Features subsection below; N tuned per feature via CV)

### Form Features: Hot-Streak / Regime-Change Detection
Built on top of DataGolf's exponential-decay player prior to capture what
it misses: genuine regime change. DataGolf's decay handles ordinary recency
weighting upstream; these features target the gap.

**Feature (a) — Recent-Form Residual:** per player, mean of
(actual SG − player skill prior) over their last N events. Captures
systematic underestimation by the long-horizon prior.

**Feature (b) — Form Trend Slope:** per player, simple linear-trend
slope of those same residuals over the last N events. Distinguishes
"hot right now" from "stepped up to a new level."

**Feature (c) — Structural Break / Regime Change:** modeled natively in
brms via random effects on player-season-segment. NOT a design-matrix
column. GBDT candidates get (a) and (b) only; lme4 gets a simplified
version via random slopes on player-season; brms gets the full
hierarchical treatment. This asymmetric advantage for brms is intentional
— it is the single biggest reason brms justifies its compute cost.

**Lookback window N:** tunable hyperparameter, swept independently for
(a) and (b). Candidate values: 4, 8, 12, 16 events. N for the level and
N for the slope are not assumed equal.

**Event definition:** every PGA Tour start = 1 event regardless of
strength-of-field. Missed cuts count (SG through 36 holes included).

**Point-in-time correctness:** form features use only data available
pre-event. A unit test in `tests/test_form_features.R` enforces this on
every computation run — no exceptions.

**Caching:** features are cached per N value in `data/cache/form/` so
the N sweep does not recompute across CV folds.

### Known Constraint: Course-Fit Signal Is Weak
DataGolf's own published guidance: their work shows course fit "does not have
much predictive power." We proceed with course-class + shrinkage anyway because:
1. The signal may be stronger for the brutal-rough US Open class than for
   general PGA stops (untested, worth checking)
2. We need a feature engineered with proper methodology to evaluate, not
   dismiss on prior
3. **If results confirm DataGolf's claim, that is itself a Shadow Leaderboard
   piece** — "broadcast loves course-horse stories, even DataGolf says it
   doesn't matter, here's the data"

### Training Data
- PGA Tour rounds 2010–2025 via DataGolf historical raw data endpoint
- Estimated ~50K+ player-rounds (4 majors + 40+ regular events × 16 years × 156
  field × 4 rounds, with cuts)
- Modern equipment baseline (post-2010 distance era)
- Pre-2010 data exists back to 2004 for PGA Tour but reflects a meaningfully
  different game; explicitly excluded

---

## Strategic Decisions Log

### DataGolf API as Backbone (vs. Hybrid or Build-Your-Own)
Chosen over hybrid. Trade-off acknowledged: input-side differentiation is
limited because we use the same data DataGolf publishes. The residual DV and
content layer have to do the work. Hybrid was the recommendation; this choice
prioritizes time-to-MVP over moat depth. Revisit if MVP succeeds and we want
deeper differentiation.

### Four-Engine Comparison, No A-Priori Favorite
Original spec had XGBoost as the headline engine (mirror of NFL Draft model
architecture). Pushed back on the basis that golf's training population
(~50K player-rounds vs. NFL Draft's ~3,750 players) supports a wider
algorithmic playing field, and the academic golf-prediction literature is
dominated by hierarchical Bayesian approaches (Broadie, DataGolf published
methodology, Drappi & Co Ting Keh 2019, the 2025 empirical-Bayes paper on
PGA Tour skill). Decision: fit all four Tier 1 candidates (XGBoost, LightGBM,
hierarchical Bayesian via brms, mixed-effects via lme4), pick winner
empirically on held-out validation events. Computational cost (especially for
brms HMC sampling on 50K rows) is the trade-off; the methodology comparison
itself becomes the brand-intro Substack content for golf coverage, which
justifies the work.

### End-of-Round Refresh (Not Live, Not Event-Driven)
Model runs 5 times per tournament: pre-tournament + after each round. No
streaming, no event-driven alerting, no in-memory state. This was a deliberate
runway-vs-payoff trade. Brand value lives in the takes, not in the milliseconds.
DataGolf's live model is hole-level (not shot-by-shot — that's ShotLink, off
the table for indie projects), so the realistic refresh ceiling was hole-level
anyway. End-of-round is dramatically simpler and loses little.

### Manual Content Trigger (Not Automated)
Model produces dashboards; Merrittocracy reads them and writes takes. No
automated content generation pipeline for this model. The Telegram approval
loop and autopilot architecture from the NFL/OpenClaw side are explicitly
out of scope here.

### Quarto + PNG Output (Not Shiny, Not Static MD Alone)
Single Quarto render produces both: (1) the HTML dashboard the writer scans
post-round, and (2) PNG assets to `/graphics/` for X and Substack reuse.
Mirrors the NFL `/scripts/ → /graphics/` workflow with a Quarto wrapper
providing the dashboard layer. Scratches the "integrate Quarto" item on the
NFL roadmap by giving it a smaller, cleaner project to debut on.

### 2010+ Training Window
Modern equipment baseline. Distance era began ~2010. DataGolf has PGA Tour
data back to 2004 but pre-2010 reflects a meaningfully different game.

### Joint Expected Baseline (Player × Conditions)
Most demanding option of the three considered (field-only, player-only, joint).
Required to make the residual mean what we want it to mean. Implementation
naturally falls out of any of the four Tier 1 candidates with player-skill and
condition features — no separate baseline model needed.

### Form Features: Three-Layer Hot-Streak / Regime-Change Detection
DataGolf's exponential-decay player prior handles ordinary recency
weighting. What it does not catch fast enough is genuine regime change —
a player whose underlying skill has structurally stepped up (Cam Young
2026 as the motivating example). Decision: build three form features on
top of the DataGolf prior rather than replacing it.

**Double-counting risk acknowledged.** The DataGolf prior already
incorporates recency weighting. These features are explicitly additive
corrections on top of that prior. If the prior were perfect at detecting
regime change, these features would show zero weight in validation and
get dropped. That is the test.

**Asymmetric brms advantage is intentional.** The structural-break
modeling via player-season-segment random effects is the strongest single
justification for brms's computational cost. If brms wins in Week 4
validation, the form-feature architecture is part of why. The GBDT
candidates get features (a) and (b); they do not get (c).

**N is tunable and swept independently per feature.** No reason the
optimal lookback for the residual level equals the optimal lookback for
the slope. Candidate values: 4, 8, 12, 16 events; CV picks per feature.

### Manual Substack Publishing (No API Automation in MVP)
Substack has no official publishing API. Unofficial APIs exist (session-cookie
based, undocumented internal endpoints) and could push drafts programmatically
later, but they're fragile and the manual editorial control is part of the
brand's quality bar. Filed as future option, not MVP scope.

---

## Content Strategy

### Voice & Persona
See `CONTENT_GUIDE.md` for full voice rules and golf-specific deltas. Core
identity is unchanged: the narrative-checker. "Here's what the broadcast is
saying — now let's look at what the data actually shows." Conversational and
confident. Contrarian takes are earned by the data, not manufactured for
engagement.

### Content Autonomy Levels
- **Shadow Leaderboard table generation:** autonomous (template-driven from
  model output)
- **Sustainability tags per player:** autonomous (derived directly from model
  decomposition)
- **X post drafts:** Claude drafts, Merrittocracy heavily edits for voice
- **Substack post drafts:** Claude generates full first drafts, Merrittocracy
  edits

### Uncertainty in Predictions
Same rule as the NFL model: always show the range, never a point estimate.
"Our model gives him a 35–55% chance to make the weekend" — not "he has a 45%
cut probability." Particularly important in golf where round-to-round variance
is enormous and false precision is the genre disease of golf analytics.
**The Bayesian Tier 1 candidate produces these intervals natively, which is
part of why it's in the comparison rather than just being a methodology curio.**

### Content Roadmap (7 Weeks to US Open)
Adjusted from the original plan to absorb the cost of running four model
candidates rather than one. The methodology comparison gets repurposed as
Week 5 brand-intro content rather than just being internal R&D.

- **Week 1 (now, late April):** Repo setup, DataGolf API integration, secrets
  wiring, training data pull, course-class taxonomy initial draft
- **Week 2:** All four model skeletons stood up (XGBoost, LightGBM, brms,
  lme4) — first runs with default hyperparameters, sanity check residual
  distributions, identify any data-quality issues
- **Week 3:** Tuning and iteration. XGBoost and LightGBM in parallel via
  tidymodels (fast). brms prior specification and posterior predictive
  checks (slow — long pole on the timeline). lme4 sensitivity analysis.
- **Week 4:** Full validation against 2025 US Open (Oakmont) and 2026 Masters
  as held-out events. Empirical comparison on the three decision criteria.
  Winner selected. Quarto dashboard template build begins.
- **Week 5:** Substack methodology post — **the four-model comparison itself**
  as the brand intro for golf coverage. Cross-post threaded version on X.
  Quarto dashboard finalization.
- **Week 6:** Pre-tournament Shinnecock analysis using winning model — field
  assessment, expected scoring conditions, course-class priors. Scheffler
  iron-play piece (already drafted from the project conversation).
- **Week 7 (Tournament week, June 18–21):** Live coverage — round-by-round
  Shadow Leaderboards, sustainability calls, post-round takes on Substack
  and X.

---

## Automation Architecture
End-of-round refresh, manual content trigger. No streaming, no Telegram loop
for this model. The OpenClaw infrastructure that supports the NFL pipeline is
not in scope here.

Out-of-scope for MVP, parked for later consideration:
- Programmatic Substack draft creation via unofficial API
- Auto-rendering Quarto on a schedule trigger
- Cross-posting to X via API

---

## Working with Claude

### Preferences
- Concise, direct responses — no fluff
- R for everything (modeling, data wrangling, reporting). Python only if
  unavoidable
- Claude Code handles boilerplate; Merrittocracy handles domain judgment
- Public GitHub repo for credibility with analytics community

### Ask vs. Assume
- **Architecture decisions** (model changes, feature additions, pipeline
  design): Ask first, pause for input
- **Implementation details** (column names, package versions, code style):
  Make reasonable assumptions, note them, keep moving

### Disagreements With Documented Decisions
If you believe a locked-in decision should be revisited:
1. Flag the specific concern
2. Explain what evidence or circumstance changed
3. Pause for input — do not proceed with an alternative approach

### What Merrittocracy Handles
- Domain judgment (which narratives to challenge, which players to feature)
- Content voice and final editing
- Strategic decisions about brand direction
- Course-class taxonomy initial classifications (golf domain knowledge call)

### What Claude Handles
- Code implementation and debugging
- DataGolf API wrapper and caching layer
- Model training, tuning, validation across all four Tier 1 candidates
- Quarto template and dashboard layout
- Content draft generation (reviewed before publishing)
- Player tag and table output generation (autonomous)

### Do NOT
- Suggest live in-tournament refresh — explicitly out of scope
- Build a Substack publishing automation layer in MVP scope
- Compete with DataGolf on prediction accuracy — that is not the brand position
- Add features without considering whether DataGolf already provides them
- Build duplicate scrapers for data DataGolf serves via API
- Suggest moving the modeling stack from R to Python
- Lock in venue-class taxonomies without Merrittocracy's domain review
- Silently change a documented decision — flag and pause instead
- **Default to XGBoost as the winner before validation runs.** The four-engine
  comparison is meaningful only if we let the data decide. Cousin Claude Code
  should treat all four candidates as equal first-class citizens through Week 4.

### File Naming
Drafts in `content/drafts/` use descriptive names without dates (mirror NFL
convention). The git hook adds the following Sunday's date prefix when copying
to the published folder. Date-prefixed `.md` files signal published, final-
edited content and serve as voice calibration references.
