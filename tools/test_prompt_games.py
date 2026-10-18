"""Complete eight-seat football matches through the real decision bridge."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = Path(sys.argv[1]).resolve()
WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
)


def play(variant, seed, wording, prompt_seed=0):
    with subprocess.Popen(
        [str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as process:
        assert process.stdin is not None and process.stdout is not None

        def request(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            line = process.stdout.readline()
            assert line, process.poll()
            return json.loads(line)

        observation = request(
            dict(
                kind="reset",
                players=8,
                seed=str(seed),
                promptVariant=wording,
                promptSeed=prompt_seed,
                split="test",
            )
        )
        trace = []
        systems = set()
        while observation["kind"] == "decision":
            view = observation["semantic_view"].copy()
            metadata = view.pop("prompt_template")
            assert metadata["bank"] == "grf-football-rules-v1"
            assert metadata["selection"] == wording
            assert metadata["variant"] == (
                WORDINGS[prompt_seed % 5] if wording == "mixed" else wording
            )
            assert metadata["seed"] == prompt_seed
            for message in observation["messages"]:
                assert (
                    metadata[message["role"] + "_sha256"].lower()
                    == hashlib.sha256(message["content"].encode()).hexdigest()
                )
            action = json.loads(request({"kind": "teacher"})["response"])
            seat = observation["seat"]
            action["note"] = f"PRIVATE-NOTE-{seat}"
            action["cogs"][0]["say"] = f"SPECTATOR-{seat}"
            for other in range(8):
                if other != seat:
                    assert (
                        f"PRIVATE-NOTE-{other}"
                        not in observation["messages"][1]["content"]
                    )
                assert f"SPECTATOR-{other}" not in observation["messages"][1]["content"]
            reply = request(
                dict(
                    kind="step",
                    decision_id=observation["decision_id"],
                    response=json.dumps(action),
                )
            )
            assert reply["kind"] == "accepted"
            assert reply["action"]["note"] == action["note"]
            assert reply["action"]["cogs"][0]["say"] == action["cogs"][0]["say"]
            trace.append(
                (
                    seat,
                    observation["turn"],
                    view,
                    observation["messages"][1],
                    reply["action"],
                )
            )
            systems.add(observation["messages"][0]["content"])
            observation = reply["observation"]
        assert len(trace) == (192 if variant == "match" else 96)
        assert abs(sum(observation["scores"].values()) - 4) < 1e-6
        assert len(systems) == 1
        process.stdin.close()
        assert process.wait(timeout=10) == 0
        return trace, observation, systems


def main():
    count = 0
    for variant in ("match", "half"):
        for seed in (7, 19):
            baseline = play(variant, seed, "canonical")
            count += 1
            wordings = {next(iter(baseline[2]))}
            for wording in WORDINGS[1:]:
                current = play(variant, seed, wording)
                assert current[:2] == baseline[:2], (variant, seed, wording)
                wordings.update(current[2])
                count += 1
            assert len(wordings) == 7
            for prompt_seed in range(5):
                current = play(variant, seed, "mixed", prompt_seed)
                assert current[:2] == baseline[:2], (variant, seed, prompt_seed)
                count += 1
            print(
                variant,
                seed,
                "all wordings, private notes and outcomes PASS",
                flush=True,
            )
    print(count, "complete matches PASS", flush=True)


if __name__ == "__main__":
    main()
