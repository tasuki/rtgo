import gleam/dict
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
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

pub fn main() {
  gleeunit.main()
}

fn model(route: app.Route) -> app.Model {
  app.initial_model(
    route,
    player_info.LoggedIn("alice", "jwt"),
    "https://rtgo.test",
  )
  |> step(app.RouteChanged(route))
}

fn step(model: app.Model, msg: app.Msg) -> app.Model {
  let #(model, _) = app.update(model, msg)
  model
}

fn room(
  id: String,
  phase: game.GamePhase,
  players: List(String),
) -> lobby_api.GetGameResponse {
  lobby_api.GetGameResponse(lobby_api.GameDetails(
    id,
    phase,
    "alice",
    players,
    list.length(players),
    game.default_settings,
    game.default_cooldowns(players, game.default_settings),
    dict.new(),
  ))
}

pub fn lobby_refresh_does_not_change_the_view_even_when_empty_test() {
  let initial = model(app.CreateJoinGame)
  should.equal(
    initial |> app.view |> element.to_string |> string.contains("Loading..."),
    True,
  )
  list.each(
    [
      [],
      [
        lobby_api.GameMetadata(
          "room",
          game.Negotiating,
          1,
          game.default_settings,
          None,
        ),
      ],
    ],
    fn(games) {
      let response =
        app.GamesLoaded(
          initial.page_version,
          Ok(lobby_api.ListGamesResponse(games, False)),
        )
      let loaded = step(initial, response)
      let html = loaded |> app.view |> element.to_string
      should.equal(string.contains(html, "Loading..."), False)
      let refreshing = step(loaded, app.Refresh(loaded.page_version))
      should.equal(refreshing.loading_lobby, True)
      should.equal(refreshing |> app.view |> element.to_string, html)
      should.equal(
        step(refreshing, response) |> app.view |> element.to_string,
        html,
      )
    },
  )
  // Initial failures must also stay visually stable while retrying.
  list.each([app.CreateJoinGame, app.Play("room")], fn(route) {
    let initial = model(route)
    let failed = case route {
      app.CreateJoinGame ->
        step(
          initial,
          app.GamesLoaded(initial.page_version, Error(rsvp.NetworkError)),
        )
      _ ->
        step(
          initial,
          app.GameLoaded(initial.page_version, Error(rsvp.NetworkError)),
        )
    }
    let retrying = step(failed, app.Refresh(failed.page_version))
    should.equal(
      retrying |> app.view |> element.to_string,
      failed |> app.view |> element.to_string,
    )
  })
}

pub fn lobby_groups_open_running_and_finished_games_test() {
  let initial = model(app.CreateJoinGame)
  let games = [
    lobby_api.GameMetadata(
      "waiting-room",
      game.Negotiating,
      1,
      game.default_settings,
      None,
    ),
    lobby_api.GameMetadata(
      "playing-room",
      game.Started,
      2,
      game.default_settings,
      None,
    ),
    lobby_api.GameMetadata(
      "completed-room",
      game.Finished,
      3,
      game.default_settings,
      None,
    ),
  ]
  let loaded =
    step(
      initial,
      app.GamesLoaded(
        initial.page_version,
        Ok(lobby_api.ListGamesResponse(games, False)),
      ),
    )
  let sections =
    query.find_all(
      app.view(loaded),
      query.element(query.class("lobby-section")),
    )
  should.equal(list.length(sections), 3)
  list.zip(sections, [
    #("Open for joining", "waiting-room"),
    #("In progress", "playing-room"),
    #("Finished games", "completed-room"),
  ])
  |> list.each(fn(entry) {
    let #(section, #(title, id)) = entry
    let html = element.to_string(section)
    should.equal(string.contains(html, "<h2>" <> title <> "</h2>"), True)
    should.equal(
      list.length(query.find_all(
        section,
        query.element(query.class("game-row")),
      )),
      1,
    )
    list.each(games, fn(game) {
      should.equal(string.contains(html, game.id), game.id == id)
    })
  })
  let empty =
    step(
      loaded,
      app.GamesLoaded(
        loaded.page_version,
        Ok(lobby_api.ListGamesResponse([], False)),
      ),
    )
  should.equal(
    string.contains(
      element.to_string(app.view(empty)),
      "<h2>Finished games</h2><p>none</p>",
    ),
    True,
  )
}

