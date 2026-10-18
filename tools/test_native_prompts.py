"""Complete native football matches, retaining real failed requests and replay proof."""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import time
from pathlib import Path

from replay_summary import Reader, decompress, MAGIC


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("rehash", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / "coworld_manifest_template.json").read_text())
    variants = {entry["id"]: entry["game_config"] for entry in manifest["variants"]}
    cases = [(variant, "canonical") for variant in variants]
    if not args.smoke:
        cases += [
            ("match", wording)
            for wording in (
                "plain",
                "numbered",
                "questions",
                "reordered",
                "heldout-briefing",
                "heldout-reference",
                "mixed",
            )
        ]
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    for variant, wording in cases:
        work = args.output / f"{variant}-{wording}"
        work.mkdir(mode=0o700)
        config = dict(variants[variant])
        config.update(
            seed=7,
            promptVariant=wording,
            promptSeed=4,
            tokens=[f"t{seat}" for seat in range(8)],
            players=[{"name": f"policy-{seat}"} for seat in range(8)],
        )
        (work / "config.json").write_text(json.dumps(config))
        port = free_port()
        closed = socket.socket()
        closed.bind(("127.0.0.1", 0))
        env = os.environ.copy()
        for key in (
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_API_KEY_URI",
            "AWS_BEARER_TOKEN_BEDROCK",
            "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
            "PLAYER_SCRIPTED",
        ):
            env.pop(key, None)
        env.update(
            COGAME_HOST="127.0.0.1",
            COGAME_PORT=str(port),
            COGAME_CONFIG_URI=(work / "config.json").as_uri(),
            COGAME_RESULTS_URI=(work / "results.json").as_uri(),
            COGAME_SAVE_REPLAY_URI=(work / "episode.replay").as_uri(),
            COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{closed.getsockname()[1]}",
            GRF_FOOTBALL_TRACE_DIR=str(work / "private"),
            GRF_FOOTBALL_SOURCE_REVISION="uncommitted-football-validation",
        )
        processes, logs = [], []
        try:
            log = (work / "game.log").open("w")
            logs.append(log)
            game = subprocess.Popen(
                [str(args.game)],
                cwd=root,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            processes.append(game)
            for _ in range(400):
                assert game.poll() is None, work
                with socket.socket() as probe:
                    ready = probe.connect_ex(("127.0.0.1", port)) == 0
                if ready:
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError(f"host did not start: {work}")
            for seat in range(8):
                player_env = dict(
                    env,
                    COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                    PLAYER_PROMPT=f"PRIVATE-STRATEGY-{seat}: Play your shirt using the match view.",
                )
                log = (work / f"player-{seat}.log").open("w")
                logs.append(log)
                processes.append(
                    subprocess.Popen(
                        [str(args.player)],
                        cwd=root,
                        env=player_env,
                        stdout=log,
                        stderr=subprocess.STDOUT,
                    )
                )
            assert game.wait(timeout=config["wallClockBudgetSeconds"] + 60) == 0
            for player in processes[1:]:
                assert player.wait(timeout=15) == 0
            results = json.loads((work / "results.json").read_text())
            assert results["reason"] == "complete"
            trace = work / "private"
            for path in trace.iterdir():
                assert path.stat().st_mode & 0o777 == 0o600
            rows = [
                json.loads(line)
                for line in (trace / "decisions.jsonl").read_text().splitlines()
            ]
            decisions = [row for row in rows if row["event_type"] == "decision"]
            resolutions = {
                row["attempt_id"]: row
                for row in rows
                if row["event_type"] == "attempt_resolution"
            }
            expected = 192 if variant == "match" else 96
            assert len(decisions) == expected
            attempts = [
                json.loads(line)
                for line in (trace / "attempts.jsonl").read_text().splitlines()
            ]
            starts = {
                row["attempt_id"]: row
                for row in attempts
                if row["event_type"] == "attempt_started"
            }
            finishes = {
                row["attempt_id"]: row
                for row in attempts
                if row["event_type"] == "attempt_finished"
            }
            assert (
                len(starts) == expected * 2
                and starts.keys() == finishes.keys() == resolutions.keys()
            )
            for index, row in enumerate(decisions):
                seat, turn = index % 8, index // 8
                assert row["seat"] == seat and row["turn"] == turn
                assert (
                    row["selected_attempt_id"] is None
                    and row["action_status"] == "dsFallback"
                )
                system, user = [message["content"] for message in row["prompt"]]
                assert f"PRIVATE-STRATEGY-{seat}" in user
                assert all(
                    f"PRIVATE-STRATEGY-{other}" not in user
                    for other in range(8)
                    if other != seat
                )
                metadata = row["observation"]["prompt_template"]
                assert metadata["variant"] == (
                    "reordered" if wording == "mixed" else wording
                )
                for role, value in [("system", system), ("user", user)]:
                    assert (
                        metadata[role + "_sha256"].lower()
                        == hashlib.sha256(value.encode()).hexdigest()
                    )
                for attempt in (1, 2):
                    identity = f"{turn}-{seat}-{attempt}"
                    start, finish = starts[identity], finishes[identity]
                    assert start["prompt"] == row["prompt"]
                    assert start["request"]["body"]["system"] == system
                    assert start["request"]["body"]["messages"] == row["prompt"][1:]
                    assert (
                        start["request"]["body"]["model"] == start["request"]["model"]
                    )
                    assert not finish["completed"] and finish["error"]
                    assert not resolutions[identity]["accepted"]
            raw = decompress((work / "episode.replay").read_bytes())
            assert b"PRIVATE-STRATEGY-" not in raw and b"prompt_template" not in raw
            reader = Reader(raw)
            assert reader.take(8) == MAGIC and reader.u16() == 1
            reader.text()
            reader.text()
            reader.u64()
            reader.text()
            hashes, inputs, directives = {}, [], []
            while reader.at < len(raw):
                kind = reader.u8()
                if kind == 1:
                    tick = reader.u32()
                    hashes[tick] = reader.u64()
                elif kind == 2:
                    inputs.append((reader.u32(), reader.u8(), reader.u8()))
                elif kind == 3:
                    reader.u32()
                    reader.u8()
                    reader.text()
                    reader.i16()
                    reader.text()
                elif kind == 4:
                    reader.u32()
                    reader.u8()
                elif kind == 5:
                    reader.u32()
                    reader.u8()
                    value = json.loads(reader.text())
                    if value["k"] == "directive":
                        directives.append(value)
                elif kind == 6:
                    reader.u32()
                    reader.u8()
                    reader.blob()
                else:
                    raise ValueError(kind)
            assert directives == [row["executed_action"] for row in decisions]
            executions = [
                json.loads(line)
                for line in (trace / "execution.jsonl").read_text().splitlines()
            ]
            assert executions[-1]["outcome"] == results
            masks, position = [0] * 22, 0
            for row in executions[:-1]:
                tick = row["tick"]
                while (
                    position < len(inputs)
                    and inputs[position][0] <= (tick - 1) * 1000 // 24
                ):
                    _, cog, action = inputs[position]
                    masks[cog] = action
                    position += 1
                assert row["actions"] == masks
                assert int(row["after_hash"]) == hashes[tick]
            with (work / "rehash.log").open("w") as log:
                subprocess.run(
                    [str(args.rehash), str(work / "episode.replay")],
                    cwd=root,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    check=True,
                    timeout=120,
                )
            print(
                variant,
                wording,
                expected,
                "decisions; requests, directives, actions and replay hashes PASS",
                flush=True,
            )
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=15)
            for log in logs:
                log.close()
            closed.close()


if __name__ == "__main__":
    main()
