## Roster machinery: slot identities and limits, join/auth resolution, reward
## accounts, addPlayer/removePlayerAt, and `playerResultsJson`. Kept in ctf's
## shape; the sole runtime consumer beyond the sim loop is server.nim.
##
## The results document must equal the manifest's `results_schema` KEY FOR KEY:
## that schema is `additionalProperties: false` and the certifier rejects any
## unknown field, so adding or removing a key here means editing
## coworld_manifest_template.json in the same commit — tests/test_manifest.nim
## fails until they agree.

import
  std/json,
  sim

proc canAddPlayer*(sim: SimServer): bool {.inline.} =
  sim.players.len < MaxPlayers

proc nextPlayerSlot*(sim: SimServer): int {.inline.} =
  ## Joins are strictly slot-sequential, so the seat a lobby is stuck waiting
  ## on is exactly this.
  sim.players.len

proc slotOfAddress(sim: SimServer, address: string): int =
  for i, player in sim.players:
    if player.address == address:
      return i
  -1

proc resolvePlayerSlot*(
  sim: SimServer,
  address: string,
  token: string,
  requestedSlot: int
): int =
  ## Where a pending connection wants to sit. An explicit slot wins; a token
  ## that matches a configured slot comes next; otherwise the next free seat.
  if requestedSlot >= 0 and requestedSlot < MaxPlayers:
    return requestedSlot
  if token.len > 0:
    for i, entry in sim.config.slots:
      if entry.token.len > 0 and entry.token == token:
        return i
  let existing = sim.slotOfAddress(address)
  if existing >= 0:
    return existing
  sim.nextPlayerSlot()

proc rewardAccountFor*(sim: var SimServer, address: string): int =
  for i in 0 ..< sim.rewardAccounts.len:
    if sim.rewardAccounts[i].address == address:
      return i
  sim.rewardAccounts.add RewardAccount(
    address: address, slotIndex: int32(sim.rewardAccounts.len))
  sim.rewardAccounts.len - 1

proc addPlayer*(
  sim: var SimServer,
  address: string,
  requestedSlot: int,
  token: string,
  trusted = false
): int =
  ## Seats one connection. The SEAT is a property of the SLOT, never of the
  ## connection order, so a replay re-seats exactly as the live match did, and
  ## seat parity is the team.
  if sim.players.len >= MaxPlayers:
    raise newException(GrfFootballError, "match is full")
  let slot = sim.players.len
  if not trusted and requestedSlot >= 0 and requestedSlot != slot:
    raise newException(GrfFootballError,
      "player slot " & $requestedSlot & " is not the next open seat")
  var team = teamOfSeat(slot)
  if slot < sim.config.slots.len and sim.config.slots[slot].hasTeam:
    team = sim.config.slots[slot].team
  let player = Player(
    address: address,
    joinOrder: int32(slot),
    seat: int32(slot),
    team: team,
    shirt: SeatShirt[slot],
    policyLabel: policyName(address),
    policyKind: pkScripted,
    baseline: "zonal"
  )
  sim.players.add(player)
  let account = sim.rewardAccountFor(address)
  sim.rewardAccounts[account].team = team
  sim.rewardAccounts[account].hasSeat = true
  sim.nextJoinOrder = int32(sim.players.len)
  sim.logGameEvent("player joined: " & address & " as " &
    cogId(cogOfSeat(slot)))
  discard token
  slot

proc removePlayerAt*(sim: var SimServer, index: int) =
  ## Removes a roster entry. THE 22 COGS ARE NOT TOUCHED: they are fixed for
  ## the whole match, so unlike ctf (a per-player game) nothing renumbers when
  ## a seat leaves — see the second named edit in replays.nim.
  if index < 0 or index >= sim.players.len:
    return
  sim.logGameEvent("player left: " & sim.players[index].address)
  sim.players.delete(index)

proc recordGameAbandon*(sim: var SimServer, index: int) =
  if index < 0 or index >= sim.players.len:
    return
  let account = sim.rewardAccountFor(sim.players[index].address)
  sim.rewardAccounts[account].abandoned = true

proc playerForSeat*(sim: SimServer, seat: int): int =
  for i, player in sim.players:
    if int(player.seat) == seat:
      return i
  -1

