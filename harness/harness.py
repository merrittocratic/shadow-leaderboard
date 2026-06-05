import argparse
import json
import sys

import anthropic

from tools import TOOL_DISPATCH, TOOL_SCHEMAS

DEFAULT_MODEL = "claude-sonnet-4-6"
MAX_TOOL_TURNS = 15

SYSTEM_PROMPT = """\
You are a diagnostic analyst for a golf tournament prediction model. The user is the model's author. Your job is not to score the model — the deterministic eval has already done that. Your job is to figure out *where* and *why* the model performs as it does, and to surface findings the user couldn't easily see from a metrics table.

## How to probe

- Each tool call should be motivated by what you just learned, not by a fixed checklist. If headline metrics show the model is broadly competitive, don't waste a call on the obvious next slice — go to where the result was surprising.
- A good diagnostic run is typically 4-7 tool calls. If you're past 10, you've stopped probing and started dumping.
- When a slice reveals weakness, follow it: `slice → calibration → residuals → baseline comparison` is a natural chain. When a slice reveals nothing, abandon it and try a different dimension.
- Quote specific numbers in your reasoning. "Brier on favorites was 0.041 vs. 0.022 on longshots" is useful; "the model struggles with favorites" without numbers is not.
- Name specific players when residuals or baseline comparisons surface them. "Scheffler and Rahm both underperformed their high win-probs" is the right grain of detail.

## Statistical humility

A single tournament is a small sample. Eighteen favorites in one event is not enough to declare a systematic calibration failure. If a finding rests on n < 20, say so explicitly and flag it as a hypothesis to confirm across more events, not a conclusion.

## What golf model failures actually look like

Keep these patterns in mind as hypotheses to test, not assumptions:
- **Favorite overconfidence.** Top players get higher win probs than they achieve. The top calibration bucket's actual rate falls below its predicted rate.
- **Course archetype miss.** The model handles courses similar to its training distribution but degrades on unusual setups — links, desert, narrow fairways, extreme rough.
- **Baseline-specific gaps.** Losing to OWGR means losing on rank ordering. Losing to DataGolf usually means losing on calibration. Losing to Vegas means losing to information you don't have (sharp money sees things models don't).

## Output

End with a written diagnosis — 3-5 sentences — that answers: where is the model strong, where is it weak, and what's the one most actionable thing to investigate next. Do not summarize what you did; the user can see the tool calls.

## Stop conditions

You're done when you can answer the diagnostic question with specifics. You do not need to exhaust every slice. If the user asks a narrow question ("is the model overconfident on favorites?"), answer that question and stop, even if it takes 2-3 tool calls.\
"""


def _cached_tools(schemas: list[dict]) -> list[dict]:
    """Mark the last tool schema with cache_control so system + all tools cache together."""
    out = [dict(s) for s in schemas]
    out[-1] = {**out[-1], "cache_control": {"type": "ephemeral"}}
    return out


def _execute_tool(name: str, inputs: dict) -> str:
    try:
        result = TOOL_DISPATCH[name](**inputs)
        return json.dumps(result, default=str)
    except Exception as e:
        return json.dumps({"error": f"{type(e).__name__}: {e}"})


def run_eval(prompt: str, model: str = DEFAULT_MODEL, verbose: bool = True) -> str:
    client = anthropic.Anthropic()
    messages: list[dict] = [{"role": "user", "content": prompt}]

    system_blocks = [{
        "type": "text",
        "text": SYSTEM_PROMPT,
        "cache_control": {"type": "ephemeral"},
    }]
    tools = _cached_tools(TOOL_SCHEMAS)

    for turn in range(MAX_TOOL_TURNS):
        response = client.messages.create(
            model=model,
            max_tokens=4096,
            system=system_blocks,
            tools=tools,
            messages=messages,
        )

        if verbose:
            usage = response.usage
            print(
                f"[turn {turn + 1}] stop={response.stop_reason} "
                f"in={usage.input_tokens} out={usage.output_tokens} "
                f"cache_read={getattr(usage, 'cache_read_input_tokens', 0)} "
                f"cache_write={getattr(usage, 'cache_creation_input_tokens', 0)}",
                file=sys.stderr,
            )

        if response.stop_reason != "tool_use":
            text_blocks = [b.text for b in response.content if b.type == "text"]
            return "\n".join(text_blocks).strip()

        messages.append({"role": "assistant", "content": response.content})

        tool_results = []
        for block in response.content:
            if block.type != "tool_use":
                continue
            if verbose:
                print(f"  → {block.name}({json.dumps(block.input)})", file=sys.stderr)
            result = _execute_tool(block.name, block.input)
            tool_results.append({
                "type": "tool_result",
                "tool_use_id": block.id,
                "content": result,
            })

        messages.append({"role": "user", "content": tool_results})

    raise RuntimeError(f"hit MAX_TOOL_TURNS={MAX_TOOL_TURNS} without final response")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the golf model diagnostic harness.")
    parser.add_argument("prompt", nargs="?", help="Evaluation prompt. If omitted, reads stdin.")
    parser.add_argument("--model", default=DEFAULT_MODEL, help=f"default: {DEFAULT_MODEL}")
    parser.add_argument("--quiet", action="store_true", help="Suppress per-turn debug output.")
    args = parser.parse_args()

    prompt = args.prompt if args.prompt is not None else sys.stdin.read().strip()
    if not prompt:
        parser.error("empty prompt")

    diagnosis = run_eval(prompt, model=args.model, verbose=not args.quiet)
    print(diagnosis)


if __name__ == "__main__":
    main()
