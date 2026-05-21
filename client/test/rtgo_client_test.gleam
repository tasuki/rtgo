import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
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
        ),
      ],
    ],
    fn(games) {
      let response =
        app.GamesLoaded(
          initial.page_version,
          Ok(lobby_api.ListGamesResponse(games)),
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
  should.equal(missing.loading_game, False)
  should.equal(
    missing.load_error,
    Some("Game not found. It may have been cancelled."),
  )
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
    app.GamesLoaded(old, Ok(lobby_api.ListGamesResponse([]))),
    app.Refresh(old),
    app.GameCreated(old, Ok(lobby_api.CreateGameResponse("other"))),
    app.GameJoined(old, "other", Ok(lobby_api.JoinGameResponse(True))),
    app.GameStarted(old, "other", Ok(lobby_api.StartGameResponse(True))),
    app.GameLeft(old, Ok(Nil)),
    app.GameCancelled(old, Ok(Nil)),
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
    lobby_api.GameMetadata("room", game.Negotiating, 1, game.default_settings),
  ]
  let refreshed =
    step(
      failed,
      app.GamesLoaded(
        failed.page_version,
        Ok(lobby_api.ListGamesResponse(games)),
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
