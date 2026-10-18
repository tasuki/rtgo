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
- `DT[YYYY-MM-DD]`: the game's start date in **UTC**, also used in its filename.
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
- Cooldowns are positive integer **milliseconds**, including per-player handicaps.
  They apply before the first move as well as after each successful placement;
  move timestamps are measured from game start, including that opening wait.
- `RTEND[ms]`: optional elapsed time when everyone passed. Absent means an
  unfinished recording, not a draw. Automatic passing isn't a move; we do not
  invent alternating turns or insert synthetic passes.
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
metadata in the replay, not wall-clock waits. At the last position the UI can
show the recorded scoring exclusions and area shading; earlier positions show
only the actual played board.

## Persistence and replay

`SGF_DIR` selects the server directory (default `data/sgf`, relative to the server
working directory; the container uses `/data/sgf`). Startup checks writability.
Each started game gets `YYYY-MM-DD-<room-id>.sgf`, for example
`2026-10-18-four.sgf`. The UTC start date is fixed for all subsequent saves and
downloads, even if play/scoring crosses midnight. Archive lookup accepts only
this date-prefixed format; room/replay URLs still use just the game code.
A per-game recorder process writes a complete snapshot to
`YYYY-MM-DD-<room-id>.sgf.tmp`, then atomically renames it, at start,
after each accepted move, at finish, and after scoring. Rejections and polls do
not add moves. Temporary files are not recordings. Write failures are logged;
the previous complete snapshot remains usable. Writes are asynchronous, so an
abrupt kill can lose the latest queued updates; this is not a synchronous WAL or
a power-loss durability guarantee.

Mount `/data` as a named volume or writable host directory to survive container
replacement. Saved recording IDs are not reused after restart. Live rooms
and account sessions are still in memory; recordings do not restore games.

- `GET /api/games/<id>/sgf` downloads the current in-memory recording or a saved
  file after restart. Standalone development also supports the unprefixed route.
- Finished games offer **Replay game** and **Download SGF** in their game/result
  menu panels. `/replay/<id>` fetches a recording and opens the replay viewer.
- `/replay` accepts a pasted SGF, entirely client-side. It supports our version-1
  recordings, not arbitrary third-party Go SGFs, setup stones, variations, or
  collections. Unsupported/malformed input is rejected, not silently flattened.
- The viewer has Start, Previous, Next, End, and a move slider; it displays the
  move's player, coordinate, and timestamp, the roster/handicaps, and recorded
  final scores. Empty and interrupted recordings are replayable too.

The importer limits input to 1 MB and 10,000 moves, rejects duplicate properties,
invalid rosters/coordinates, unknown seats, decreasing timestamps and illegal
moves. A replay URL loads once; if opened while scoring is pending, reload it
later to fetch the scored recording.
