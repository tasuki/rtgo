import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import lustre/element
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

fn playing(timing: game.TimeSettings) -> app.Model {
  let settings = game.Settings(9, game.TwoPlayerGame, timing)
  let initial =
    app.initial_model(
      app.Play("room"),
      player_info.LoggedIn("alice", "jwt"),
      "https://rtgo.test",
    )
  app.Model(
    ..initial,
    current_game: Some(lobby_api.GameDetails(
      "room",
      game.Started,
      "alice",
      ["alice", "bob"],
      2,
      settings,
      game.default_cooldowns(["alice", "bob"], settings),
      dict.from_list([#("alice", player.Black), #("bob", player.White)]),
    )),
    game: go.new_game(9),
    live: Some(play_api.State(
      go.new_game(9),
      [
        play_api.PlayerStatus(player.Player("alice", player.Black), 0, 10_000),
        play_api.PlayerStatus(player.Player("bob", player.White), 0, 10_000),
      ],
      False,
      0,
      10_000,
      dict.new(),
      play_api.NotScored,
      [],
      dict.new(),
    )),
  )
}

pub fn picker_uses_agreed_order_and_marks_simul_as_unavailable_test() {
  let initial =
    app.initial_model(
      app.CreateJoinGame,
      player_info.LoggedIn("alice", "jwt"),
      "https://rtgo.test",
    )
  let html = initial |> app.view |> element.to_string
  let options =
    string.split(html, "value=\"")
    |> list.filter(fn(part) {
      string.starts_with(part, "crazy_cooldown")
      || string.starts_with(part, "cushy_cooldown")
      || string.starts_with(part, "stone_savings")
      || string.starts_with(part, "simul_slaughter")
      || string.starts_with(part, "drag_derby")
    })
    |> list.map(fn(part) { string.split(part, "\"") |> list.first })
  should.equal(options, [
    Ok("crazy_cooldown"),
    Ok("cushy_cooldown"),
    Ok("stone_savings"),
    Ok("simul_slaughter"),
    Ok("drag_derby"),
  ])
  should.equal(string.contains(html, "Simul Slaughter — coming later"), True)
  let cushy = step(initial, app.TimeModeChanged("cushy_cooldown"))
  let assert Ok(settings) = app.creation_settings(cushy)
  should.equal(settings.time_settings, game.CushyCooldown(5))
  let bank =
    cushy
    |> step(app.TimeModeChanged("stone_savings"))
    |> step(app.SavingsCapChanged("7"))
    |> step(app.SavingsGapChanged("250"))
  let assert Ok(settings) = app.creation_settings(bank)
  should.equal(settings.time_settings, game.StoneSavings(5, 7, 250))
  should.equal(
    app.creation_settings(step(bank, app.SavingsGapChanged("5001"))),
    Error(Nil),
  )
  should.equal(
    app.creation_settings(step(bank, app.SavingsCapChanged("0"))),
    Error(Nil),
  )
  let drag =
    bank
    |> step(app.TimeModeChanged("drag_derby"))
    |> step(app.CooldownChanged("not a number"))
  let assert Ok(settings) = app.creation_settings(drag)
  should.equal(settings.time_settings, game.DragDerby)
  should.equal(
    app.creation_settings(step(initial, app.TimeModeChanged("simul_slaughter"))),
    Error(Nil),
  )
}

pub fn pass_waits_for_readiness_clears_premove_and_allows_resuming_test() {
  let model = playing(game.Cooldown(5))
  let assert Some(live) = model.live
  let cooling =
    app.Model(
      ..model,
      live: Some(
        play_api.State(
          ..live,
          players: list.map(live.players, fn(s) {
            play_api.PlayerStatus(..s, cooldown_ms: 1000)
          }),
        ),
      ),
    )
  should.equal(step(cooling, app.PassPressed), cooling)
  should.equal(
    step(app.Model(..model, drag_in_flight: 1), app.PassPressed),
    app.Model(..model, drag_in_flight: 1),
  )
  let sent = step(app.Model(..model, premove: Some(#(0, 0))), app.PassPressed)
  should.equal(sent.pending_action, True)
  should.equal(sent.premove, None)
  let passed =
    play_api.State(
      ..live,
      revision: 1,
      players: list.map(live.players, fn(s) {
        case s.player.username {
          "alice" -> play_api.PlayerStatus(..s, pass_in_ms: 0)
          _ -> s
        }
      }),
    )
  let ready = step(sent, app.MoveResponded(sent.page_version, Ok(passed)))
  should.equal(ready.pending_action, False)
  should.equal(step(ready, app.PassPressed), ready)
  let resumed = step(ready, app.PlayPoint(#(0, 0)))
  should.equal(resumed.pending_action, True)
}

pub fn dragging_does_not_wait_for_network_roundtrips_and_ignores_old_responses_test() {
  let model = playing(game.DragDerby)
  let sending = step(model, app.DragPoints([#(0, 0), #(1, 0), #(2, 0)]))
  should.equal(sending.drag_in_flight, 3)
  should.equal(sending.pending_action, False)
  let sending = step(sending, app.DragPoints([#(3, 0)]))
  should.equal(sending.drag_in_flight, 4)
  let assert Some(live) = model.live
  let newest = play_api.State(..live, revision: 4)
  let received =
    step(sending, app.DragResponded(sending.page_version, Ok(newest)))
  let received =
    step(received, app.DragResponded(received.page_version, Ok(live)))
  should.equal(received.drag_in_flight, 2)
  should.equal(received.live, Some(newest))
  let navigated = step(received, app.RouteChanged(app.CreateJoinGame))
  should.equal(navigated.drag_in_flight, 0)
  should.equal(
    step(navigated, app.DragResponded(received.page_version, Ok(live))),
    navigated,
  )
  let cooldown = playing(game.Cooldown(5))
  should.equal(step(cooldown, app.DragPoints([#(0, 0)])), cooldown)
}

pub fn savings_ui_shows_bank_not_a_fake_auto_pass_countdown_test() {
  let model = playing(game.StoneSavings(5, 3, 1000))
  let assert Some(live) = model.live
  let model =
    app.Model(
      ..model,
      live: Some(
        play_api.State(
          ..live,
          end_in_ms: -1,
          players: list.map(live.players, fn(s) {
            play_api.PlayerStatus(..s, pass_in_ms: -1)
          }),
          savings: dict.from_list([
            #("alice", play_api.SavingsStatus(2, 3, 9000)),
          ]),
        ),
      ),
    )
  let html = model |> app.view |> element.to_string
  should.equal(string.contains(html, "2/3 stones"), True)
  should.equal(string.contains(html, "next in 9s"), True)
  should.equal(string.contains(html, "Saving stones does not auto-pass"), True)
  should.equal(string.contains(html, "-1"), False)
}
