import os
import time
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
import requests
from scipy.stats import spearmanr
from scipy.stats import norm

from loader import list_eval_tables, load_eval_table

# ---------------------------------------------------------------------------
# Live artifact paths
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = REPO_ROOT / "output"
EVAL_DIR   = OUTPUT_DIR / "eval"

DG_BASE_URL = "https://feeds.datagolf.com"

# 60-second in-process cache for DataGolf live endpoint
_live_cache: dict[str, tuple[float, Any]] = {}
LIVE_CACHE_TTL = 60  # seconds


def _dg_api_key() -> str:
    key = os.environ.get("GOLF_API_KEY", "")
    if not key:
        raise RuntimeError("GOLF_API_KEY not set — run via scripts/with-secrets.sh")
    return key


def _read_artifact(stem: str) -> pd.DataFrame:
    """Read a model artifact: prefer CSV (live run), fall back to RDS (git-committed)."""
    csv_path = OUTPUT_DIR / f"{stem}.csv"
    rds_path = OUTPUT_DIR / f"{stem}.rds"
    if csv_path.exists():
        return pd.read_csv(csv_path)
    if rds_path.exists():
        import pyreadr
        result = pyreadr.read_r(str(rds_path))
        return list(result.values())[0]
    raise FileNotFoundError(
        f"No artifact found for '{stem}' (checked {csv_path} and {rds_path})"
    )


def _read_preview(tournament: str, year: int) -> pd.DataFrame:
    """Read pre-tournament predictions; check several candidate paths."""
    # 1. output/{tournament}_preview_{year}.csv  (07_pga_preview output, gitignored)
    csv_path = OUTPUT_DIR / f"{tournament}_preview_{year}.csv"
    if csv_path.exists():
        return pd.read_csv(csv_path)
    # 2. output/eval/predictions_{tournament}_{year}_preview.rds  (eval snapshot)
    rds_path = EVAL_DIR / f"predictions_{tournament}_{year}_preview.rds"
    if rds_path.exists():
        import pyreadr
        result = pyreadr.read_r(str(rds_path))
        return list(result.values())[0]
    # 3. Any parquet in eval dir matching pattern
    pq_path = EVAL_DIR / f"predictions_{tournament}_{year}_preview.parquet"
    if pq_path.exists():
        return pd.read_parquet(pq_path)
    raise FileNotFoundError(
        f"No preview artifact found for tournament='{tournament}', year={year}. "
        f"Run R/07_pga_preview.R first."
    )


def _dg_live_request(endpoint: str, params: dict) -> Any:
    """Hit DataGolf API with 60s in-process caching."""
    cache_key = endpoint + str(sorted(params.items()))
    now = time.monotonic()
    if cache_key in _live_cache:
        ts, data = _live_cache[cache_key]
        if now - ts < LIVE_CACHE_TTL:
            return data
    params = {"key": _dg_api_key(), **params}
    resp = requests.get(f"{DG_BASE_URL}/{endpoint}", params=params, timeout=15)
    resp.raise_for_status()
    data = resp.json()
    _live_cache[cache_key] = (now, data)
    return data


def _round_or_none(x: float | None, n: int = 4) -> float | None:
    if x is None or (isinstance(x, float) and np.isnan(x)):
        return None
    return round(x, n)

PROB_TO_ACTUAL = {
    "pred_win_prob":   "actual_won",
    "pred_top10_prob": "actual_top10",
}


def _brier(pred: pd.Series, actual: pd.Series) -> float:
    mask = pred.notna() & actual.notna()
    if mask.sum() == 0:
        return float("nan")
    return float(((pred[mask] - actual[mask].astype(float)) ** 2).mean())


def _spearman(a: pd.Series, b: pd.Series) -> float:
    mask = a.notna() & b.notna()
    if mask.sum() < 3:
        return float("nan")
    rho, _ = spearmanr(a[mask], b[mask])
    return float(rho)


def _round_or_none(x: float, n: int = 4) -> float | None:
    if x is None or (isinstance(x, float) and np.isnan(x)):
        return None
    return round(x, n)


