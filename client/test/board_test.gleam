import gleam/dict
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import lustre/dev/query
import lustre/dev/simulate
import lustre/effect
import lustre/element
import rsvp
import rtgo_client as app
import rtgo_client/player_info
import rtgo_shared/game
import rtgo_shared/go
import rtgo_shared/lobby_api
import rtgo_shared/play_api
import rtgo_shared/player

fn step(model: app.Model, msg: app.Msg) -> app.Model {
  let #(model, _) = app.update(model, msg)
  model
}

fn state() -> play_api.State {
  play_api.State(
    go.new_game(9),
    [
      play_api.PlayerStatus(player.Player("alice", player.Black), 0, 10_000),
      play_api.PlayerStatus(player.Player("bob", player.White), 0, 10_000),
    ],
    False,
    0,
    10_000,
    dict.new(),
  )
}

fn loaded() -> app.Model {
  let model =
    app.initial_model(
      app.Play("room"),
      player_info.LoggedIn("alice", "jwt"),
      "https://rtgo.test",
    )
    |> step(app.RouteChanged(app.Play("room")))
  let settings = game.Settings(9, game.TwoPlayerGame, game.Cooldown(5))
  let model =
    step(
      model,
      app.GameLoaded(
        model.page_version,
        Ok(
          lobby_api.GetGameResponse(lobby_api.GameDetails(
            "room",
            game.Started,
            "alice",
            ["alice", "bob"],
            2,
            settings,
            game.default_cooldowns(["alice", "bob"], settings),
          )),
        ),
      ),
    )
  step(model, app.BoardLoaded(model.page_version, Ok(state())))
}

