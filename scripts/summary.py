#!/usr/bin/env python3
"""Summarise results/measurements.tsv rows written since a start time and check the headline outcomes.

usage: summary.py --since 2026-10-11T10:00:00 [--runs 5 --placements P0,P1,... --drain 1 --full 0
                  --runner-failures file] [--markdown out.md] results/measurements.tsv

Checks: every row's verdict; the headline outcomes; and, when the test plan is given (scripts/lab.sh passes it),
that every planned placement and test was measured in every run and that no runner exited with an error.
Exit status 0 when every check holds, 1 otherwise.
"""
import argparse
import collections
import csv
import sys

PLACEMENTS = ["P0-OFF", "P0-OFF-LIT", "P0", "P-AGW", "P-AGW2995", "P1", "P2", "P2-NP", "P-AGW2995-SEAL"]
COLUMNS = ["T0", "T0-B", "PC-anon", "PC-agent-c", "AUD", "T1", "T3a", "T3b", "T4", "TL", "TB", "TR",
           "R-8:rotated", "R-8:removed", "T2a-exp", "DRAIN-watch", "DRAIN-force"]

# Placements that bind a task to its owner, and those that do not (the baseline).
BINDING = ["P1", "P2", "P2-NP", "P-AGW2995-SEAL"]
NOT_BINDING = ["P0-OFF", "P0", "P-AGW", "P-AGW2995"]
CROSS_TENANT = ["T1", "T3a", "T3b", "TL"]
# Rows whose FAIL is the measured result, not a lab fault: with a per-request handler the owner
# cannot read its own task (the store lives one request long).
EXPECTED_FAIL = {("P0-OFF-LIT", "T0")}
OK_VERDICTS = {"PASS", "MATCH", "OBSERVED", "N/A"}

# Tests that one default run of lab/run-placement.sh writes per placement (scripts/lab.sh test).
BASE = ["T0", "T0-B", "PC-anon", "PC-agent-c", "AUD", "T1", "T3a", "T3b", "T4", "TL"]
REQUIRED = {p: BASE for p in ["P0-OFF", "P0", "P-AGW", "P-AGW2995", "P-AGW2995-SEAL"]}
REQUIRED.update({
    "P0-OFF-LIT": ["T0"],
    "P1": BASE + ["TL-upstream"],
    "P2": BASE + ["TL-upstream", "TB", "TR", "R-1"],
    "P2-NP": ["T0", "T1", "TL", "TL-upstream", "TB", "R-1"],
})
DRAIN = {"P0": ("read", "forced-by-B"), "P-AGW": ("read", "forced-by-B"), "P1": ("refused", "refused"), "P2": ("read", "refused")}
# outcomes beyond the cross-tenant four that the README states
EXPECT = {("P0-OFF-LIT", "T0"): "fail", ("P2", "TB"): "reached", ("P2-NP", "TB"): "blocked", ("P2", "TR"): "opens-everywhere"}
for _p in BINDING:
    EXPECT[(_p, "T4")] = "indistinguishable"
