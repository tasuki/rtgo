# RTGO SGF recordings — version 1

RTGO writes UTF-8 SGF FF[4] files. SGF is the canonical recording, not a JSON
wrapper. Multiplayer uses **private uppercase SGF properties**. This is valid SGF
syntax, but it is not a standardized multiplayer Go format. Ordinary Go viewers
cannot replay the extra colors. `GM[1]` identifies the Go family; `RU` describes
RTGO's custom rules, not tournament Go.

```sgf
(;FF[4]CA[UTF-8]GM[1]AP[RTGO:1]SZ[19]DT[2026-10-18]
RU[RTGO positional superko; no suicide; area; no komi]RTFORMAT[1]
RTPLAYER[p1:Alice:black:1000][p2:Bob:white:2000][p3:Carol:cyan:1000]
RTEND[14000]RTSCORING[unassisted]RTSCORE[p1:1][p2:1][p3:1]
;RTMOVE[p3:dd]RTTIME[1250]
;RTMOVE[p1:pq]RTTIME[1420]
;RTMOVE[p2:dp]RTTIME[2000]
)
```

## Root node

- `RTFORMAT[1]`: required extension version.
- `RTTIMING[json]`: optional timing metadata, encoded as a single SGF-escaped JSON
  value. Missing means legacy strict cooldown (Crazy Cooldown). Its object has
  `mode` (`crazy_cooldown`, `cushy_cooldown`, `stone_savings`, or `drag_derby`)
  and `gain_move_seconds` (the base interval, zero for Drag Derby). Stone Savings
  additionally requires `max_moves` and `minimum_gap_ms`. Cushy Cooldown's credit
  cap is fixed at 25% of each player's interval. Unknown modes and invalid
  parameters are rejected, not silently treated as strict cooldown.
  This additive metadata does not change the sequential move-node contract;
  Simul Slaughter will require a separate, explicitly agreed recording design.
- `DT[YYYY-MM-DD]`: the game's start date in **UTC**. The filename additionally
  includes the UTC start hour and minute; `DT` remains date-only.
  Date metadata does not affect move playback.
- `SZ[n]`: square board size. Production creates 9, 13, or 19; the importer
  accepts 2–25.
- `RTPLAYER[id:name:color:cooldown]...`: one value per player, **all four fields
  together**. A four-field value is our private grammar, not SGF's standard
  two-part Compose type. IDs are game-local lowercase ASCII letters/digits
  (`p1`, `p2`, …), assigned by username sort at start and never changed. The
  name and color are snapshots, not authentication identifiers. There are 2–8
  unique IDs, names, and colors.
- Colors are RTGO's canonical names: `black`, `white`, `cyan`, `green`, `orange`,
  `pink`, `purple`, `blue`.
- Cooldowns are integer **milliseconds**, including per-player handicaps.
  They are positive for cooldown/banking modes and zero only for Drag Derby.
  In Crazy Cooldown they apply before the first move and after each placement.
  In Cushy Cooldown they describe the full interval before readiness credit; in
  Stone Savings they describe the base recharge interval. Drag Derby has no
  opening wait or timing handicap. Move timestamps are measured from game start,
  including any opening wait.
- `RTEND[ms]`: optional elapsed time when everyone passed. Absent means an
  unfinished recording, not a draw. Neither explicit nor automatic passing is a
  placement; we do not invent alternating turns or insert synthetic pass moves.
  Intermediate pass/resume status is not replayed; the final end time is retained.
- `RTSCORING[pending|estimated|unassisted]`: whether final scoring is available
  and whether KataGo estimated dead stones. `pending` also covers active games
  and games whose final scoring was interrupted.
- `RTSCORE[id:integer]...`: final area scores, including zeroes for every player.
- `RTDEAD[xy]...`: estimated dead stones on the **actual final board**. Omitted
  if none. This is scoring metadata; it does not alter the move history.
- Two-player black/white recordings additionally have standard `PB` and `PW`.

