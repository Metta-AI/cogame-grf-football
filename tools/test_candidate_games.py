"""Complete candidate exports with prompt provenance and execution joins."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
OUTPUT = Path(sys.argv[2]).resolve()


def main():
    OUTPUT.mkdir(mode=0o700, parents=True, exist_ok=False)
    totals = 0
    families = set()
    for variant in ("match", "half"):
        reference = None
        for wording in ("canonical", "plain", "numbered", "questions", "reordered"):
            destination = OUTPUT / f"{variant}-{wording}"
            subprocess.run(
                [str(EXPORTER), str(destination), "10", "1", variant, wording, "0"],
                cwd=ROOT,
                check=True,
                timeout=180,
            )
            episodes, decisions, trace = {}, {}, []
            with (destination / "trajectories.jsonl").open() as stream:
                for line in stream:
                    row = json.loads(line)
                    episode = row["episode_id"]
                    if row["event_type"] == "episode":
                        assert (
                            row["status"] == "completed"
                            and row["outcome"]["reason"] == "complete"
                        )
                        families.add(row["seed_family"])
                        episodes[episode] = row
                        trace.append(row["outcome"])
                        continue
                    assert (
                        row["visibility"] == "private"
                        and row["action_status"] == "accepted"
                    )
                    assert (
                        len(row["attempts"]) == 1
                        and row["attempts"][0]["origin"] == "teacher"
                    )
                    assert (
                        row["selected_attempt_id"] == row["attempts"][0]["attempt_id"]
                    )
                    assert (
                        json.loads(row["attempts"][0]["response"])
                        == row["executed_action"]
                    )
                    view = row["observation"].copy()
                    metadata = view.pop("prompt_template")
                    assert (
                        metadata["bank"] == "grf-football-rules-v1"
                        and metadata["variant"] == wording
                    )
                    for message in row["prompt"]:
                        assert (
                            metadata[message["role"] + "_sha256"].lower()
                            == hashlib.sha256(message["content"].encode()).hexdigest()
                        )
                    decisions[(episode, int(row["decision_id"]))] = row
                    trace.append((view, row["prompt"][1], row["executed_action"]))
            assert len(episodes) == 10
            assert len(decisions) == (1920 if variant == "match" else 960)
            if reference is None:
                reference = trace
            else:
                assert trace == reference
            joined = set()
            ticks = {}
            with (destination / "execution.jsonl").open() as stream:
                for line in stream:
                    row = json.loads(line)
                    episode = row["episode_id"]
                    assert episode in episodes and row["visibility"] == "private"
                    if row["event_type"] == "turn_execution":
                        for seat, order in enumerate(row["orders"]):
                            key = (episode, row["first_decision_id"] + seat)
                            assert key not in joined
                            joined.add(key)
                            action = decisions[key]["executed_action"]
                            assert (
                                order["note"] == action["note"]
                                and order["cogs"] == action["cogs"]
                            )
                    else:
                        previous_tick = ticks.setdefault(episode, 0)
                        assert row["tick"] == previous_tick + 1
                        ticks[episode] = row["tick"]
                        assert len(row["actions"]) == 22 and all(
                            0 <= action < 19 for action in row["actions"]
                        )
                        assert (
                            int(row["before_hash"]) >= 0 and int(row["after_hash"]) >= 0
                        )
            assert joined == decisions.keys()
            assert (
                not (destination / "train.jsonl").exists()
                and not (destination / "validation.jsonl").exists()
            )
            totals += len(episodes)
            print(
                variant,
                wording,
                "ten complete candidate matches and execution joins PASS",
                flush=True,
            )
    assert len(families) == 10
    print(totals, "matches; ten shared families PASS", flush=True)


if __name__ == "__main__":
    main()
