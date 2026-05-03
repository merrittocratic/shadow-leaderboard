# Shadow Leaderboard

End-of-round golf prediction model under the [Merrittocracy](https://themerrittocracy.substack.com) brand.
The model re-sorts players by underlying strokes-gained performance, decomposes residuals into sticky vs. lucky components, and produces updated win probabilities — a *Shadow Leaderboard* behind the official one.

Launch event: **2026 US Open at Shinnecock Hills (June 18–21, 2026).**

Built with R + tidymodels. Sister project to [nfl-draft-model](https://github.com/merrittocratic/nfl-draft-model).

---

## What It Does

**Pre-tournament:** field assessment, expected scoring conditions, course-class priors, win probability distribution.

**After each round:** Shadow Leaderboard (players re-ranked by SG residual), per-player sustainability tags (sticky / fade / mixed), updated win probabilities with uncertainty intervals.

**Architecture:** four-engine empirical comparison — XGBoost, LightGBM, hierarchical Bayesian (brms), and mixed-effects (lme4). Winner selected after validation against held-out events (2025 US Open at Oakmont, 2026 Masters). No a-priori favorite.

---

## Folder Structure

```
R/
  00_config.R              # packages, constants, DataGolf base URL
  datagolf_api.R           # API wrapper with on-disk cache
  01_pull_historical.R     # PGA Tour rounds 2010–2025 (resumable)
config/
  course_taxonomy.csv      # venue list — course_class filled in manually
data/                      # gitignored — intermediate .rds files
  cache/                   # gitignored — raw JSON from DataGolf API
output/                    # gitignored — model results, CSVs
graphics/                  # gitignored — PNG/SVG assets for Substack and X
content/
  drafts/                  # gitignored — unpublished prose
  published/               # tracked — date-prefixed .md files (voice reference)
```

---

## Setup

### Prerequisites

- R ≥ 4.3
- [1Password CLI](https://developer.1password.com/docs/cli/get-started/) (`op`) installed and signed in
- 1Password item: **DataGolf API Key** in the **Merrittocracy Agent** vault
  - Item type: API Credential
  - `username`: `GOLF_API_KEY`
  - `credential`: your DataGolf API key

### 1Password item setup (one-time)

```bash
# Verify the item exists and the reference resolves
op item get "DataGolf API Key" --vault "Merrittocracy Agent"
```

### Running scripts

All scripts that call the DataGolf API must be run via `op run` so the key is injected as `GOLF_API_KEY`:

```bash
op run --env-file=.env.template -- Rscript R/01_pull_historical.R
```

The `.env.template` file contains the 1Password secret reference — it is safe to commit. The resolved key is never written to disk.

### Install R packages

```r
install.packages(c(
  "tidyverse", "tidymodels", "httr2", "jsonlite",
  "xgboost", "bonsai", "brms", "lme4",
  "finetune", "probably", "stacks",
  "quarto", "gt", "ggplot2",
  "glue", "scales", "cli"
))
```

---

## Pipeline (run in order)

```bash
# Pull all historical training data (2010–2025, resumable)
op run --env-file=.env.template -- Rscript R/01_pull_historical.R
```

More pipeline steps added as the project progresses.

---

## Content

Analysis and deep dives: [Merrittocracy on Substack](https://themerrittocracy.substack.com)
Quick takes and data viz: [X @Merrittocratic](https://x.com/Merrittocratic)

## License

MIT
