# Time systems — design notes

**Status:** Crazy Cooldown, Cushy Cooldown, Stone Savings, and Drag Derby are
implemented, with a timing picker in game setup. Simul Slaughter remains a design
for later implementation and is disabled in the picker. The picker keeps the
least-crazy-to-craziest order below.

These are different game modes, not necessarily successive improvements to one
mode. Strict cooldown remains a first-class option rather than being replaced.
The discussion applies to individual players, including games with more than two
players. **Team play and shared team reserves are out of scope.**

From least crazy to craziest:

1. **Crazy Cooldown** — strict cooldown, the sensible baseline.
2. **Cushy Cooldown** — cooldown with limited timing forgiveness.
3. **Stone Savings** — bank moves, with diminishing returns on saving.
4. **Simul Slaughter** — hidden simultaneous choices; same-point collisions boom.
5. **Drag Derby** — unlimited placement attempts while dragging across the board.

## Motivation

The strict cooldown game has a clear rhythm: placing a stone commits you to a period in
which you cannot respond. However, losing a race for an important intersection
can impose two disadvantages:

1. The opponent gets the point.
2. Noticing the collision and choosing a replacement delays your successful
   placement, and therefore your next cooldown cycle.

Rejected moves already consume no cooldown. The second disadvantage is lost
reaction/decision time, not an extra cooldown charged for an invalid move.

To avoid an immediate opening race favouring the host or whoever first receives
the started position, cooldown-mode players start on their full configured
cooldown, including handicaps. Opening premoves can be queued during that cooldown. The
ten-second inactivity/pass window begins only once the player becomes ready.
Crazy Cooldown and Cushy Cooldown use this opening cooldown. Stone Savings
starts with an empty bank and earns its first stone after the player's full base
interval. Drag Derby is ready immediately; Simul Slaughter's opening remains open.

## Passing — all implemented modes

- A player can explicitly **Pass** once ready. The server applies the same
  readiness check as for placement, including opening waits and banking gaps.
- Passing does not reset readiness, spend or grant credits, or place a stone.
  Repeated explicit passes are idempotent.
- A successful legal placement clears that player's pass. Resuming still obeys
  the mode's timing rules; rejected placements do not clear a pass.
- Once everyone is passing, the game finishes and cannot be resumed.
- Crazy Cooldown, Cushy Cooldown, and Drag Derby also retain automatic passing
  after ten seconds of readiness without a successful placement.
- Stone Savings uses explicit passing only: intentional saving must not trigger
  automatic passing. This also means a disconnected banking player does not
  automatically pass. Disconnect handling is future work.
- Bots explicitly pass when the engine chooses to pass, and may play again if
  the position changes before the game ends.

## 1. Crazy Cooldown — the strict baseline

- A successful placement starts that player's full configured cooldown.
- The player cannot place another stone until it expires.
- Waiting after becoming ready does not earn extra moves or shorten the next
  cooldown.
- Rejected placements do not consume a cooldown.
- Before the first move, everyone waits their full configured cooldown, including
  any per-player handicap. Opening premoves are allowed.
- The opening pass deadline is the initial cooldown plus ten seconds, just as
  after subsequent successful moves.

**Character:** continuous pressure, readable response windows, and a reliable
minimum gap between a player's stones. Acting promptly matters. This is the
preferred baseline and should remain available unchanged as a mode.

## 2. Cushy Cooldown — cooldown with limited slack

Retain a cooldown-like rhythm, but make a short hesitation or lost-point retry
less costly. This mode uses **limited readiness credit**, not a small bank.

- Once a player is ready, retain a capped amount of elapsed ready time toward
  their next cooldown.
- Credit is earned by being ready, not by making rejected attempts. Deliberately
  clicking occupied points must not generate special refunds.
- Credit is capped at **25% of that player's configured cooldown**, including
  handicaps. Every accepted placement therefore leaves at least 75% of the
  configured cooldown before the next one.
- This is limited timing slack, not a bank of several playable stones.
- Credit starts only after opening readiness, never during the opening wait.

Example: a player becomes ready at 10s, loses a contested point, and successfully
plays elsewhere at 11.5s. With a 5s cooldown, credit is capped at 1.25s, so the
next ready time is 15.25s instead of 16.5s.

This relaxes the strict rule that every successful placement is followed by the
full cooldown. It cannot erase the tactical disadvantage of losing the
intersection; it only limits the subsequent timing disadvantage.

## 3. Stone Savings — banking with diminishing returns on saving

- Start empty. Waiting earns move credits; each successful placement spends one.
- With `n` stones already saved, the next costs `(n + 1)` base intervals. From an
  empty bank, earning successive stones therefore takes 1×, 2×, 3×… the player's
  base interval. Longer per-player intervals provide timing handicaps.
- Spending preserves the **fraction** of progress toward the next stone,
  recalculated at the new recharge rate (rounded down to whole milliseconds).
- The host configures a reserve cap of **1–20 stones** and a minimum placement
  gap of **0 up to one base interval**, in milliseconds. The setup form initially
  offers a five-stone reserve and a 1000ms gap; these are tuning defaults, not
  claims about balance. The base interval defaults to five seconds.
- A full bank stops recharging; time beyond the cap is not stored.
- The minimum placement gap applies even with credits available. Rejected moves
  spend nothing and do not restart the gap.