def _model_metrics(df: pd.DataFrame) -> dict:
    return {
        "brier_win":      _round_or_none(_brier(df["pred_win_prob"],   df["actual_won"])),
        "brier_top10":    _round_or_none(_brier(df["pred_top10_prob"], df["actual_top10"])),
        "spearman_score": _round_or_none(_spearman(df["pred_score"],   df["actual_score"]), n=3),
    }


# ---- tools ----

def list_available_evals() -> list[dict]:
    return list_eval_tables()


def get_headline_metrics(tournament: str, year: int) -> dict:
    df = load_eval_table(tournament, year)
    winner = df.loc[df["actual_finish_position"] == 1]
    winner_row = winner.iloc[0] if len(winner) else None

    return {
        "n_players":            int(len(df)),
        "n_made_cut":           int(df["actual_made_cut"].sum()),
        "winner":               str(winner_row["player_name"]) if winner_row is not None else None,
        "winner_pred_win_prob": _round_or_none(float(winner_row["pred_win_prob"])) if winner_row is not None else None,
        "model": _model_metrics(df),
        "owgr":  {"brier_win": _round_or_none(_brier(df["pred_owgr_win_prob"],  df["actual_won"]))},
        "dg":    {"brier_win": _round_or_none(_brier(df["pred_dg_win_prob"],    df["actual_won"]))},
        "vegas": {"brier_win": _round_or_none(_brier(df["pred_vegas_win_prob"], df["actual_won"]))},
    }


def get_slice_metrics(tournament: str, year: int, dimension: str) -> list[dict]:
    if dimension not in ("player_tier", "course_type"):
        raise ValueError(f"unsupported dimension: {dimension}")
    df = load_eval_table(tournament, year)

    rows = []
    for bucket, sub in df.groupby(dimension):
        m = _model_metrics(sub)
        rows.append({
            "bucket":         str(bucket),
            "n":              int(len(sub)),
            "brier_win":      m["brier_win"],
            "brier_top10":    m["brier_top10"],
            "spearman_score": m["spearman_score"],
        })
    return rows


def get_calibration_curve(
    tournament: str,
    year: int,
    prediction_column: str,
    n_buckets: int = 5,
) -> list[dict]:
    if prediction_column not in PROB_TO_ACTUAL:
        raise ValueError(f"prediction_column must be one of {list(PROB_TO_ACTUAL)}")
    actual_col = PROB_TO_ACTUAL[prediction_column]
    df = load_eval_table(tournament, year)
    sub = df[[prediction_column, actual_col]].dropna()

    bins = pd.qcut(sub[prediction_column], q=n_buckets, duplicates="drop")
    grouped = sub.groupby(bins, observed=True)

    rows = []
    for i, (_, g) in enumerate(grouped, start=1):
        rows.append({
            "bucket":      i,
            "pred_min":    _round_or_none(float(g[prediction_column].min())),
            "pred_max":    _round_or_none(float(g[prediction_column].max())),
            "pred_mean":   _round_or_none(float(g[prediction_column].mean())),
            "actual_rate": _round_or_none(float(g[actual_col].mean())),
            "n":           int(len(g)),
        })
    return rows


def get_top_residuals(
    tournament: str,
    year: int,
    prediction_column: str,
    n: int = 5,
) -> dict:
    df = load_eval_table(tournament, year).copy()

    if prediction_column in PROB_TO_ACTUAL:
        actual_col = PROB_TO_ACTUAL[prediction_column]
        df["_residual"] = df[prediction_column] - df[actual_col].astype(float)
    elif prediction_column == "pred_score":
        df = df.dropna(subset=["actual_score"])
        df["_residual"] = df["pred_score"] - df["actual_score"]
    else:
        raise ValueError(f"unsupported prediction_column: {prediction_column}")

    df = df.dropna(subset=["_residual"])

    context_cols = [
        "player_name", prediction_column, "actual_finish_position",
        "player_tier", "course_type",
    ]

    def _format(rows: pd.DataFrame) -> list[dict]:
        out = []
        for _, r in rows.iterrows():
            out.append({
                "player_name":            str(r["player_name"]),
                "pred":                   _round_or_none(float(r[prediction_column])),
                "actual_finish_position": (
                    int(r["actual_finish_position"])
                    if pd.notna(r["actual_finish_position"]) else None
                ),
                "player_tier":            str(r["player_tier"]),
                "course_type":            str(r["course_type"]),
                "residual":               _round_or_none(float(r["_residual"])),
            })
        return out

    underperformers = df.nlargest(n, "_residual")[context_cols + ["_residual"]]
    overperformers  = df.nsmallest(n, "_residual")[context_cols + ["_residual"]]

    return {
        "underperformers": _format(underperformers),
        "overperformers":  _format(overperformers),
    }


