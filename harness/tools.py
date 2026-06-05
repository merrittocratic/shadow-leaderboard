import numpy as np
import pandas as pd
from scipy.stats import spearmanr

from loader import list_eval_tables, load_eval_table

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


TOOL_DISPATCH = {
    "list_available_evals":  list_available_evals,
    "get_headline_metrics":  get_headline_metrics,
    "get_slice_metrics":     get_slice_metrics,
    "get_calibration_curve": get_calibration_curve,
    "get_top_residuals":     get_top_residuals,
    "compare_to_baseline":   compare_to_baseline,
}
