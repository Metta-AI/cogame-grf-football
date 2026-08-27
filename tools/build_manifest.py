#!/usr/bin/env python3
"""Regenerate `coworld_manifest_template.json`.

`game.docs` must carry the README and the three doc pages as TEXT (the playbook
gotcha: `{"type":"text","value":…}`, never a URI), and hand-pasting four
markdown files into a JSON string is how they drift. This script inlines them
from the repo, so `tests/test_manifest.nim` asserting they are non-empty is
asserting something that stays true.

    python3 tools/build_manifest.py          # rewrite the template
    python3 tools/build_manifest.py --check  # fail if it is out of date
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "coworld_manifest_template.json")

SLUG = "grf-football"
IMAGE = "{{GRF_FOOTBALL_IMAGE}}"
REPO = "https://github.com/Metta-AI/cogame-grf-football"
SEATS = 8

SLOTS = [{"team": "red" if i % 2 == 0 else "blue"} for i in range(SEATS)]
NAMES = ["RED-10", "BLUE-10", "RED-9", "BLUE-9",
         "RED-7", "BLUE-7", "RED-6", "BLUE-6"]
PLAYERS = [{"name": n} for n in NAMES]


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as handle:
        return handle.read()


def text(value):
    return {"type": "text", "value": value}


def uri(value):
    return {"type": "uri", "value": value}


def per_seat(kind):
    return {"type": "array", "minItems": SEATS, "maxItems": SEATS,
            "items": {"type": kind}}


def per_team(kind):
    return {"type": "array", "minItems": 2, "maxItems": 2,
            "items": {"type": kind}}


VARIANT_BASE = {
    "players": PLAYERS,
    "slots": SLOTS,
    "num_agents": SEATS,
    "minPlayers": SEATS,
    "maxGames": 1,
    "turnTicks": 240,
    "turnBudgetMs": 10000,
    "attempt1Ms": 6000,
    "retryMs": 3000,
    "turnSpacingMs": 18000,
    "lobbyJoinTimeoutTicks": 1440,
    "startWaitTicks": 24,
    "gameOverTicks": 360,
    "mercyGoalDiff": 5,
    "restartTicks": 36,
    "stalemateTicks": 480,
    "fastMode": True,
    "showPlayerLabels": False,
}


def variant(vid, name, description, max_ticks, half_ticks, budget):
    config = dict(VARIANT_BASE)
    config["maxTicks"] = max_ticks
    config["halfTicks"] = half_ticks
    config["wallClockBudgetSeconds"] = budget
    return {"id": vid, "name": name, "description": description,
            "game_config": config}


manifest = {
    "game": {
        "name": SLUG,
        "owner": "daveey@gmail.com",
        "description": (
            "Eleven-a-side association football in a continuous 2D physics "
            "world: 22 cogs, one ball, throw-ins, corners and goal kicks. A "
            "policy is just a prompt — every ten seconds you issue ONE order "
            "for your shirt and a deterministic controller executes it."
        ),
        "runnable": {
            "type": "game",
            "image": IMAGE,
            "run": ["/bin/grf-football"],
            "env": {
                "ANTHROPIC_API_KEY_URI":
                    "secret://coworld/%s/anthropic_api_key" % SLUG
            },
            "source_url": REPO + "/tree/main",
        },
        "replay_viewer": {"bundle": "static-replay-viewer"},
        "protocols": {
            "player": uri(REPO + "/blob/main/docs/PROTOCOL.md"),
            "global": uri(REPO + "/blob/main/docs/PROTOCOL.md"),
        },
        "docs": {
            "readme": text(read("README.md")),
            "pages": [
                {"id": "rules.md", "title": "Rules",
                 "content": text(read("docs", "RULES.md"))},
                {"id": "protocol.md", "title": "Wire protocol",
                 "content": text(read("docs", "PROTOCOL.md"))},
                {"id": "coaching.md", "title": "Writing a grf-football prompt",
                 "content": text(read("docs", "COACHING.md"))},
            ],
        },
        "config_schema": {
            "type": "object",
            "additionalProperties": False,
            "required": ["tokens", "players"],
            "properties": {
                "tokens": {"type": "array", "minItems": SEATS,
                           "maxItems": SEATS,
                           "items": {"type": "string", "minLength": 1}},
                "players": {
                    "type": "array", "minItems": SEATS, "maxItems": SEATS,
                    "items": {"type": "object", "additionalProperties": False,
                              "properties": {"name": {"type": "string"}}}},
                "slots": {
                    "type": "array", "minItems": SEATS, "maxItems": SEATS,
                    "items": {"type": "object", "additionalProperties": False,
                              "properties": {"team": {
                                  "type": "string",
                                  "enum": ["red", "blue"]}}}},
                "closedRoster": {"type": "boolean", "default": False},
                "seed": {"type": "integer"},
                "num_agents": {
                    "type": "integer", "default": SEATS,
                    "description":
                        "seats; one seat is one outfield shirt for the match"},
                "minPlayers": {"type": "integer", "default": SEATS},
                "maxTicks": {
                    "type": "integer", "default": 5760,
                    "description": "24 ticks/second; 5760 = 4:00 of football"},
                "halfTicks": {
                    "type": "integer", "default": 2880,
                    "description": "half-time tick; ends are NOT swapped"},
                "maxGames": {"type": "integer", "default": 1},
                "turnTicks": {
                    "type": "integer", "default": 240,
                    "description": "ticks between decision turns (10.0 s)"},
                "turnBudgetMs": {"type": "integer", "default": 10000},
                "attempt1Ms": {"type": "integer", "default": 6000},
                "retryMs": {"type": "integer", "default": 3000},
                "turnSpacingMs": {
                    "type": "integer", "default": 18000,
                    "description":
                        "rate floor between batch starts; 0 disables it"},
                "wallClockBudgetSeconds": {
                    "type": "integer", "default": 690,
                    "description": "engine hard stop; yields reason 'deadline'"},
                "lobbyJoinTimeoutTicks": {"type": "integer", "default": 1440},
                "startWaitTicks": {"type": "integer", "default": 24},
                "gameOverTicks": {"type": "integer", "default": 360},
                "mercyGoalDiff": {"type": "integer", "default": 5},
                "restartTicks": {
                    "type": "integer", "default": 36,
                    "description": "dead-ball ticks on every restart"},
                "stalemateTicks": {
                    "type": "integer", "default": 480,
                    "description": "parked-ball ticks before the neutral drop"},
                "fastMode": {"type": "boolean", "default": True},
                "showPlayerLabels": {"type": "boolean", "default": False},
                "speed": {"type": "integer", "default": 1},
                "model": {"type": "string",
                          "default": "claude-haiku-4-5-20251001"},
                "maxOutputTokens": {"type": "integer", "default": 900},
                "baseSpeed": {"type": "integer", "default": 250000},
                "sprintSpeed": {"type": "integer", "default": 337500},
                "shotSpeed": {"type": "integer", "default": 1083333},
                "shortPassSpeed": {"type": "integer", "default": 583333},
                "longPassSpeed": {"type": "integer", "default": 916666},
            },
        },
        "results_schema": {
            "type": "object",
            "additionalProperties": False,
            "required": ["names", "scores", "win", "team", "reason",
                         "endRule"],
            "properties": {
                "names": per_seat("string"),
                "scores": per_seat("number"),
                "win": per_seat("boolean"),
                "team": per_seat("string"),
                "shirt": per_seat("integer"),
                "goals": per_seat("integer"),
                "assists": per_seat("integer"),
                "passes": per_seat("integer"),
                "passesCompleted": per_seat("integer"),
                "shots": per_seat("integer"),
                "tackles": per_seat("integer"),
                "fouls": per_seat("integer"),
                "llmTurns": per_seat("integer"),
                "fallbackTurns": per_seat("integer"),
                "teamGoals": per_team("integer"),
                "teamShots": per_team("integer"),
                "teamShotsOnTarget": per_team("integer"),
                "teamPossessionTicks": per_team("integer"),
                "reason": {"type": "string",
                           "enum": ["complete", "deadline", "fault"]},
                "endRule": {"type": "string",
                            "enum": ["full_time", "mercy", "wall_clock",
                                     "sim_fault", "host_error"]},
                "finalTick": {"type": "integer"},
                "seed": {"type": "integer"},
            },
        },
    },
    "tags": ["football", "soccer", "physics", "team", "gfootball", "llm"],
    "player": [
        {
            "id": "baseline",
            "name": "GRF Football Zonal Baseline",
            "description": (
                "The bundled certification seat: registers as the scripted "
                "`zonal` baseline (hold the zone, support the ball, press when "
                "it is close, go and win a loose ball) so an episode always "
                "completes without LLM credentials."
            ),
            "type": "player",
            "image": IMAGE,
            "run": ["/bin/grf-football-player"],
            "env": {"PLAYER_SCRIPTED": "zonal"},
            "source_url": REPO + "/tree/main",
            "resources": {
                "requests": {"cpu": "100m", "memory": "64Mi"},
                "limits": {"cpu": "1"},
            },
        }
    ],
    "variants": [
        variant("match", "Match (8 seats, 11 v 11, 4:00)",
                "The full match: eight seats over 22 cogs, 5760 ticks (4:00) "
                "in two halves, played as 24 decision turns of 10 s.",
                5760, 2880, 690),
        variant("half", "Half (8 seats, 11 v 11, 2:00)",
                "The short match for cheap ladder rounds: the same eight "
                "seats, 2880 ticks (2:00) played as 12 decision turns of 10 s. "
                "It changes only match length, never the seat count.",
                2880, 1440, 400),
    ],
    "certification": {
        "players": [{"player_id": "baseline"} for _ in range(SEATS)],
        "game_config": {
            "players": [{"name": "Zonal %d" % (i + 1)} for i in range(SEATS)],
            "slots": SLOTS,
            "num_agents": SEATS,
            "minPlayers": SEATS,
            "seed": 679961,
            "maxTicks": 1440,
            "halfTicks": 720,
            "maxGames": 1,
            "turnTicks": 240,
            "turnBudgetMs": 10000,
            "turnSpacingMs": 0,
            "wallClockBudgetSeconds": 180,
            "lobbyJoinTimeoutTicks": 720,
            "fastMode": True,
        },
    },
}

rendered = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"

if "--check" in sys.argv:
    current = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
    if current != rendered:
        sys.exit("coworld_manifest_template.json is stale: "
                 "run python3 tools/build_manifest.py")
    print("manifest up to date")
else:
    with open(OUT, "w", encoding="utf-8") as handle:
        handle.write(rendered)
    print("wrote %s (%d bytes)" % (OUT, len(rendered)))