- Saving never automatically passes the player. Use the explicit Pass action.

**Character:** waiting becomes a strategic investment. A player can trade present
board influence for a future combination, but large reserves are expensive.

### Burst risk and possible constraints

Unrestricted banking can encourage everyone to save up and then execute a
prepared sequence as fast as possible. Five uninterrupted moves can kill groups
that would be safe under cooldown rules. This may reward execution speed more
than intended.

Diminishing returns discourage hoarding, but do not alone prevent instant bursts.
The configurable reserve cap and minimum placement gap constrain this. Setting
the gap to zero deliberately allows immediate bursts. An interruptible sequence
executed at a fixed pace remains a possible future mechanic, not an implemented
feature.

While one player saves, opponents can claim space and force defensive spending.
That is a natural cost, but it should not be assumed to balance powerful Go
combinations without playtesting.

## 4. Simul Slaughter — simultaneous rounds (deferred)

This mode is not implemented. Its capture, suicide, and superko resolution rules
need further agreement before implementation.

Players choose privately during a round. At a shared server-authoritative tick,
choices are locked/resolved and the round's results are revealed together.
Opponents must not learn a choice before that reveal.

This is distinct from simply giving everyone permission to play on shared beats:
if moves become visible immediately within the interval, players can still react
to them and arrival order can still decide contested points. Hidden choices with
a common reveal are the defining feature of simultaneous rounds.

### Agreed same-intersection collision rule

When two or more players choose the same intersection:

- All those placements fail; no stone from those choices is placed there.
- Each involved player spends their action for that round.
- There is no replacement attempt in that round, no priority based on arrival
  order, and no extra penalty in the following round.
- A small, brief **“boom” animation appears on that intersection at the reveal
  tick, at the same time as the other stones are revealed**. It must not appear
  on submission or as an early acknowledgement.
- All viewers see the collision as part of that round's result. The effect means
  “the move registered but collided,” not “the click was dropped.”

For an intersection that was empty before the round, colliding choices leave it
empty. This rule concerns competing choices of an otherwise available point;
it does not yet define how an already-occupied or otherwise illegal choice is
handled.

Predicting another player's choice can therefore block it without occupying the
point. Repeated collisions may keep a critical point empty. Accept this as part
of the initial design rather than inventing an unagreed random winner or
alternating-priority tie-breaker.

### Resolution questions still open

Same-point collisions are settled above, but **different-point choices can still
interact through captures, suicide, and superko**. These need an explicit
simultaneous-resolution rule. Do not silently resolve them in player/request
order and call that simultaneous: it can reintroduce an ordering advantage.

Also decide before implementation:

- Round duration and opening behaviour.
- Whether a private choice can be changed or withdrawn before the tick, and
  exactly when submissions are locked.
- Treatment of occupied points and choices that become illegal during joint
  resolution.
- Missing submissions, deliberate passes, disconnects, and game-end detection.
- Whether/how per-player timing handicaps work with a shared round duration.
- The animation's appearance and duration; it should be short and local, not
  delay the next round or obscure the resulting position unnecessarily.

## 5. Drag Derby — unlimited placements

Click and drag across the board to send placement attempts immediately as the
pointer moves. There is no cooldown, move-credit cost, or timing-imposed minimum
gap between placements. This is a separate timing mode, not just a drag input
method for spending banked moves.

Unlimited attempts do not bypass board legality: the server still decides which
placements are accepted.

**Character:** paint the board. Execution speed and contested-point races are
part of the chaos.

- Players are ready immediately, with no timing handicaps.
- Mouse, pen, and touch pointer gestures send cells crossed by the pointer path,
  including intermediate cells skipped between browser pointer events.
- Consecutive attempts on the same cell are suppressed. Leaving and revisiting
  it creates a fresh attempt. Server board legality still applies.
- Requests are sent without waiting for earlier HTTP responses. The server's
  acceptance order is authoritative, and stale responses cannot roll back the
  displayed board.
- Bots are eligible to think whenever ready, but engine/network speed still
  limits them; unlimited timing does not promise unlimited bot throughput.
- Explicit passing and the ten-second readiness timeout apply as described above.

## Future work and cross-mode requirements

- Playtest timing defaults, especially the Stone Savings cap and placement gap.
- Keep timing and action acceptance authoritative on the server. Client effects
  display outcomes; animation completion must not determine legality or timing.
- Explain each mode's resource and timing clearly in the UI. Do not present a
  bank as though it were a strict cooldown.
- Simultaneous rounds need their own agreed inactivity/pass semantics and
  disconnect handling. Stone Savings also needs a deliberate disconnect policy
  that does not mistake intentional saving for inactivity.
- Adapt premoves, bot scheduling, and handicaps to the selected mode rather than
  assuming the current readiness rules still apply.
- The [SGF format](sgf.md) records accepted placements in server order, the timing
  mode and parameters, and per-player base intervals. Legacy recordings without
  timing metadata remain strict cooldown games. For future simultaneous rounds,
  preserve round boundaries and collisions so replay can reproduce both the
  position and the tick-time boom effects. Do not encode a collision as a stone
  that was actually placed or invent a meaningful order for simultaneous moves.
- Do not encode simultaneous rounds using the sequential recording contract or
  silently choose an unresolved simultaneous capture rule just to ship the mode.
