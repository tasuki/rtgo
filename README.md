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
host can start once at least two players have joined; everyone sees the chosen
board. Settings are retained by the running game, but cooldown enforcement and
browser moves are not implemented yet.

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
and leaving/rejoining does not reset them. They are retained when the game starts,
but, like the base cooldown, are not enforced by gameplay yet. Kicking and editing
cooldowns are only allowed before start.

The lobby and waiting room refresh automatically every second. State is currently
in memory and disappears on server restart.

## Test

```
mise run test
```

Runs shared rules, server/API integration, and client update tests.