pub fn finished_lobby_row_opens_the_game_instead_of_joining_test() {
  let initial = model(app.CreateJoinGame)
  let loaded =
    step(
      initial,
      app.GamesLoaded(
        initial.page_version,
        Ok(lobby_api.ListGamesResponse(
          [
            lobby_api.GameMetadata(
              "done",
              game.Finished,
              2,
              game.default_settings,
              None,
            ),
          ],
          False,
        )),
      ),
    )
  let clicked =
    simulate.application(
      fn(_) { #(None, effect.none()) },
      fn(_, msg) { #(Some(msg), effect.none()) },
      fn(_) { app.view(loaded) },
    )
    |> simulate.start(Nil)
    |> simulate.event(query.element(query.class("game-row")), "click", [])
    |> simulate.model
  should.equal(clicked, Some(app.OpenGame("done")))
}

pub fn finished_pages_show_dates_and_ignore_stale_responses_test() {
  let initial = model(app.CreateJoinGame)
  let first =
    lobby_api.GameMetadata(
      "newest",
      game.Finished,
      2,
      game.default_settings,
      Some("2026-10-18T12:34:56Z"),
    )
  let loaded =
    step(
      initial,
      app.GamesLoaded(
        initial.page_version,
        Ok(lobby_api.ListGamesResponse([first], True)),
      ),
    )
  let html = loaded |> app.view |> element.to_string
  should.equal(string.contains(html, "class=\"game-id\">newest<time"), True)
  should.equal(string.contains(html, "2026-10-18 · 12:34 UTC"), True)
  should.equal(string.contains(html, "datetime=\"2026-10-18T12:34:56Z\""), True)
  let clicked =
    simulate.application(
      fn(_) { #(None, effect.none()) },
      fn(_, msg) { #(Some(msg), effect.none()) },
      fn(_) { app.view(loaded) },
    )
    |> simulate.start(Nil)
    |> simulate.event(
      query.element(query.tag("button") |> query.and(query.text("Next"))),
      "click",
      [],
    )
    |> simulate.model
  should.equal(clicked, Some(app.FinishedPage(1)))
  let loading = step(loaded, app.FinishedPage(1))
  should.equal(loading.pending_finished_page, Some(1))
  should.equal(loading.finished_page, 0)
  should.equal(loading.lobby_games, [first])
  should.equal(step(loading, app.FinishedPage(2)), loading)
  should.equal(
    step(
      loading,
      app.GamesLoaded(
        loaded.page_version,
        Ok(lobby_api.ListGamesResponse([], False)),
      ),
    ),
    loading,
  )
  let older = lobby_api.GameMetadata(..first, id: "older")
  let next =
    step(
      loading,
      app.GamesLoaded(
        loading.page_version,
        Ok(lobby_api.ListGamesResponse([older], False)),
      ),
    )
  should.equal(next.finished_page, 1)
  should.equal(next.pending_finished_page, None)
  should.equal(next.lobby_games, [older])
  should.equal(step(next, app.FinishedPage(2)), next)
  should.equal(
    string.contains(element.to_string(app.view(next)), "Page 2"),
    True,
  )
  let previous = step(next, app.FinishedPage(0))
  should.equal(previous.pending_finished_page, Some(0))
  let failed =
    step(
      previous,
      app.GamesLoaded(previous.page_version, Error(rsvp.NetworkError)),
    )
  should.equal(failed.finished_page, 1)
  should.equal(failed.lobby_games, [older])
  should.equal(failed.pending_finished_page, None)
  should.equal(step(failed, app.FinishedPage(0)).pending_finished_page, Some(0))
}

pub fn room_refresh_tracks_joins_and_start_without_blanking_the_room_test() {
  let model = model(app.Play("room"))
  let version = model.page_version
  let first = room("room", game.Negotiating, ["alice"])
  let loaded = step(model, app.GameLoaded(version, Ok(first)))
  should.equal(loaded.loading_game, False)

  let refreshing = step(loaded, app.Refresh(version))
  should.equal(refreshing.loading_game, True)
  should.equal(refreshing.current_game, Some(first.game))
  // An extra refresh cannot overlap the in-flight request.
  should.equal(step(refreshing, app.Refresh(version)), refreshing)
  let joined = room("room", game.Negotiating, ["alice", "bob"])
  let loaded = step(refreshing, app.GameLoaded(version, Ok(joined)))
  should.equal(loaded.current_game, Some(joined.game))

  let failed =
    loaded
    |> step(app.Refresh(version))
    |> step(app.GameLoaded(version, Error(rsvp.NetworkError)))
  should.equal(failed.current_game, loaded.current_game)
  should.not_equal(failed.load_error, None)
  let started = room("room", game.Started, ["alice", "bob"])
  let recovered =
    failed
    |> step(app.Refresh(version))
    |> step(app.GameLoaded(version, Ok(started)))
  should.equal(recovered.current_game, Some(started.game))
  should.equal(recovered.load_error, None)
  let missing =
    step(
      recovered,
      app.GameLoaded(
        version,
        Error(rsvp.HttpError(response.new(404) |> response.set_body(""))),
      ),
    )
  should.equal(missing.current_game, None)
  // A missing live room may still have a persisted recording after restart.
  should.equal(missing.loading_game, True)
  should.equal(missing.load_error, None)
  let missing_recording =
    step(
      missing,
      app.SgfLoaded(
        version,
        Error(rsvp.HttpError(response.new(404) |> response.set_body(""))),
      ),
    )
  should.equal(missing_recording.loading_game, False)
  should.not_equal(missing_recording.replay.error, None)
}

pub fn navigation_discards_old_responses_actions_and_timers_even_on_revisit_test() {
  let first = model(app.Play("a"))
  let old = first.page_version
  let revisited =
    first
    |> step(app.RouteChanged(app.Play("b")))
    |> step(app.RouteChanged(app.Play("a")))
  let stale_messages = [
    app.GameLoaded(old, Ok(room("a", game.Negotiating, ["alice"]))),
    app.GameLoaded(old, Error(rsvp.NetworkError)),
    app.GamesLoaded(old, Ok(lobby_api.ListGamesResponse([], False))),
    app.Refresh(old),
    app.GameCreated(old, Ok(lobby_api.CreateGameResponse("other"))),
    app.GameJoined(old, "other", Ok(lobby_api.JoinGameResponse(True))),
    app.GameStarted(old, "other", Ok(lobby_api.StartGameResponse(True))),
    app.GameLeft(old, Ok(Nil)),
    app.GameCancelled(old, Ok(Nil)),
    app.PlayerKicked(old, "bob", Ok(Nil)),
    app.PlayerCooldownSet(old, "bob", 10, Ok(Nil)),
  ]
  list.each(stale_messages, fn(msg) {
    should.equal(step(revisited, msg), revisited)
  })
  let lobby = step(revisited, app.RouteChanged(app.CreateJoinGame))
  should.equal(step(lobby, app.Refresh(revisited.page_version)), lobby)
  should.equal(lobby.current_game, None)
}

pub fn mutations_require_login_and_errors_allow_retry_without_losing_the_list_test() {
  let lobby = model(app.CreateJoinGame)
  list.each(
    [
      player_info.PickingName,
      player_info.VerifyingName("alice"),
      player_info.NameAlreadyTaken("alice"),
    ],
    fn(player) {
      let unauthenticated = app.Model(..lobby, player: player)
      list.each(
        [
          app.CreateGamePressed,
          app.JoinGamePressed("room"),
          app.StartGamePressed("room"),
          app.LeaveGamePressed("room"),
          app.CancelGamePressed("room"),
        ],
        fn(msg) { should.equal(step(unauthenticated, msg), unauthenticated) },
      )
    },
  )
  let creating = step(lobby, app.CreateGamePressed)
  should.equal(creating.pending_action, True)
  should.equal(step(creating, app.CreateGamePressed), creating)
  let failed =
    step(
      creating,
      app.GameCreated(creating.page_version, Error(rsvp.NetworkError)),
    )
  should.equal(failed.pending_action, False)
  should.not_equal(failed.action_error, None)
  let games = [
    lobby_api.GameMetadata(
      "room",
      game.Negotiating,
      1,
      game.default_settings,
      None,
    ),
  ]
  let refreshed =
    step(
      failed,
      app.GamesLoaded(
        failed.page_version,
        Ok(lobby_api.ListGamesResponse(games, False)),
      ),
    )
  should.equal(refreshed.lobby_games, games)
  should.equal(refreshed.action_error, failed.action_error)
  let offline =
    step(
      refreshed,
      app.GamesLoaded(refreshed.page_version, Error(rsvp.NetworkError)),
    )
  should.equal(offline.lobby_games, games)
  let retrying = step(offline, app.CreateGamePressed)
  should.equal(retrying.pending_action, True)
  should.equal(retrying.action_error, None)
}

pub fn creation_settings_are_validated_and_selected_board_is_used_test() {
  let initial = model(app.CreateJoinGame)
  should.equal(app.creation_settings(initial), Ok(game.default_settings))
  let configured =
    initial
    |> step(app.GameTypeChanged("multiplayer"))
    |> step(app.BoardSizeChanged("13"))
    |> step(app.CooldownChanged("12"))
  let settings = game.Settings(13, game.MultiplayerGame, game.Cooldown(12))
  should.equal(app.creation_settings(configured), Ok(settings))
  list.each(["", "0", "61", "1.5"], fn(value) {
    let invalid = step(configured, app.CooldownChanged(value))
    should.equal(app.creation_settings(invalid), Error(Nil))
    let rejected = step(invalid, app.CreateGamePressed)
    should.equal(rejected.pending_action, False)
    should.not_equal(rejected.action_error, None)
  })
  let waiting = model(app.Play("custom"))
  let details =
    lobby_api.GameDetails(
      "custom",
      game.Started,
      "alice",
      ["alice", "bob"],
      2,
      settings,
      game.default_cooldowns(["alice", "bob"], settings),
      dict.new(),
    )
  let loaded =
    step(
      waiting,
      app.GameLoaded(
        waiting.page_version,
        Ok(lobby_api.GetGameResponse(details)),
      ),
    )
  should.equal(loaded.game.board_size, 13)
}

pub fn host_controls_keep_cooldown_drafts_stable_during_refresh_test() {
  let initial = model(app.Play("room"))
  let response = room("room", game.Negotiating, ["alice", "bob"])
  let loaded = step(initial, app.GameLoaded(initial.page_version, Ok(response)))
  let editing = step(loaded, app.PlayerCooldownChanged("bob", "15"))
  let html = editing |> app.view |> element.to_string
  should.equal(string.contains(html, "Set cooldown"), False)
  should.equal(string.contains(html, "Kick"), True)
  let assert Ok(host_row) =
    query.find(
      app.view(editing),
      query.element(query.attribute("data-player", "alice")),
    )
  let assert Ok(guest_row) =
    query.find(
      app.view(editing),
      query.element(query.attribute("data-player", "bob")),
    )
  should.equal(
    host_row |> element.to_string |> string.contains("disabled"),
    True,
  )
  should.equal(
    guest_row |> element.to_string |> string.contains("disabled"),
    False,
  )
  let refreshed =
    editing
    |> step(app.Refresh(editing.page_version))
    |> step(app.GameLoaded(editing.page_version, Ok(response)))
  should.equal(refreshed.cooldown_drafts, editing.cooldown_drafts)
  should.equal(refreshed |> app.view |> element.to_string, html)
  let guest =
    app.Model(..editing, player: player_info.LoggedIn("bob", "guest-jwt"))
  let guest_html = guest |> app.view |> element.to_string
  should.equal(string.contains(guest_html, "Set cooldown"), False)
  should.equal(string.contains(guest_html, "Kick"), False)
  list.each(
    [
      app.KickPlayerPressed("room", "alice"),
      app.SetPlayerCooldownPressed("room", "bob"),
    ],
    fn(msg) { should.equal(step(guest, msg), guest) },
  )
  should.equal(step(editing, app.KickPlayerPressed("room", "alice")), editing)
  list.each(["4", "0", "3601", "bad"], fn(value) {
    let rejected =
      editing
      |> step(app.PlayerCooldownChanged("bob", value))
      |> step(app.SetPlayerCooldownPressed("room", "bob"))
    should.equal(rejected.pending_action, False)
    should.not_equal(rejected.action_error, None)
  })
}

pub fn successful_host_changes_update_the_room_and_invalidate_old_polls_test() {
  let initial = model(app.Play("room"))
  let response = room("room", game.Negotiating, ["alice", "bob"])
  let loaded = step(initial, app.GameLoaded(initial.page_version, Ok(response)))
  let pending =
    loaded
    |> step(app.PlayerCooldownChanged("bob", "15"))
    |> step(app.SetPlayerCooldownPressed("room", "bob"))
  should.equal(pending.pending_action, True)
  should.equal(
    step(pending, app.SetPlayerCooldownPressed("room", "bob")),
    pending,
  )
  let failed =
    step(
      pending,
      app.PlayerCooldownSet(
        pending.page_version,
        "bob",
        15,
        Error(rsvp.NetworkError),
      ),
    )
  should.equal(failed.pending_action, False)
  should.equal(dict.get(failed.cooldown_drafts, "bob"), Ok("15"))
  let changed =
    step(
      pending,
      app.PlayerCooldownSet(pending.page_version, "bob", 15, Ok(Nil)),
    )
  should.equal(changed.pending_action, False)
  should.equal(dict.has_key(changed.cooldown_drafts, "bob"), False)
  let assert Some(details) = changed.current_game
  should.equal(dict.get(details.cooldowns, "bob"), Ok(15))
  should.equal(
    step(changed, app.GameLoaded(loaded.page_version, Ok(response))),
    changed,
  )
  let refreshed =
    step(
      changed,
      app.GameLoaded(
        changed.page_version,
        Ok(lobby_api.GetGameResponse(details)),
      ),
    )
  let kicking = step(refreshed, app.KickPlayerPressed("room", "bob"))
  should.equal(kicking.pending_action, True)
  should.equal(step(kicking, app.KickPlayerPressed("room", "bob")), kicking)
  let kicked =
    step(kicking, app.PlayerKicked(kicking.page_version, "bob", Ok(Nil)))
  let assert Some(remaining) = kicked.current_game
  should.equal(remaining.players, ["alice"])
  should.equal(remaining.player_count, 1)
  should.equal(dict.has_key(remaining.cooldowns, "bob"), False)
  should.equal(
    step(
      kicked,
      app.GameLoaded(
        kicking.page_version,
        Ok(lobby_api.GetGameResponse(details)),
      ),
    ),
    kicked,
  )
}

pub fn cooldown_autosave_waits_before_a_followup_action_and_skips_unchanged_values_test() {
  let initial = model(app.Play("room"))
  let response = room("room", game.Negotiating, ["alice", "bob"])
  let loaded = step(initial, app.GameLoaded(initial.page_version, Ok(response)))
  should.equal(
    step(loaded, app.SetPlayerCooldownPressed("room", "bob")),
    loaded,
  )
  let editing = step(loaded, app.PlayerCooldownChanged("bob", "15"))
  let simulation =
    simulate.application(
      fn(_) { #(editing, effect.none()) },
      app.update,
      app.view,
    )
    |> simulate.start(Nil)
  let input =
    query.element(query.attribute("aria-label", "Cooldown seconds for bob"))
  let blurred =
    simulation |> simulate.event(input, "blur", []) |> simulate.model
  should.equal(blurred.saving_cooldown, True)
  let entered =
    simulation
    |> simulate.event(input, "keydown", [#("key", json.string("Enter"))])
    |> simulate.model
  should.equal(entered.saving_cooldown, True)
  should.equal(
    simulation
      |> simulate.event(input, "keydown", [#("key", json.string("ArrowLeft"))])
      |> simulate.model,
    editing,
  )
  let pending =
    loaded
    |> step(app.PlayerCooldownChanged("bob", "15"))
    |> step(app.SetPlayerCooldownPressed("room", "bob"))
  list.each(
    [
      app.StartGamePressed("room"),
      app.KickPlayerPressed("room", "bob"),
      app.CancelGamePressed("room"),
    ],
    fn(action) {
      let queued = step(pending, action)
      should.equal(queued.after_save, Some(action))
      should.equal(step(queued, action), queued)
      let saved =
        step(
          queued,
          app.PlayerCooldownSet(queued.page_version, "bob", 15, Ok(Nil)),
        )
      should.equal(saved.after_save, None)
      should.equal(saved.saving_cooldown, False)
      should.equal(saved.pending_action, True)
      let failed =
        step(
          queued,
          app.PlayerCooldownSet(
            queued.page_version,
            "bob",
            15,
            Error(rsvp.NetworkError),
          ),
        )
      should.equal(failed.after_save, None)
      should.equal(failed.pending_action, False)
      should.equal(dict.get(failed.cooldown_drafts, "bob"), Ok("15"))
    },
  )
  let invalid =
    loaded
    |> step(app.PlayerCooldownChanged("bob", "bad"))
    |> step(app.SetPlayerCooldownPressed("room", "bob"))
    |> step(app.StartGamePressed("room"))
  should.equal(invalid.pending_action, False)
  should.not_equal(invalid.action_error, None)
}

pub fn leave_and_cancel_prevent_duplicate_actions_and_allow_retry_test() {
  let waiting = model(app.Play("room"))
  let version = waiting.page_version
  let rejected =
    Error(rsvp.HttpError(
      response.new(409)
      |> response.set_body("{\"msg\":\"The game has already started\"}"),
    ))
  list.each(
    [
      #(
        app.LeaveGamePressed("room"),
        app.GameLeft(version, rejected),
        app.GameLeft(version, Ok(Nil)),
      ),
      #(
        app.CancelGamePressed("room"),
        app.GameCancelled(version, rejected),
        app.GameCancelled(version, Ok(Nil)),
      ),
    ],
    fn(action) {
      let #(pressed, error, success) = action
      let pending = step(waiting, pressed)
      should.equal(pending.pending_action, True)
      should.equal(step(pending, pressed), pending)
      let failed = step(pending, error)
      should.equal(failed.pending_action, False)
      should.equal(failed.action_error, Some("The game has already started"))
      let retried = step(failed, pressed)
      should.equal(retried.action_error, None)
      should.equal(step(retried, success).pending_action, False)
    },
  )
}

pub fn login_preserves_a_shared_room_link_test() {
  // Client decoding is deliberately unsigned; server verification is covered by
  // the API tests. Effects (including localStorage writes) aren't run here.
  let jwt =
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhbGljZSIsImV4cCI6MjAwMDAwMDAwMH0.c2lnbmF0dXJl"
  let model =
    app.initial_model(
      app.Play("shared"),
      player_info.PickingName,
      "https://rtgo.test",
    )
  let logged_in = step(model, app.LoggedInResponse(Ok(auth.LogInResponse(jwt))))
  should.equal(logged_in.route, app.Play("shared"))
  should.equal(logged_in.player, player_info.LoggedIn("alice", jwt))
}