proc roundDiv(a, b: int): int {.inline.} =
  ## Round-half-away-from-zero integer division; symmetric under negation, so
  ## the two teams' permille scores always sum to exactly 1000.
  if a >= 0: (2 * a + b) div (2 * b)
  else: -((2 * -a + b) div (2 * b))

proc scorePermille*(sim: SimServer, seat: int): int =
  ## `0.5 + 0.5 * clamp(gd / 3, -1, +1)`, in permille so the pair is exactly
  ## complementary. Higher is better; 3-0 or better = 1000, any draw = 500.
  if sim.endReason == reasonFault:
    return 500
  500 + clamp(roundDiv(sim.goalDiff(teamOfSeat(seat)) * 500, 3), -500, 500)

proc seatWon*(sim: SimServer, seat: int): bool {.inline.} =
  sim.endReason != reasonFault and sim.goalDiff(teamOfSeat(seat)) > 0

proc seatName*(sim: SimServer, seat: int): string =
  ## The REAL policy name (spectator side). Falls back to the configured slot
  ## name, then to the shirt alias, so results are never empty.
  let index = sim.playerForSeat(seat)
  if index >= 0 and sim.players[index].address.len > 0:
    return sim.players[index].address
  if seat < sim.config.slots.len and sim.config.slots[seat].name.len > 0:
    return sim.config.slots[seat].name
  cogId(cogOfSeat(seat))

proc playerResultsJson*(sim: SimServer): string =
  ## The results artifact. Exactly the keys the manifest's `results_schema`
  ## declares: per-seat arrays of length eight in seat order, team arrays of
  ## length two in `[red, blue]` order.
  var
    names = newJArray()
    scores = newJArray()
    win = newJArray()
    team = newJArray()
    shirt = newJArray()
    goals = newJArray()
    assists = newJArray()
    passes = newJArray()
    passesCompleted = newJArray()
    shots = newJArray()
    tackles = newJArray()
    fouls = newJArray()
    llmTurns = newJArray()
    fallbackTurns = newJArray()
  for seat in 0 ..< SeatCount:
    let index = cogOfSeat(seat)
    names.add(%sim.seatName(seat))
    scores.add(%(float(sim.scorePermille(seat)) / 1000.0))
    win.add(%sim.seatWon(seat))
    team.add(%teamText(teamOfSeat(seat)))
    shirt.add(%int(SeatShirt[seat]))
    goals.add(%int(sim.cogStats[index].goals))
    assists.add(%int(sim.cogStats[index].assists))
    passes.add(%int(sim.cogStats[index].passes))
    passesCompleted.add(%int(sim.cogStats[index].passesCompleted))
    shots.add(%int(sim.cogStats[index].shots))
    tackles.add(%int(sim.cogStats[index].tackles))
    fouls.add(%int(sim.cogStats[index].fouls))
    llmTurns.add(%int(sim.seatStats[seat].llmTurns))
    fallbackTurns.add(%int(sim.seatStats[seat].fallbackTurns))
  var
    teamGoals = newJArray()
    teamShots = newJArray()
    teamSot = newJArray()
    teamPossession = newJArray()
  for t in Team:
    teamGoals.add(%int(sim.teamStats[t].goals))
    teamShots.add(%int(sim.teamStats[t].shots))
    teamSot.add(%int(sim.teamStats[t].shotsOnTarget))
    teamPossession.add(%int(sim.teamStats[t].possessionTicks))
  $(%*{
    "names": names,
    "scores": scores,
    "win": win,
    "team": team,
    "shirt": shirt,
    "goals": goals,
    "assists": assists,
    "passes": passes,
    "passesCompleted": passesCompleted,
    "shots": shots,
    "tackles": tackles,
    "fouls": fouls,
    "llmTurns": llmTurns,
    "fallbackTurns": fallbackTurns,
    "teamGoals": teamGoals,
    "teamShots": teamShots,
    "teamShotsOnTarget": teamSot,
    "teamPossessionTicks": teamPossession,
    "reason": reasonText(sim.endReason),
    "endRule": endRuleText(sim.endRule),
    "finalTick": sim.tickCount,
    "seed": sim.config.seed
  })

proc resultRecordJson*(sim: SimServer): string =
  ## The `result` replay chat record: the full results document, written once
  ## at game over so `tools/replay_summary.py` can report the outcome from the
  ## bytes alone.
  $(%*{"k": "result", "results": parseJson(sim.playerResultsJson())})