def compare_to_baseline(
    tournament: str,
    year: int,
    baseline: str,
    prediction_column: str,
) -> dict:
    baseline_col_map = {
        "owgr":  "pred_owgr_win_prob",
        "dg":    "pred_dg_win_prob",
        "vegas": "pred_vegas_win_prob",
    }
    if baseline not in baseline_col_map:
        raise ValueError(f"baseline must be one of {list(baseline_col_map)}")
    if prediction_column not in PROB_TO_ACTUAL:
        raise ValueError(f"prediction_column must be one of {list(PROB_TO_ACTUAL)}")

    baseline_col = baseline_col_map[baseline]
    actual_col = PROB_TO_ACTUAL[prediction_column]

    df = load_eval_table(tournament, year)
    sub = df[[
        "player_name", prediction_column, baseline_col, actual_col,
        "player_tier", "course_type",
    ]].dropna()

    actual = sub[actual_col].astype(float)
    model_se    = (sub[prediction_column] - actual) ** 2
    baseline_se = (sub[baseline_col]      - actual) ** 2
    diff = model_se - baseline_se  # negative means model better

    model_better_pct = float((model_se < baseline_se).mean())
    mean_brier_diff  = float(diff.mean())

    sub = sub.assign(_diff=diff)

    def _format(rows: pd.DataFrame) -> list[dict]:
        out = []
        for _, r in rows.iterrows():
            out.append({
                "player_name":  str(r["player_name"]),
                "model_pred":   _round_or_none(float(r[prediction_column])),
                "baseline_pred":_round_or_none(float(r[baseline_col])),
                "actual":       int(r[actual_col]),
                "player_tier":  str(r["player_tier"]),
                "brier_diff":   _round_or_none(float(r["_diff"])),
            })
        return out

    return {
        "baseline":             baseline,
        "n_compared":           int(len(sub)),
        "model_better_pct":     _round_or_none(model_better_pct, n=3),
        "mean_brier_diff":      _round_or_none(mean_brier_diff),
        "biggest_model_gains":  _format(sub.nsmallest(5, "_diff")),
        "biggest_model_losses": _format(sub.nlargest(5, "_diff")),
    }


# ---- tool schemas ----

