# Real Time GO

> Never lose on time again.


## Setup

One needs [mise](https://mise.jdx.dev/). I used `2025.4.1`.

```
mise install
```

Create `mise.local.toml`:

```
[env]
SECRET_KEY_BASE = "dev"
SIGN_KEY = "this.one.should.be.rather.very.long"
```

## Develop

```
mise run dev
```

## Try the lobby

Choose a name and create a two-player (black/white) or multiplayer (up to eight
colors) game. Pick a 9×9, 13×13 or 19×19 board and a 1–60 second cooldown. Share
its `/play/...` URL so other browser profiles or private windows can join. The
host can start once at least two players have joined. Click or tap an empty
intersection to play; keyboard users can focus a point and press Enter or Space.
Everyone starts ready and can move independently (there are no alternating turns).
The server serializes moves, applies captures and positional superko, and enforces
each player's cooldown. Rejected moves do not consume a cooldown. Boards refresh
every 250ms; spectators can watch but cannot move.

The board fills the largest possible viewport square. Navigation, player status,
game details and scores live in the circles along the left (landscape) or top
(portrait); hover for details, or click/tap/keyboard-activate a circle to pin its
panel open. Your timer is mirrored as two plain black 5px bars along opposite board
edges: left/right in landscape, top/bottom in portrait. They show only your cooldown
and disappear as soon as you can play. No pass countdown or opponent bars are shown;
spectators see none.
The board never shrinks to make room for them.

While waiting, guests can **Leave game**, freeing their seat and color, and
rejoin later. Only the host can **Cancel game**, removing the room for everyone.
The host must cancel rather than leave. These actions are rejected after start;
**Back to lobby** is only navigation and does not relinquish a seat.

The waiting-room host can also **Kick** guests (blocking that identity from
rejoining the room) and edit the cooldown for any player, including themselves.
Cooldown edits save when the field loses focus or Enter is pressed; there is no
separate save button. Invalid or failed edits stay visible with an error, and a
start/kick/cancel click waits for an in-progress save rather than discarding it.
A player's cooldown may range from the game's base cooldown up to 3600 seconds;
setting it back to the base removes the handicap. Longer waits handicap stronger
players, rather than giving a move deadline. Everyone can see these settings,
and leaving/rejoining does not reset them. They are enforced when the game starts.
Kicking and editing cooldowns are only allowed before start.

### Automatic passing and scoring

There is no Pass button. A player is **passing** after 10 seconds of being ready
without making a successful move. Initially everyone has a 10-second opening
window. After a move, that player's pass deadline is their cooldown **plus 10
seconds**, so a long cooldown cannot end the game before they can move again.
A passing player may resume while anyone else is still active. The server ends
the game permanently once everyone is passing, even if browsers disconnect.
Invalid moves, polling and reconnecting do not reset these deadlines. The board
shows each player's readiness/pass countdown and the time until everyone passes.

Final scoring uses **area**: stones on the board plus empty regions bordered by
exactly one player's stones. Mixed-color borders and unclaimed space are neutral;
there is no komi. Highest score wins, with ties allowed. **Capture dead stones
before stopping**; there is no dead-stone adjudication or resume-after-finish yet.

The lobby and waiting room refresh automatically every second. Finished games
remain accessible at their room URL. State is currently in memory and disappears
on server restart.

## Test

```
mise run test
```

Runs shared rules, server/API integration, and client update tests.