Private fields preserve names as text (including literal newlines). Escape `\`
as `\\`, `]` as `\]`, and a literal colon as `\:`. **Split fields before
unescaping**, or `Alice\:Bob` would be read as two fields. An escaped line break
is a continuation and is removed. Other unknown properties can be ignored.
Names are never interpreted as markup or used as file paths.

## Move nodes

`;` starts a **node**, not necessarily a move in SGF generally. Our writer puts
all roster/result metadata in the root and one accepted move in each subsequent
node, in authoritative server order:

- `RTMOVE[id:xy]`: seat and zero-based SGF coordinate. `aa` is the top-left,
  first letter is column, second is row. No pass moves are written.
- `RTTIME[ms]`: nonnegative integer milliseconds since game start, monotonically
  nondecreasing. Equal timestamps are resolved by node order.
- Two-player black/white games also include `B[xy]` or `W[xy]` in the same node.
  Consecutive moves by the same color are intentional. The `RTMOVE` property is
  authoritative for RTGO readers; do not replay both properties as two moves.

The empty board is position zero. Replaying uses RTGO's shared multiplayer Go
rules to reconstruct captures and enforce suicide/positional superko. Captures
are not flattened into a black/white approximation. Cooldowns are descriptive
metadata in the replay; realtime playback follows the recorded move timestamps,
not a reconstruction of cooldown timers. At the last position the UI can
show the recorded scoring exclusions and area shading; earlier positions show
only the actual played board.

## Persistence and replay

`SGF_DIR` selects the server directory (default `data/sgf`, relative to the server
working directory; the container uses `/data/sgf`). Startup checks writability.
Each started game gets `YYYY-MM-DD-HHMM-<room-id>.sgf`, for example
`2026-10-18-1234-four.sgf`. The UTC start time, to the minute, is fixed for all
subsequent saves and downloads, even if play/scoring crosses midnight. Archive
lookup accepts only this timestamp-prefixed format, not date-only filenames;
game URLs still use just the game code. The lobby displays UTC start dates and
lists finished games newest first, 20 per page, with Previous/Next controls.
In-memory games use their full start timestamp; archived games use the filename's
UTC start minute. Open and running rooms remain visible on every page.
A per-game recorder process writes a complete snapshot to
`YYYY-MM-DD-HHMM-<room-id>.sgf.tmp`, then atomically renames it, at start,
after each accepted move or explicit pass, at finish, and after scoring. Rejections and polls do
not add moves. Temporary files are not recordings. Write failures are logged;
the previous complete snapshot remains usable. Writes are asynchronous, so an
abrupt kill can lose the latest queued updates; this is not a synchronous WAL or
a power-loss durability guarantee.

Mount `/data` as a named volume or writable host directory to survive container
replacement. Saved recording IDs are not reused after restart. Live rooms
and account sessions are still in memory; recordings do not restore games.
The lobby merges saved finished recordings with in-memory games, preferring
memory for duplicate IDs. Missing, malformed, temporary, and interrupted files
are skipped. Archives are loaded on demand, without starting game actors.
`GET /api/games?page=0` (zero-based, default 0) returns all active rooms plus up
to 20 finished games, with `has_more` indicating another finished-games page.
Game metadata includes nullable `started_at` in RFC 3339 (null for unstarted rooms).
Opening an archived game falls back to its SGF when no in-memory room exists.

- `GET /api/games/<id>/sgf` downloads the current in-memory recording or a saved
  file after restart. Standalone development also supports the unprefixed route.
- Finished games automatically become fullscreen replays at `/play/<id>`, starting
  at the final position. This also works for archived recordings after restart.
  **Download SGF** stays in the game/result menu panels.
- The lobby's **Import an SGF recording** accepts a pasted SGF, entirely client-side,
  and opens it on the same fullscreen board. It supports our version-1
  recordings, not arbitrary third-party Go SGFs, setup stones, variations, or
  collections. Unsupported/malformed input is rejected, not silently flattened.
- Replays share the live game's fullscreen board. The opposite-side control strip
  is vertical on the right in landscape, horizontal at the bottom in portrait.
  It has a move slider and Start, Previous, Play/Stop, Next, End buttons. Playback
  uses original timestamps, including simultaneous moves, and stops at the end.
  Playing from the end restarts at position zero; seeking stops playback.
  Left/right arrows step through moves; Space plays/pauses, including when the
  move slider is focused. Shortcuts do not override text editing or native Space
  activation on buttons/links.
- The slider describes the move's player, coordinate, and timestamp; the general
  menu holds timing parameters, roster/handicaps, and recorded final scores.
  Empty and interrupted recordings are replayable too.

The importer limits input to 1 MB and 10,000 moves, rejects duplicate properties,
invalid rosters/coordinates, unknown seats, decreasing timestamps and illegal
moves. Finished live rooms continue polling while scoring is pending, refreshing
the replay's scoring metadata without changing the playback position.