TOOL_SCHEMAS = [
    {
        "name": "list_available_evals",
        "description": (
            "List all (tournament, year) eval tables available on disk. "
            "Call this first if the user hasn't specified which event to evaluate, "
            "or if you need to confirm a requested event exists before scoring it."
        ),
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "get_headline_metrics",
        "description": (
            "Return top-level performance metrics for one (tournament, year): "
            "Brier score on win prob, Brier on top-10 prob, Spearman rank "
            "correlation between predicted and actual score, plus Brier on win "
            "prob for each available baseline (OWGR, DataGolf, Vegas). "
            "Use this as your starting point on any eval — it tells you whether "
            "the model is broadly competitive before you drill into where it "
            "wins or loses. A lower Brier is better; a higher Spearman is better."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "tournament": {"type": "string"},
                "year":       {"type": "integer"},
            },
            "required": ["tournament", "year"],
        },
    },
    {
        "name": "get_slice_metrics",
        "description": (
            "Return headline metrics grouped by a slicing dimension. Use this "
            "after get_headline_metrics to localize *where* the model is strong "
            "or weak. Dimensions: 'player_tier' (favorite/mid/longshot — best "
            "for finding calibration failures) and 'course_type' (links/parkland/"
            "desert/etc. — best for finding course-archetype weakness). If the "
            "headline Brier looks fine but you suspect a systematic issue, slice "
            "by player_tier first — that's where most golf models break."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "tournament": {"type": "string"},
                "year":       {"type": "integer"},
                "dimension":  {"type": "string", "enum": ["player_tier", "course_type"]},
            },
            "required": ["tournament", "year", "dimension"],
        },
    },
    {
        "name": "get_calibration_curve",
        "description": (
            "Bucket players by predicted probability and return the average "
            "predicted probability vs the actual observed rate in each bucket. "
            "Use this to detect systematic over- or under-confidence. If the top "
            "bucket's predicted rate is much higher than its actual rate, the "
            "model is overconfident on favorites — a classic golf model failure. "
            "Specify which prediction column to calibrate."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "tournament":        {"type": "string"},
                "year":              {"type": "integer"},
                "prediction_column": {"type": "string", "enum": ["pred_win_prob", "pred_top10_prob"]},
                "n_buckets":         {"type": "integer", "minimum": 2, "maximum": 10},
            },
            "required": ["tournament", "year", "prediction_column"],
        },
    },
    {
        "name": "get_top_residuals",
        "description": (
            "Return the players the model got most wrong and most right. Use "
            "this when slice metrics or calibration suggest a problem but you "
            "need specific examples to characterize it. Returns the top n "
            "underperformers (model said high, player finished low) and top n "
            "overperformers (model said low, player finished high), with their "
            "prediction, actual finish, and key context fields. Look for "
            "patterns — are the misses concentrated in a player archetype?"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "tournament":        {"type": "string"},
                "year":              {"type": "integer"},
                "prediction_column": {"type": "string", "enum": ["pred_win_prob", "pred_top10_prob", "pred_score"]},
                "n":                 {"type": "integer", "minimum": 1, "maximum": 20},
            },
            "required": ["tournament", "year", "prediction_column"],
        },
    },
    {
        "name": "compare_to_baseline",
        "description": (
            "Head-to-head comparison between the model and a single baseline. "
            "Returns: how often the model's prediction was closer to the actual "
            "outcome than the baseline's, the average per-player Brier "
            "differential (negative = model better), and the 5 players where the "
            "model gained the most edge plus the 5 where it lost the most "
            "ground. Use this to answer 'where is our edge actually coming from' "
            "rather than just 'are we better on average.'"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "tournament":        {"type": "string"},
                "year":              {"type": "integer"},
                "baseline":          {"type": "string", "enum": ["owgr", "dg", "vegas"]},
                "prediction_column": {"type": "string", "enum": ["pred_win_prob", "pred_top10_prob"]},
            },
            "required": ["tournament", "year", "baseline", "prediction_column"],
        },
    },
]


# ---------------------------------------------------------------------------
# Live tools
# ---------------------------------------------------------------------------

def get_pretournament_predictions(tournament: str, year: int, top_n: int = 20) -> list[dict]:
    """Return the pre-tournament model rankings (from R/07_pga_preview.R output)."""
    df = _read_preview(tournament, year)
    df = df.sort_values("win_prob", ascending=False).head(top_n)
    out = []
    for _, r in df.iterrows():
        row: dict = {
            "rank":                  int(r["rank"]) if "rank" in df.columns else None,
            "player_name":           str(r["player_name"]),
            "win_prob":              _round_or_none(float(r["win_prob"])),
            "top5_prob":             _round_or_none(float(r["top5_prob"])) if "top5_prob" in df.columns else None,
            "top10_prob":            _round_or_none(float(r["top10_prob"])) if "top10_prob" in df.columns else None,
            "predicted_sg_total":    _round_or_none(float(r["predicted_sg_total"])),
            "predicted_sg_residual": _round_or_none(float(r["predicted_sg_residual"])) if "predicted_sg_residual" in df.columns else None,
            "player_skill_prior":    _round_or_none(float(r["player_skill_prior"])) if "player_skill_prior" in df.columns else None,
            "form_residual_mean_8":  _round_or_none(float(r["form_residual_mean_8"])) if "form_residual_mean_8" in df.columns else None,
            "pred_sg_lo":            _round_or_none(float(r["pred_sg_lo"])) if "pred_sg_lo" in df.columns else None,
            "pred_sg_hi":            _round_or_none(float(r["pred_sg_hi"])) if "pred_sg_hi" in df.columns else None,
        }
        out.append({k: v for k, v in row.items() if v is not None})
    return out


