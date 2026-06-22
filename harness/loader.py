from pathlib import Path

import pandas as pd

EVAL_DIR = Path(__file__).resolve().parent.parent / "output" / "eval"

EXPECTED_SCHEMA: dict[str, tuple[str, bool]] = {
    "player_id":              ("int64",   False),
    "player_name":            ("object",  False),
    "tournament":             ("object",  False),
    "year":                   ("int32",   False),
    "pred_win_prob":          ("float64", False),
    "pred_top10_prob":        ("float64", False),
    "pred_score":             ("float64", False),
    "pred_owgr_win_prob":     ("float64", True),
    "pred_dg_win_prob":       ("float64", True),
    "pred_vegas_win_prob":    ("float64", True),
    "actual_finish_position": ("Int32",   True),
    "actual_made_cut":        ("bool",    False),
    "actual_won":             ("bool",    False),
    "actual_top10":           ("bool",    False),
    "actual_score":           ("float64", True),
    "course_type":            ("object",  False),
    "player_tier":            ("object",  False),
    "is_in_form":             ("bool",    False),
}


def eval_path(tournament: str, year: int) -> Path:
    return EVAL_DIR / f"predictions_{tournament}_{year}.parquet"


def load_eval_table(tournament: str, year: int) -> pd.DataFrame:
    path = eval_path(tournament, year)
    if not path.exists():
        raise FileNotFoundError(f"no eval table at {path} — run R/eval_export.R first")

    df = pd.read_parquet(path)

    # R's arrow writes as.integer() as int32; cast to int64 before schema check.
    if "player_id" in df.columns and str(df["player_id"].dtype) == "int32":
        df["player_id"] = df["player_id"].astype("int64")

    missing = set(EXPECTED_SCHEMA) - set(df.columns)
    if missing:
        raise ValueError(f"missing columns: {sorted(missing)}")

    for col, (dtype, nullable) in EXPECTED_SCHEMA.items():
        actual = str(df[col].dtype)
        if actual != dtype:
            raise ValueError(f"{col}: expected dtype {dtype}, got {actual}")
        if not nullable and df[col].isna().any():
            raise ValueError(f"{col} has nulls but is non-nullable")

    n = len(df)
    if not (50 <= n <= 250):
        raise ValueError(f"field size {n} is outside expected range 50-250")
    if df["player_id"].duplicated().any():
        raise ValueError("duplicate player_id")

    win_sum = df["pred_win_prob"].sum()
    if not (0.90 <= win_sum <= 1.10):
        raise ValueError(f"pred_win_prob sums to {win_sum:.3f}, expected ~1.0")

    top10_sum = df["pred_top10_prob"].sum()
    if not (9.0 <= top10_sum <= 11.0):
        raise ValueError(f"pred_top10_prob sums to {top10_sum:.3f}, expected ~10.0")

    # finish_position is intentionally NA for missed-cut players; check cut rate
    # and finish coverage among cut-makers instead of raw field coverage.
    cut_rate = df["actual_made_cut"].mean()
    if cut_rate < 0.15:
        raise ValueError(
            f"cut rate {cut_rate:.0%} — likely a join bug (nearly everyone appears as non-cut)"
        )
    cutmakers = df["actual_made_cut"]
    if cutmakers.any():
        finish_coverage_cutmakers = df.loc[cutmakers, "actual_finish_position"].notna().mean()
        if finish_coverage_cutmakers < 0.85:
            raise ValueError(
                f"only {finish_coverage_cutmakers:.0%} of cut-makers have a finish position"
                " — likely a fin_text parsing bug"
            )

    return df


def list_eval_tables() -> list[dict]:
    if not EVAL_DIR.exists():
        return []
    out = []
    for p in sorted(EVAL_DIR.glob("predictions_*_*.parquet")):
        stem = p.stem.removeprefix("predictions_")
        tournament, _, year_str = stem.rpartition("_")
        out.append({"tournament": tournament, "year": int(year_str)})
    return out
