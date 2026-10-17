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

## All-in-one image (Podman)

```sh
mise run image
podman run --rm -p 8000:8000 \
  -e SECRET_KEY_BASE -e SIGN_KEY localhost/rtgo:latest
```

Set `SECRET_KEY_BASE` and `SIGN_KEY` to separate long random secrets in your shell
first, then open **http://localhost:8000**. The image serves the browser frontend
and the API (`/api`) on the same port. Shared `/play/...` links work directly,
including after a reload. The bundled client uses the page's origin, so LAN
addresses, other published ports and HTTPS reverse proxies need no client rebuild.

The multi-stage `Containerfile` bundles a stripped CPU-only KataGo 1.16.4 (Eigen)
and `kata1-b6c96-s175395328-d26788732.txt.gz`. The KataGo source archive and model
are checksum-verified. Only the Erlang runtime, production application, minified
frontend (including styles/fonts), engine and compressed model reach the final
slim Debian image—no C++ toolchain, Gleam, Bun, GPU libraries or startup downloads.
It runs as an unprivileged user.

Hosts can **Add KataGo bot** in a waiting room, then start normally. Bots occupy
ordinary seats and can be kicked or handicapped with longer cooldowns. One
persistent engine serves all bots at one visit per move. Each query uses a fresh
board, treating the bot's stones as black and all other stones as white, with
zero komi. The bot plays the highest-probability move from KataGo's raw neural
network policy (including pass), without search or tactical overrides; normal
server legality/cooldown checks still apply. A pass or rejected move waits
for a changed position before trying again. Multiplayer is an approximation, not
a multiplayer-trained model.

Outside the image, bots are unavailable unless the bundled files are installed
at `/opt/katago`; human-only development works without KataGo. Engine/model/visit
settings are deliberately fixed for now.

## Develop

```
mise run dev
```

## Try the lobby

Choose a name and preferred color, then create a two-player (black/white) or
multiplayer (up to eight colors) game. Pick a 9×9, 13×13 or 19×19 board and a 1–60 second cooldown. Share
its `/play/...` URL so other browser profiles or private windows can join. The
host can start once at least two players have joined. Click or tap an empty
intersection to play; keyboard users can focus a point and press Enter or Space.
Everyone starts ready and can move independently (there are no alternating turns).
The server serializes moves, applies captures and positional superko, and enforces
each player's cooldown. Rejected moves do not consume a cooldown. Boards refresh
every 250ms; spectators can watch but cannot move.

Choose colors from the always-visible stones on a board background; a ring marks
your selection. Change your saved **Preferred color** in the main lobby. Creating or joining a
room uses it if that color is free and supported by the game type; otherwise a
random available color is assigned. Two-player games always use black and white.
Changing your preference doesn't recolor existing games.

In a waiting room, each member can change **Your color** to any currently unused
color for that game. Everyone sees the assigned colors; taken colors are disabled,
and the server resolves simultaneous claims atomically. Choosing a room color
doesn't change your saved preference. Colors are locked once the host starts.
Account preferences, like rooms, are currently held in server memory.

During cooldown, click an empty point to queue one **premove**, shown as a faint
normal-sized stone. Clicking elsewhere replaces it until it is sent;
clicking the selected point again or pressing Escape cancels it. The latest
queued point is sent once a live update confirms you are ready. An occupied point
cancels the queue, and legality is checked again before sending. Server rejection
(including superko) or a network failure does not retry the move automatically.
Queued moves are local to this page and clear on navigation or game end.

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

Final scoring uses **Chinese-like area scoring**: stones on the board plus empty
regions bordered by exactly one player's stones. Captured stones give no separate
prisoner bonus. Mixed-color borders and unclaimed space are neutral; there is no
komi. Highest score wins, with ties allowed. Play uses positional superko and
forbids suicide. Real-time passing, multiplayer neutral regions and estimated
dead-stone adjudication make this a custom variant, not tournament Chinese rules.

Once play stops, the server asks KataGo for **ownership estimates for each player**:
their stones are black, all others white, with that player to move. It makes
**one single-visit NN evaluation per player** on the original board: eight players
need eight evaluations, not extra transformed-board or opposite-turn queries.
Ownership is reported from that player's perspective. A whole actual-color group
is excluded only if every stone has ownership at or below -0.6 in its owner's
estimate. Uncertain groups, missing data, and seki-like neutral ownership stay;
opponents are never merged when identifying the groups to remove. These remain
estimates, not life-and-death proofs. There is no second-turn agreement safeguard,
so turn-dependent positions can be misjudged. Multiplayer remains approximate
because KataGo sees only two colors in each projection.

The UI shows **Scoring…** while this runs asynchronously, then a **KataGo estimate**.
Estimated dead stones remain visible, faded and marked ×, but do not count and do
not block territory. The actual final board/history are preserved. All final
area/neutral-region calculations still use RTGO's real multiplayer rules, not
KataGo's score lead. The final overview and player circles are ordered by score
(highest first, ties alphabetical). Counted area (live stones plus territory) is
shaded in its owner's color above the board and below the stones; neutral empty
regions stay unshaded. The colored intersections add up to each player's score.
This uses the same scoring position with dead stones excluded, so shading also
appears beneath excluded stones. No territory is shown while playing or waiting
for scoring. There is no resume-after-finish or manual correction yet.

If KataGo is absent, fails, or scoring exceeds 30 seconds, the UI explicitly labels
an **unassisted area score** with no dead stones removed. No provisional winner is
shown while waiting, and clients keep polling until the result is ready.

The lobby and waiting room refresh automatically every second. Finished games
remain accessible at their room URL. State is currently in memory and disappears
on server restart.

## Test

```
mise run test
```

Runs shared rules, server/API integration, and client update tests. Engine-backed
scoring cases run when KataGo is installed at the production paths; otherwise
those cases are skipped (the rule/fixture tests still run).

To test production's **one evaluation per player** scoring against
the enclosed-stone, screenshot, seki, escapable-atari, and empty-board cases over
20 trials with a fresh engine (and therefore a fresh NN cache) each time:

```
mise run test:single-view
```

This requires KataGo and its model and exercises the actual production scoring
path, including whole-group, per-stone cutoff, and missing-data checks.
