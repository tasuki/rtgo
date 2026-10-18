import gleam/dict
import gleam/http/response
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

fn cooling() -> app.Model {
  let board = go.new_game(9)
  let settings = game.Settings(9, game.TwoPlayerGame, game.Cooldown(2))
  let details =
    lobby_api.GameDetails(
      "room",
      game.Started,
      "alice",
      ["alice", "bob"],
      2,
      settings,
      game.default_cooldowns(["alice", "bob"], settings),
      dict.from_list([#("alice", player.Black), #("bob", player.White)]),
    )
  let live =
    play_api.State(
      board,
      [
        play_api.PlayerStatus(
          player.Player("alice", player.Black),
          2000,
          12_000,
        ),
        play_api.PlayerStatus(player.Player("bob", player.White), 0, 10_000),
      ],
      False,
      1,
      12_000,
      dict.new(),
      play_api.NotScored,
      [],
      dict.new(),
    )
  app.Model(
    ..app.initial_model(
      app.Play("room"),
      player_info.LoggedIn("alice", "jwt"),
      "https://rtgo.test",
    ),
    game: board,
    current_game: Some(details),
    live: Some(live),
    page_version: 1,
  )
}

fn ready(model: app.Model) -> play_api.State {
  let assert Some(live) = model.live
  let assert [alice, bob] = live.players
  play_api.State(..live, players: [
    play_api.PlayerStatus(..alice, cooldown_ms: 0, pass_in_ms: 10_000),
    bob,
  ])
}

fn loaded(model: app.Model, state: play_api.State) -> app.Model {
  step(model, app.BoardLoaded(model.page_version, Ok(state)))
}

pub fn opening_cooldown_shows_a_full_timer_and_queues_the_first_move_test() {
  let initial = cooling()
  let assert Some(state) = initial.live
  let assert [alice, bob] = state.players
  let opening =
    app.Model(
      ..initial,
      live: Some(
        play_api.State(..state, revision: 0, players: [
          alice,
          play_api.PlayerStatus(..bob, cooldown_ms: 2000, pass_in_ms: 12_000),
        ]),
      ),
    )
  let html = opening |> app.view |> element.to_string
  should.equal(string.contains(html, "countdown-bars"), True)
  should.equal(string.contains(html, "--remaining:100%"), True)
  let queued = step(opening, app.PlayPoint(#(1, 1)))
  should.equal(queued.premove, Some(#(1, 1)))
  should.equal(queued.pending_action, False)
  let assert Some(state) = queued.live
  let cooling = loaded(queued, state)
  should.equal(cooling.premove, Some(#(1, 1)))
  should.equal(cooling.pending_action, False)
  let sent = loaded(cooling, ready(cooling))
  should.equal(sent.premove, None)
  should.equal(sent.pending_action, True)
  should.equal(dict.is_empty(sent.game.stones), True)
}

pub fn one_premove_is_replaceable_until_the_latest_point_is_sent_test() {
  let initial = cooling()
  let queued = step(initial, app.PlayPoint(#(1, 1)))
  should.equal(queued.premove, Some(#(1, 1)))
  should.equal(queued.pending_action, False)
  should.equal(queued.game, initial.game)
  let replaced = step(queued, app.PlayPoint(#(3, 4)))
  should.equal(replaced.premove, Some(#(3, 4)))
  let assert Some(state) = replaced.live
  let still_cooling = loaded(replaced, state)
  should.equal(still_cooling.premove, Some(#(3, 4)))
  should.equal(still_cooling.pending_action, False)
  let sent = loaded(still_cooling, ready(still_cooling))
  should.equal(sent.premove, None)
  should.equal(sent.pending_action, True)
  // Once the HTTP request has started, clicks cannot replace it or send another.
  should.equal(step(sent, app.PlayPoint(#(5, 5))), sent)
  let repeated = loaded(sent, ready(sent))
  should.equal(repeated.pending_action, True)
  should.equal(repeated.premove, None)
}

pub fn queued_marker_and_click_keyboard_cancellation_are_wired_up_test() {
  let initial = cooling()
  let simulation =
    simulate.application(
      fn(_) { #(initial, effect.none()) },
      app.update,
      app.view,
    )
    |> simulate.start(Nil)
  let point =
    query.element(query.attribute("aria-label", "Play at column 2, row 3"))
  let queued =
    simulation |> simulate.event(point, "click", []) |> simulate.model
  should.equal(queued.premove, Some(#(1, 2)))
  let html = queued |> app.view |> element.to_string
  should.equal(string.contains(html, "premove-stone"), True)
  should.equal(string.contains(html, "aria-pressed=\"true\""), True)
  should.equal(step(queued, app.PlayPoint(#(1, 2))).premove, None)
  let simulation =
    simulate.application(
      fn(_) { #(queued, effect.none()) },
      app.update,
      app.view,
    )
    |> simulate.start(Nil)
  let board = query.element(query.attribute("aria-label", "Go board"))
  let cancelled =
    simulation
    |> simulate.event(board, "keydown", [#("key", json.string("Escape"))])
    |> simulate.model
  should.equal(cancelled.premove, None)
  let replacement =
    query.element(query.attribute("aria-label", "Play at column 4, row 5"))
  let replaced =
    simulation
    |> simulate.event(replacement, "keydown", [#("key", json.string("Enter"))])
    |> simulate.model
  should.equal(replaced.premove, Some(#(3, 4)))
  should.equal(replaced.pending_action, False)
}

pub fn occupied_queue_is_cancelled_without_sending_or_consuming_a_move_test() {
  let queued = cooling() |> step(app.PlayPoint(#(2, 2)))
  let assert Some(state) = queued.live
  let assert Ok(board) =
    go.play(state.board, player.Player("bob", player.White), #(2, 2))
  let changed =
    loaded(queued, play_api.State(..state, board: board, revision: 2))
  should.equal(changed.premove, None)
  should.equal(changed.pending_action, False)
  should.not_equal(changed.action_error, None)
  // An occupied or out-of-bounds click doesn't replace a valid queue.
  let queued = step(changed, app.PlayPoint(#(3, 3)))
  should.equal(step(queued, app.PlayPoint(#(2, 2))), queued)
  should.equal(step(queued, app.PlayPoint(#(-1, 0))), queued)
  should.equal(step(queued, app.PlayPoint(#(9, 0))), queued)
  should.equal(loaded(changed, ready(changed)).pending_action, False)
}

pub fn suicide_is_rechecked_when_ready_but_not_while_planning_test() {
  let queued = cooling() |> step(app.PlayPoint(#(0, 0)))
  let assert Some(state) = queued.live
  let bob = player.Player("bob", player.White)
  let assert Ok(board) = go.play(state.board, bob, #(0, 1))
  let assert Ok(board) = go.play(board, bob, #(1, 0))
  let changed =
    loaded(queued, play_api.State(..state, board: board, revision: 2))
  // A move may become legal again before readiness, so keep planning possible.
  should.equal(changed.premove, Some(#(0, 0)))
  let cancelled = loaded(changed, ready(changed))
  should.equal(cancelled.premove, None)
  should.equal(cancelled.pending_action, False)
  should.not_equal(cancelled.action_error, None)
}

pub fn stale_polls_and_failed_refreshes_do_not_send_or_lose_the_queue_test() {
  let queued = cooling() |> step(app.PlayPoint(#(1, 1)))
  let stale_ready = play_api.State(..ready(queued), revision: 0)
  let stale = loaded(queued, stale_ready)
  should.equal(stale.premove, queued.premove)
  should.equal(stale.pending_action, False)
  let failed =
    step(queued, app.BoardLoaded(queued.page_version, Error(rsvp.NetworkError)))
  should.equal(failed.premove, queued.premove)
  should.equal(failed.pending_action, False)
  let replaced = step(failed, app.PlayPoint(#(2, 2)))
  should.equal(replaced.premove, Some(#(2, 2)))
  let recovered = loaded(replaced, ready(replaced))
  should.equal(recovered.premove, None)
  should.equal(recovered.pending_action, True)
}

pub fn navigation_game_end_and_loss_of_membership_clear_premoves_test() {
  let queued = cooling() |> step(app.PlayPoint(#(1, 1)))
  let navigated = step(queued, app.RouteChanged(app.Play("other")))
  should.equal(navigated.premove, None)
  should.equal(
    step(navigated, app.BoardLoaded(queued.page_version, Ok(ready(queued)))),
    navigated,
  )
  let ended =
    loaded(queued, play_api.State(..ready(queued), finished: True, revision: 2))
  should.equal(ended.premove, None)
  should.equal(ended.pending_action, False)
  should.equal(step(ended, app.PlayPoint(#(2, 2))), ended)
  let removed = loaded(queued, play_api.State(..ready(queued), players: []))
  should.equal(removed.premove, None)
  should.equal(removed.pending_action, False)
  let spectator =
    app.Model(..cooling(), player: player_info.LoggedIn("spectator", "jwt"))
  should.equal(step(spectator, app.PlayPoint(#(1, 1))), spectator)
}

pub fn sent_premoves_are_not_retried_on_rejection_or_network_failure_test() {
  let queued = cooling() |> step(app.PlayPoint(#(1, 1)))
  let sent = loaded(queued, ready(queued))
  let rejection =
    rsvp.HttpError(
      response.new(409)
      |> response.set_body(
        "{\"msg\":\"That move repeats a previous board (superko)\"}",
      ),
    )
  assert_not_retried(sent, rejection)
  assert_not_retried(sent, rsvp.NetworkError)
}

fn assert_not_retried(sent: app.Model, error: rsvp.Error) {
  let failed = step(sent, app.MoveResponded(sent.page_version, Error(error)))
  should.equal(failed.premove, None)
  should.equal(failed.pending_action, False)
  should.not_equal(failed.action_error, None)
  let refreshed = loaded(failed, ready(failed))
  should.equal(refreshed.pending_action, False)
  should.equal(refreshed.premove, None)
  let manual = step(refreshed, app.PlayPoint(#(3, 3)))
  should.equal(manual.pending_action, True)
}

pub fn successful_premove_allows_planning_the_next_move_test() {
  let queued = cooling() |> step(app.PlayPoint(#(1, 1)))
  let sent = loaded(queued, ready(queued))
  let assert Some(state) = cooling().live
  let assert Ok(board) =
    go.play(state.board, player.Player("alice", player.Black), #(1, 1))
  let moved =
    step(
      sent,
      app.MoveResponded(
        sent.page_version,
        Ok(play_api.State(..state, board: board, revision: 2)),
      ),
    )
  should.equal(moved.premove, None)
  should.equal(moved.pending_action, False)
  let queued = step(moved, app.PlayPoint(#(2, 2)))
  should.equal(queued.premove, Some(#(2, 2)))
  should.equal(queued.pending_action, False)
}