def get_shadow_leaderboard(tournament: str, year: int, after_round: int) -> list[dict]:
    """Return the shadow leaderboard after a completed round."""
    if after_round not in (1, 2, 3):
        raise ValueError("after_round must be 1, 2, or 3")
    df = _read_artifact(f"live_leaderboard_after_r{after_round}")
    out = []
    for _, r in df.iterrows():
        row: dict = {
            "shadow_rank":           int(r["rank"]),
            "player_name":           str(r["player_name"]),
            "predicted_sg_total":    _round_or_none(float(r["predicted_sg_total"])),
            "predicted_sg_residual": _round_or_none(float(r["predicted_sg_residual"])) if "predicted_sg_residual" in df.columns else None,
            "player_skill_prior":    _round_or_none(float(r["player_skill_prior"])) if "player_skill_prior" in df.columns else None,
            "form_residual_mean_8":  _round_or_none(float(r["form_residual_mean_8"])) if "form_residual_mean_8" in df.columns else None,
        }
        # Include completed-round SG columns
        for rn in range(1, after_round + 1):
            col = f"sg_r{rn}"
            if col in df.columns and pd.notna(r[col]):
                row[col] = _round_or_none(float(r[col]))
        # Probabilities
        for col in ("win_prob", "top5_prob", "top10_prob"):
            if col in df.columns and pd.notna(r[col]):
                row[col] = _round_or_none(float(r[col]))
        out.append({k: v for k, v in row.items() if v is not None})
    return out


def get_live_field(tournament: str, year: int) -> dict:
    """
    Raw DataGolf live-tournament-stats for the current event.
    Returns current positions + in-progress SG totals. 60s cached.
    """
    data = _dg_live_request(
        "preds/live-tournament-stats",
        {"stats": "sg_putt,sg_arg,sg_app,sg_ott,sg_total",
         "round": "event_avg",
         "display": "value",
         "file_format": "json"},
    )
    players_raw = (
        data.get("live_stats")
        or data.get("rankings")
        or data.get("data")
        or (list(data.values())[0] if data else [])
    )
    if not isinstance(players_raw, list):
        return {"error": "unexpected response structure", "raw": str(data)[:500]}
    return {
        "event":   data.get("event_name", "unknown"),
        "updated": data.get("last_updated", "unknown"),
        "players": players_raw[:80],  # cap at 80 for token budget
    }


