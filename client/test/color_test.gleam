import gleam/dict
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
import rtgo_shared/auth
import rtgo_shared/game
import rtgo_shared/lobby_api
import rtgo_shared/player

fn step(model: app.Model, msg: app.Msg) -> app.Model {
  let #(model, _) = app.update(model, msg)
  model
}

fn lobby() -> app.Model {
  app.initial_model(
    app.CreateJoinGame,
    player_info.LoggedIn("alice", "jwt"),
    "https://rtgo.test",
  )
}

fn room() -> app.Model {
  let settings = game.Settings(9, game.MultiplayerGame, game.Cooldown(2))
  let details =
    lobby_api.GameDetails(
      "room",
      game.Negotiating,
      "alice",
      ["alice", "bob"],
      2,
      settings,
      game.default_cooldowns(["alice", "bob"], settings),
      dict.from_list([#("alice", player.Black), #("bob", player.White)]),
    )
  app.Model(..lobby(), route: app.Play("room"), current_game: Some(details))
}

pub fn preferred_color_is_selectable_at_registration_and_preserved_on_errors_test() {
  let initial =
    app.initial_model(
      app.PlayerInfo,
      player_info.PickingName,
      "https://rtgo.test",
    )
  let simulation =
    simulate.application(
      fn(_) { #(initial, effect.none()) },
      app.update,
      app.view,
    )
    |> simulate.start(Nil)
  let chosen =
    simulation
    |> simulate.event(
      query.element(query.and(
        query.tag("button"),
        query.attribute("value", "pink"),
      )),
      "click",
      [],
    )
    |> simulate.model
  should.equal(chosen.preferred_color, player.Pink)
  should.equal(chosen.pending_preference, False)
  let registering = step(chosen, app.Register("alice"))
  should.equal(registering.preferred_color, player.Pink)
  let failed = step(registering, app.LoggedInResponse(Error(rsvp.NetworkError)))
  should.equal(failed.preferred_color, player.Pink)
  should.equal(step(chosen, app.PreferredColorChanged("invalid")), chosen)
}

pub fn preference_saves_block_create_join_until_the_new_color_is_saved_test() {
  let initial = lobby()
  let pending = step(initial, app.PreferredColorChanged("blue"))
  should.equal(pending.preferred_color, player.Blue)
  should.equal(pending.pending_preference, True)
  should.equal(step(pending, app.CreateGamePressed), pending)
  should.equal(step(pending, app.JoinGamePressed("room")), pending)
  should.equal(step(pending, app.PreferredColorChanged("pink")), pending)
  let saved =
    step(
      pending,
      app.PreferredColorSaved(
        pending.preference_version,
        player.Black,
        Ok(player.Blue),
      ),
    )
  should.equal(saved.pending_preference, False)
  should.equal(saved.preferred_color, player.Blue)
  should.equal(step(saved, app.CreateGamePressed).pending_action, True)
  let failed =
    step(
      pending,
      app.PreferredColorSaved(
        pending.preference_version,
        player.Black,
        Error(rsvp.NetworkError),
      ),
    )
  should.equal(failed.pending_preference, False)
  should.equal(failed.preferred_color, player.Black)
  should.not_equal(failed.preference_error, None)
  should.equal(
    step(failed, app.PreferredColorChanged("pink")).pending_preference,
    True,
  )
}

pub fn preference_responses_survive_navigation_but_not_a_newer_login_generation_test() {
  let pending = lobby() |> step(app.PreferredColorChanged("green"))
  let navigated = step(pending, app.RouteChanged(app.Play("room")))
  let saved =
    step(
      navigated,
      app.PreferredColorSaved(
        pending.preference_version,
        player.Black,
        Ok(player.Green),
      ),
    )
  should.equal(saved.preferred_color, player.Green)
  should.equal(saved.pending_preference, False)
  should.equal(
    step(saved, app.PreferredColorLoaded(0, Ok(player.Purple))),
    saved,
  )
  // A renewed login fetches the server's saved preference rather than resetting it.
  let jwt =
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhbGljZSIsImV4cCI6MjAwMDAwMDAwMH0.c2lnbmF0dXJl"
  let logging_in =
    step(saved, app.LoggedInResponse(Ok(auth.LogInResponse(jwt))))
  should.equal(logging_in.pending_preference, True)
  should.equal(
    step(
      logging_in,
      app.PreferredColorSaved(
        pending.preference_version,
        player.Black,
        Ok(player.Green),
      ),
    ),
    logging_in,
  )
  let loaded =
    step(
      logging_in,
      app.PreferredColorLoaded(logging_in.preference_version, Ok(player.Cyan)),
    )
  should.equal(loaded.preferred_color, player.Cyan)
  should.equal(loaded.route, app.Play("room"))
}

pub fn failed_preference_load_unblocks_controls_and_allows_retry_test() {
  let initial =
    app.Model(..lobby(), pending_preference: True, preference_version: 2)
  let failed =
    step(initial, app.PreferredColorLoaded(2, Error(rsvp.NetworkError)))
  should.equal(failed.pending_preference, False)
  should.not_equal(failed.preference_error, None)
  let retry = step(failed, app.PreferredColorChanged("pink"))
  should.equal(retry.pending_preference, True)
  let saved =
    step(
      retry,
      app.PreferredColorSaved(
        retry.preference_version,
        player.Black,
        Ok(player.Pink),
      ),
    )
  should.equal(saved.preference_error, None)
  should.equal(saved.preferred_color, player.Pink)
}

pub fn own_waiting_room_picker_disables_used_colors_and_never_edits_other_players_test() {
  let initial = room()
  let view = app.view(initial)
  let assert Ok(picker) =
    query.find(view, query.element(query.attribute("id", "game-color-alice")))
  let assert Ok(white) =
    query.find(picker, query.element(query.attribute("value", "white")))
  let assert Ok(black) =
    query.find(picker, query.element(query.attribute("value", "black")))
  let assert Ok(pink) =
    query.find(picker, query.element(query.attribute("value", "pink")))
  should.equal(white |> element.to_string |> string.contains("disabled"), True)
  should.equal(black |> element.to_string |> string.contains("disabled"), False)
  should.equal(pink |> element.to_string |> string.contains("disabled"), False)
  should.equal(
    view |> element.to_string |> string.contains("id=\"game-color-bob\""),
    False,
  )
  should.equal(step(initial, app.ChooseGameColor("white")), initial)
  should.equal(step(initial, app.ChooseGameColor("black")), initial)
  should.equal(step(initial, app.ChooseGameColor("red")), initial)
  let pending = step(initial, app.ChooseGameColor("pink"))
  should.equal(pending.pending_action, True)
  should.equal(step(pending, app.ChooseGameColor("purple")), pending)
  let guest = app.Model(..initial, player: player_info.LoggedIn("bob", "jwt"))
  should.equal(step(guest, app.ChooseGameColor("purple")).pending_action, True)
  let spectator =
    app.Model(..initial, player: player_info.LoggedIn("spectator", "jwt"))
  should.equal(step(spectator, app.ChooseGameColor("purple")), spectator)
}

pub fn successful_room_color_change_preserves_preference_and_drafts_and_invalidates_old_polls_test() {
  let initial = room() |> step(app.PlayerCooldownChanged("alice", "bad"))
  let pending = step(initial, app.ChooseGameColor("purple"))
  let changed =
    step(
      pending,
      app.GameColorChosen(pending.page_version, "alice", player.Purple, Ok(Nil)),
    )
  let assert Some(details) = changed.current_game
  should.equal(dict.get(details.colors, "alice"), Ok(player.Purple))
  should.equal(changed.preferred_color, player.Black)
  should.equal(dict.get(changed.cooldown_drafts, "alice"), Ok("bad"))
  should.equal(changed.pending_action, False)
  should.equal(changed.loading_game, True)
  let assert Some(old) = initial.current_game
  should.equal(
    step(
      changed,
      app.GameLoaded(pending.page_version, Ok(lobby_api.GetGameResponse(old))),
    ),
    changed,
  )
  let navigated = step(pending, app.RouteChanged(app.CreateJoinGame))
  should.equal(
    step(
      navigated,
      app.GameColorChosen(pending.page_version, "alice", player.Purple, Ok(Nil)),
    ),
    navigated,
  )
  let failed =
    step(
      pending,
      app.GameColorChosen(
        pending.page_version,
        "alice",
        player.Purple,
        Error(rsvp.NetworkError),
      ),
    )
  should.equal(failed.current_game, initial.current_game)
  should.equal(failed.pending_action, False)
  should.not_equal(failed.action_error, None)
}

pub fn two_player_color_choices_and_post_start_edits_are_restricted_test() {
  let initial = room()
  let assert Some(details) = initial.current_game
  let two =
    app.Model(
      ..initial,
      current_game: Some(
        lobby_api.GameDetails(..details, settings: game.default_settings),
      ),
    )
  should.equal(step(two, app.ChooseGameColor("pink")), two)
  let assert Ok(picker) =
    query.find(
      app.view(two),
      query.element(query.attribute("id", "game-color-alice")),
    )
  should.equal(
    picker |> element.to_string |> string.contains("value=\"pink\""),
    False,
  )
  let started =
    app.Model(
      ..initial,
      current_game: Some(lobby_api.GameDetails(..details, phase: game.Started)),
    )
  should.equal(step(started, app.ChooseGameColor("pink")), started)
}

pub fn changing_color_waits_for_an_in_progress_handicap_save_test() {
  let initial =
    room()
    |> step(app.PlayerCooldownChanged("alice", "5"))
    |> step(app.SetPlayerCooldownPressed("room", "alice"))
  should.equal(initial.saving_cooldown, True)
  let queued = step(initial, app.ChooseGameColor("pink"))
  should.equal(queued.after_save, Some(app.ChooseGameColor("pink")))
  let saved =
    step(
      queued,
      app.PlayerCooldownSet(queued.page_version, "alice", 5, Ok(Nil)),
    )
  should.equal(saved.saving_cooldown, False)
  should.equal(saved.pending_action, True)
  should.equal(saved.after_save, None)
}