pub fn stones_hover_and_keyboard_moves_are_wired_up_test() {
  let model = loaded()
  let simulation =
    simulate.application(
      fn(_) { #(model, effect.none()) },
      app.update,
      app.view,
    )
    |> simulate.start(Nil)
  let point =
    query.element(query.attribute("aria-label", "Play at column 1, row 1"))
  let hovering =
    simulation |> simulate.event(point, "mouseenter", []) |> simulate.model
  should.equal(hovering.hovered, Some(#(0, 0)))
  should.equal(
    hovering |> app.view |> element.to_string |> string.contains("ghost-stone"),
    True,
  )
  let clicked =
    simulation |> simulate.event(point, "click", []) |> simulate.model
  should.equal(clicked.pending_action, True)
  should.equal(clicked.hovered, None)
  should.equal(step(clicked, app.PlayPoint(#(0, 0))), clicked)
  let entered =
    simulation
    |> simulate.event(point, "keydown", [#("key", json.string("Enter"))])
    |> simulate.model
  should.equal(entered.pending_action, True)
  let spaced =
    simulation
    |> simulate.event(point, "keydown", [#("key", json.string(" "))])
    |> simulate.model
  should.equal(spaced.pending_action, True)
  should.equal(
    simulation
      |> simulate.event(point, "keydown", [#("key", json.string("ArrowDown"))])
      |> simulate.model,
    model,
  )

  let assert Ok(board) =
    go.play(state().board, player.Player("alice", player.Black), #(0, 0))
  let updated = play_api.State(..state(), board: board, revision: 1)
  let moved = step(clicked, app.MoveResponded(model.page_version, Ok(updated)))
  should.equal(moved.game.stones, board.stones)
  should.equal(moved.pending_action, False)
  should.equal(
    moved |> app.view |> element.to_string |> string.contains("class=\"stone\""),
    True,
  )
  should.equal(step(moved, app.PlayPoint(#(0, 0))), moved)
}

pub fn polling_does_not_overlap_or_roll_back_successful_moves_test() {
  let model = loaded()
  let refreshing = step(model, app.BoardRefresh(model.page_version))
  should.equal(refreshing.loading_board, True)
  should.equal(
    step(refreshing, app.BoardRefresh(model.page_version)),
    refreshing,
  )
  let assert Ok(board) =
    go.play(state().board, player.Player("alice", player.Black), #(0, 0))
  let updated = play_api.State(..state(), board: board, revision: 1)
  let moved =
    refreshing
    |> step(app.PlayPoint(#(0, 0)))
    |> step(app.MoveResponded(model.page_version, Ok(updated)))
  let old_poll = step(moved, app.BoardLoaded(model.page_version, Ok(state())))
  should.equal(old_poll.game, moved.game)
  should.equal(old_poll.live, Some(updated))
  should.equal(old_poll.loading_board, False)
  let failed =
    step(
      old_poll,
      app.BoardLoaded(model.page_version, Error(rsvp.NetworkError)),
    )
  should.equal(failed.game, moved.game)
  should.not_equal(failed.load_error, None)
  let recovered = step(failed, app.BoardLoaded(model.page_version, Ok(updated)))
  should.equal(recovered.load_error, None)
  let navigated =
    moved
    |> step(app.RouteChanged(app.Play("other")))
    |> step(app.RouteChanged(app.Play("room")))
  should.equal(navigated.live, None)
  should.equal(navigated.hovered, None)
  should.equal(navigated.loading_board, False)
  should.equal(
    step(navigated, app.BoardLoaded(model.page_version, Ok(updated))),
    navigated,
  )
  should.equal(
    step(navigated, app.MoveResponded(model.page_version, Ok(updated))),
    navigated,
  )
  should.equal(
    step(
      navigated,
      app.MoveResponded(model.page_version, Error(rsvp.NetworkError)),
    ),
    navigated,
  )
  should.equal(step(navigated, app.BoardRefresh(model.page_version)), navigated)
}

pub fn cooldown_spectators_and_finished_games_cannot_move_test() {
  let model = loaded()
  let cooling =
    play_api.State(
      ..state(),
      players: [
        play_api.PlayerStatus(
          player.Player("alice", player.Black),
          5000,
          15_000,
        ),
        play_api.PlayerStatus(player.Player("bob", player.White), 0, 0),
      ],
      end_in_ms: 15_000,
    )
  let waiting = step(model, app.BoardLoaded(model.page_version, Ok(cooling)))
  should.equal(step(waiting, app.PlayPoint(#(0, 0))), waiting)
  let html = waiting |> app.view |> element.to_string
  should.equal(string.contains(html, "Ready in 5s"), True)
  should.equal(string.contains(html, "Passing (can still play)"), True)
  let spectator =
    app.Model(..model, player: player_info.LoggedIn("spectator", "jwt"))
  should.equal(step(spectator, app.PlayPoint(#(0, 0))), spectator)
  should.equal(
    spectator
      |> app.view
      |> element.to_string
      |> string.contains("You are spectating."),
    True,
  )
  let finished =
    play_api.State(
      ..state(),
      finished: True,
      revision: 1,
      end_in_ms: 0,
      scores: dict.from_list([#("alice", 42), #("bob", 39)]),
    )
  let ended = step(model, app.BoardLoaded(model.page_version, Ok(finished)))
  should.equal(step(ended, app.PlayPoint(#(0, 0))), ended)
  let html = ended |> app.view |> element.to_string
  should.equal(string.contains(html, "Game over"), True)
  should.equal(string.contains(html, "alice wins with 42 points."), True)
  should.equal(string.contains(html, "role=\"button\""), False)
  // A move reply from before the final snapshot must not reopen the game.
  let late = step(ended, app.MoveResponded(model.page_version, Ok(state())))
  should.equal(late.live, Some(finished))
  let tied =
    step(
      ended,
      app.BoardLoaded(
        model.page_version,
        Ok(
          play_api.State(
            ..finished,
            scores: dict.from_list([#("alice", 40), #("bob", 40)]),
          ),
        ),
      ),
    )
  should.equal(
    tied |> app.view |> element.to_string |> string.contains("Tie: alice, bob"),
    True,
  )
}

pub fn failed_moves_preserve_board_and_allow_retry_test() {
  let model = loaded()
  let pending = step(model, app.PlayPoint(#(0, 0)))
  let failed =
    step(
      pending,
      app.MoveResponded(model.page_version, Error(rsvp.NetworkError)),
    )
  should.equal(failed.pending_action, False)
  should.equal(failed.game, model.game)
  should.not_equal(failed.action_error, None)
  let retry = step(failed, app.PlayPoint(#(0, 0)))
  should.equal(retry.pending_action, True)
  should.equal(retry.action_error, None)
}