def get_heating_up(
    tournament: str,
    year: int,
    top_n: int = 5,
    min_thru: int = 9,
    percentile_gate: float = 0.90,
) -> dict:
    """
    Identify players running hot (heaters) or cold (crashers) relative to
    model expectations. Requires a shadow leaderboard artifact for the
    current round plus live DataGolf in-round SG.

    Heater: current in-round SG ≥ P{percentile_gate*100} of their predicted dist.
    Crasher: current in-round SG ≤ P{(1-percentile_gate)*100}, position ≤ 30.
    """
    # Find most recent shadow leaderboard
    preds_df: pd.DataFrame | None = None
    for r in (3, 2, 1):
        rds_path = OUTPUT_DIR / f"live_leaderboard_after_r{r}.rds"
        csv_path = OUTPUT_DIR / f"live_leaderboard_after_r{r}.csv"
        if csv_path.exists() or rds_path.exists():
            preds_df = _read_artifact(f"live_leaderboard_after_r{r}")
            last_completed_round = r
            break

    if preds_df is None:
        # Fall back to pre-tournament predictions
        try:
            preview = _read_preview(tournament, year)
            preds_df = preview.rename(columns={"rank": "shadow_rank"})
            last_completed_round = 0
        except FileNotFoundError:
            return {"error": "No model artifact found — run R/07_pga_preview.R or R/08_live_leaderboard.R"}

    # Pull live field for current in-round SG
    live_data = _dg_live_request(
        "preds/live-tournament-stats",
        {"stats": "sg_total",
         "round": "event_avg",
         "display": "value",
         "file_format": "json"},
    )
    players_raw = (
        live_data.get("live_stats")
        or live_data.get("rankings")
        or live_data.get("data")
        or []
    )
    if not players_raw:
        return {"error": "DataGolf live endpoint returned no player data"}

    live_df = pd.DataFrame(players_raw)
    # Normalize column names — DG returns various shapes
    name_col = next((c for c in ("player_name", "player", "name") if c in live_df.columns), None)
    sg_col   = next((c for c in ("sg_total", "total", "sg") if c in live_df.columns), None)
    thru_col = next((c for c in ("thru", "holes_completed", "holes") if c in live_df.columns), None)
    pos_col  = next((c for c in ("position", "pos", "current_pos") if c in live_df.columns), None)

    if not name_col or not sg_col:
        return {"error": f"Cannot parse live field — columns: {list(live_df.columns)[:10]}"}

    live_df = live_df.rename(columns={
        name_col: "player_name",
        sg_col:   "live_sg_total",
        **(({thru_col: "thru"}) if thru_col else {}),
        **(({pos_col: "current_position"}) if pos_col else {}),
    })
    live_df["live_sg_total"] = pd.to_numeric(live_df["live_sg_total"], errors="coerce")
    if "thru" in live_df.columns:
        live_df["thru"] = pd.to_numeric(live_df["thru"], errors="coerce").fillna(0)
    else:
        live_df["thru"] = 18  # assume complete if unavailable

    if "current_position" in live_df.columns:
        live_df["pos_num"] = (
            live_df["current_position"]
            .astype(str)
            .str.replace(r"^T", "", regex=True)
            .pipe(pd.to_numeric, errors="coerce")
        )
    else:
        live_df["pos_num"] = None

    # Join predictions to live data
    merged = preds_df.merge(live_df[["player_name", "live_sg_total", "thru"] +
                                     (["pos_num"] if "pos_num" in live_df.columns else [])],
                            on="player_name", how="inner")
    merged = merged[merged["thru"] >= min_thru].dropna(subset=["live_sg_total"])

    if merged.empty:
        return {"heaters": [], "crashers": [], "note": f"No players with thru >= {min_thru}"}

    # Estimate distribution: use pred_sg_lo/hi interval if available, else field std
    if "pred_sg_lo" in merged.columns and "pred_sg_hi" in merged.columns:
        # Treat [lo, hi] as ~95% interval → σ ≈ (hi-lo)/3.92
        merged["pred_sg_std"] = (merged["pred_sg_hi"] - merged["pred_sg_lo"]) / 3.92
    else:
        # Use field-wide std of predicted_sg_total as a uniform scale
        field_std = float(merged["predicted_sg_total"].std())
        merged["pred_sg_std"] = max(field_std, 0.3)

    merged["pred_sg_std"] = merged["pred_sg_std"].clip(lower=0.15)

    # Percentile of each player's live SG vs. their predicted distribution
    merged["percentile"] = merged.apply(
        lambda r: float(norm.cdf(r["live_sg_total"],
                                  loc=r["predicted_sg_total"],
                                  scale=r["pred_sg_std"])),
        axis=1,
    )
    merged["excess"] = (merged["percentile"] - 0.50).clip(lower=0)
    merged["win_prob"] = pd.to_numeric(merged.get("win_prob", pd.Series(0.01, index=merged.index)),
                                        errors="coerce").fillna(0.01)
    merged["equity_score"] = merged["win_prob"] * merged["percentile"]

    # Heaters: P{gate} or above
    heaters = (
        merged[merged["percentile"] >= percentile_gate]
        .sort_values("equity_score", ascending=False)
        .head(top_n)
    )
    # Crashers: P{1-gate} or below, position ≤ 30
    crasher_mask = merged["percentile"] <= (1 - percentile_gate)
    if "pos_num" in merged.columns:
        crasher_mask = crasher_mask & (merged["pos_num"] <= 30)
    crashers = (
        merged[crasher_mask]
        .sort_values("equity_score", ascending=True)
        .head(top_n)
    )

    def _fmt(row: pd.Series) -> dict:
        return {
            "player_name":        str(row["player_name"]),
            "live_sg_total":      _round_or_none(float(row["live_sg_total"])),
            "predicted_sg_total": _round_or_none(float(row["predicted_sg_total"])),
            "percentile":         _round_or_none(float(row["percentile"])),
            "win_prob":           _round_or_none(float(row["win_prob"])),
            "thru":               int(row["thru"]) if pd.notna(row["thru"]) else None,
        }

    return {
        "heaters":  [_fmt(r) for _, r in heaters.iterrows()],
        "crashers": [_fmt(r) for _, r in crashers.iterrows()],
        "based_on": f"live_leaderboard_after_r{last_completed_round}" if last_completed_round > 0 else "pretournament_predictions",
        "live_updated": live_data.get("last_updated", "unknown"),
    }