for _p in ["P1", "P2", "P-AGW", "P-AGW2995", "P-AGW2995-SEAL"]:
    EXPECT[(_p, "PC-anon")] = EXPECT[(_p, "PC-agent-c")] = "refused"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", required=True, help="UTC start time, ISO 8601")
    ap.add_argument("--markdown", help="also write the table as Markdown to this file")
    ap.add_argument("--runs", type=int, help="planned runs per placement")
    ap.add_argument("--placements", help="planned placements, comma-separated")
    ap.add_argument("--drain", type=int, default=0, help="1 if the drain demo was planned")
    ap.add_argument("--full", type=int, default=0, help="1 if token lifetime and key rotation were planned")
    ap.add_argument("--runner-failures", help="file with one line per runner that exited with an error")
    ap.add_argument("--incomplete", action="store_true", help="the test run did not reach its end")
    ap.add_argument("tsv")
    a = ap.parse_args()

    with open(a.tsv, newline="") as f:
        rows = [r for r in csv.DictReader(f, delimiter="\t") if r["time"][:19] >= a.since[:19]]
    if not rows:
        print(f"no measurements since {a.since}")
        return 1

    cells = collections.defaultdict(collections.Counter)   # (placement, test) -> Counter(observed)
    runs = collections.defaultdict(set)
    test_runs = collections.defaultdict(set)              # (placement, test) -> run ids
    problems = []
    for r in rows:
        p, t, v, o = r["placement"], r["test"], r["verdict"], r["observed"]
        runs[p].add(r["run_id"])
        test_runs[(p, t)].add(r["run_id"])
        if t.startswith("T2a-exp"):
            o = o.split(" at ")[0].split(" (")[0]          # drop the timing detail
        cells[(p, t)][o] += 1
        if v == "FAIL" and (p, t) in EXPECTED_FAIL:
            continue
        if v not in OK_VERDICTS:
            problems.append(f"{p} {t}: {v} (expected {r['expected']}, observed {o}) run {r['run_id']}")

    def fmt(c):
        n = sum(c.values())
        return " / ".join(f"{k} {v}/{n}" for k, v in c.most_common())

    for p in BINDING + NOT_BINDING:
        if p not in runs:
            continue
        want = "refused" if p in BINDING else "access"
        for t in CROSS_TENANT:
            c = cells.get((p, t))
            if not c:
                if p == "P2-NP" and t in ("T3a", "T3b"):
                    continue                                  # P2-NP runs the bypass subset only
                problems.append(f"{p} {t}: no measurement")
                continue
            if p == "P0-OFF" and t == "T3b" and set(c) == {"not-applicable"}:
                continue                                      # the official example has no input_required tool
            if set(c) != {want}:
                problems.append(f"{p} {t}: expected '{want}' in every run, got {fmt(c)}")

    for (p, t), want in EXPECT.items():
        c = cells.get((p, t))
        if c and set(c) != {want}:
            problems.append(f"{p} {t}: expected '{want}' in every run, got {fmt(c)}")
    for p, (watch, force) in DRAIN.items():
        for t, want in (("DRAIN-watch", watch), ("DRAIN-force", force)):
            c = cells.get((p, t))
            if c and set(c) != {want}:
                problems.append(f"{p} {t}: expected '{want}' in every run, got {fmt(c)}")

    # completeness against the plan: a missing placement, test or run is a failure, not a silent gap
    if a.runs and a.placements:
        planned = [p for p in a.placements.split(",") if p]
        for p in planned:
            for t in REQUIRED.get(p, []):
                n = len(test_runs.get((p, t), ()))
                if n < a.runs:
                    problems.append(f"{p} {t}: measured in {n} of {a.runs} runs")
        if a.drain:
            for p in DRAIN:
                for t in ("DRAIN-watch", "DRAIN-force"):
                    n = len(test_runs.get((p, t), ()))
                    if n < a.runs:
                        problems.append(f"{p} {t}: measured in {n} of {a.runs} runs")
        if a.full:
            for p in ["P0-OFF", "P1", "P-AGW", "P2"]:
                for t in ("T2a", "T2b", "T2a-exp"):
                    if not test_runs.get((p, t)):
                        problems.append(f"{p} {t}: not measured")
            for t in ("R-8:rotated", "R-8:removed"):
                n = len(test_runs.get(("P2", t), ()))
                if n < a.runs:
                    problems.append(f"P2 {t}: measured in {n} of {a.runs} runs")
        extra = sorted(set(runs) - set(planned))
        if extra:
            problems.append(f"placements not in the plan: {', '.join(extra)}")
    if a.incomplete:
        problems.append("the test run did not reach its end (interrupted or aborted)")
    if a.runner_failures:
        try:
            for line in open(a.runner_failures):
                if line.strip():
                    problems.append(f"runner failed: {line.strip()}")
        except FileNotFoundError:
            pass

    present = [p for p in PLACEMENTS if p in runs]
    cols = [t for t in COLUMNS if any((p, t) in cells for p in present)]
    lines = ["| placement | runs | " + " | ".join(cols) + " |", "|---|---|" + "---|" * len(cols)]
    for p in present:
        lines.append(f"| {p} | {len(runs[p])} | " + " | ".join(fmt(cells[(p, t)]) if (p, t) in cells else "" for t in cols) + " |")
    table = "\n".join(lines)

    print(f"\nMeasurements since {a.since}: {len(rows)} rows, placements: {', '.join(present)}\n")
    print(table)
    print("\nOwner-binding placements (expect 'refused' for T1/T3a/T3b/TL):", ", ".join(p for p in BINDING if p in runs))
    print("Baseline placements      (expect 'access'  for T1/T3a/T3b/TL):", ", ".join(p for p in NOT_BINDING if p in runs))
    if problems:
        print("\nCHECKS FAILED:")
        for x in problems:
            print("  - " + x)
    else:
        print("\nALL CHECKS PASSED")
    if a.markdown:
        with open(a.markdown, "w") as f:
            f.write(f"Measurements since {a.since} ({len(rows)} rows)\n\n{table}\n\n")
            f.write("Checks: " + ("all passed\n" if not problems else "FAILED\n" + "".join(f"- {x}\n" for x in problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