# ---------------------------------------------------------------------------
# Extend TOOL_SCHEMAS and TOOL_DISPATCH with live tools
# ---------------------------------------------------------------------------

LIVE_TOOL_SCHEMAS = [
    {
        "name": "get_pretournament_predictions",
        "description": (
            "Return the pre-tournament model rankings from R/07_pga_preview.R output. "
            "Use this to answer 'who does the model like?' before or during a tournament. "
            "Returns win_prob, top10_prob, predicted_sg_total, form_residual, and skill prior "
            "for the top N players sorted by win probability."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "tournament": {"type": "string", "description": "Tournament slug, e.g. 'us_open' or 'memorial'"},
                "year":       {"type": "integer"},
                "top_n":      {"type": "integer", "minimum": 1, "maximum": 80, "description": "Number of players to return (default 20)"},
            },
            "required": ["tournament", "year"],
        },
    },
    {
        "name": "get_shadow_leaderboard",
        "description": (
            "Return the Shadow Leaderboard — players re-ranked by predicted SG performance "
            "instead of actual score — after a completed round. Includes residual decomposition "
            "and updated win probabilities. Use this to answer 'where do things actually stand?' "
            "or 'who's playing better than their score shows?'"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "tournament":   {"type": "string"},
                "year":         {"type": "integer"},
                "after_round":  {"type": "integer", "enum": [1, 2, 3], "description": "Which completed round to read"},
            },
            "required": ["tournament", "year", "after_round"],
        },
    },
    {
        "name": "get_live_field",
        "description": (
            "Return raw DataGolf live-tournament-stats for the current event: "
            "current positions and in-progress SG totals. 60-second cached. "
            "Use this when Steve asks where players stand right now without needing "
            "the model layer. For heating-up analysis, prefer get_heating_up."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "tournament": {"type": "string"},
                "year":       {"type": "integer"},
            },
            "required": ["tournament", "year"],
        },
    },
    {
        "name": "get_heating_up",
        "description": (
            "Identify players running hot (heaters) or cold (crashers) relative to "
            "model expectations using live in-round SG. Heaters are above P90 of "
            "their predicted SG distribution with 9+ holes played. Crashers are below "
            "P10 in the top 30 positions. Ranked by equity score (win_prob × percentile). "
            "Use this when Steve asks 'who's heating up?' or 'anyone surprising today?'"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "tournament": {"type": "string"},
                "year":       {"type": "integer"},
                "top_n":      {"type": "integer", "minimum": 1, "maximum": 10},
            },
            "required": ["tournament", "year"],
        },
    },
]

TOOL_DISPATCH = {
    "list_available_evals":        list_available_evals,
    "get_headline_metrics":        get_headline_metrics,
    "get_slice_metrics":           get_slice_metrics,
    "get_calibration_curve":       get_calibration_curve,
    "get_top_residuals":           get_top_residuals,
    "compare_to_baseline":         compare_to_baseline,
    # live tools
    "get_pretournament_predictions": get_pretournament_predictions,
    "get_shadow_leaderboard":        get_shadow_leaderboard,
    "get_live_field":                get_live_field,
    "get_heating_up":               get_heating_up,
}

TOOL_SCHEMAS = TOOL_SCHEMAS + LIVE_TOOL_SCHEMAS
