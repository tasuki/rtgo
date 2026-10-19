import gleam/bit_array
import gleam/dict
import gleam/erlang/process
import gleam/http.{Options, Post}
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/time/duration
import gleeunit/should
import rtgo_server/game as running_game
import rtgo_server/lobby
import rtgo_server/players
import rtgo_server/test_support.{read_json, test_sign_key}
import rtgo_shared/auth
import rtgo_shared/auth_api
import rtgo_shared/game
import rtgo_shared/lobby_api
import rtgo_shared/player
import ywt
import ywt/claim
import ywt/sign_key

const url = "https://rtgo.test"

type Send =
  fn(request.Request(String)) -> response.Response(String)

fn server() -> Send {
  let actor = players.start(test_sign_key())
  let rooms = lobby.start()
  test_support.send(_, actor, rooms)
}

fn register(send: Send, name: String) -> String {
  let auth.LogInResponse(jwt) =
    auth_api.register_request(url, name)
    |> send
    |> read_json(auth.log_in_response_decoder)
  jwt
}

fn create(send: Send, jwt: String, settings: game.Settings) -> String {
  let lobby_api.CreateGameResponse(id) =
    lobby_api.create_game_request(url, jwt, settings)
    |> send
    |> read_json(lobby_api.create_game_response_decoder)
  id
}

fn details(send: Send, id: String) -> lobby_api.GameDetails {
  let lobby_api.GetGameResponse(game) =
    lobby_api.game_request(url, id)
    |> send
    |> read_json(lobby_api.get_game_response_decoder)
  game
}

pub fn finished_games_are_listed_by_start_time_newest_first_test() {
  let users = players.start(test_sign_key())
  let rooms = lobby.start()
  let settings = game.Settings(9, game.TwoPlayerGame, game.DragDerby)
  list.each(list.range(1, 3), fn(_) {
    let assert Ok(id) = lobby.create_game(rooms, "host", settings)
    let assert Ok(True) = lobby.join_game(rooms, id, "guest")
  })
  // Start in the dictionary's original order, so reversing it is observably
  // different. All starts occur within the same minute in ordinary test runs.
  let ids =
    rooms |> lobby.list_games |> dict.to_list |> list.map(fn(entry) { entry.0 })
  list.each(ids, fn(id) {
    let assert Ok(True) = lobby.start_game(rooms, id, "host")
    process.sleep(2)
  })
  // Finish in the opposite order: sorting must use start dates, not end dates.
  list.each(list.reverse(ids), fn(id) {
    let assert Ok(lobby.Running(subject:, ..)) = lobby.get_game(rooms, id)
    let assert Ok(_) = running_game.pass(subject, "host")
    let assert Ok(_) = running_game.pass(subject, "guest")
  })
  let lobby_api.ListGamesResponse(games) =
    lobby_api.games_request(url)
    |> test_support.send(users, rooms)
    |> read_json(lobby_api.list_games_response_decoder)
  should.equal(list.map(games, fn(game) { game.phase }), [
    game.Finished,
    game.Finished,
    game.Finished,
  ])
  should.equal(list.map(games, fn(game) { game.id }), list.reverse(ids))
}

pub fn lobby_lifecycle_through_client_api_test() {
  let send = server()
  let host = register(send, "zoe")
  let guest = register(send, "alice")
  let settings = game.Settings(9, game.TwoPlayerGame, game.Cooldown(3))
  let id = create(send, host, settings)
  should.equal(
    lobby_api.games_request(url)
      |> send
      |> read_json(lobby_api.list_games_response_decoder),
    lobby_api.ListGamesResponse([
      lobby_api.GameMetadata(id, game.Negotiating, 1, settings),
    ]),
  )
  should.equal(
    lobby_api.start_game_request(url, id, host)
      |> send
      |> read_json(lobby_api.start_game_response_decoder),
    lobby_api.StartGameResponse(False),
  )
  list.each([1, 2], fn(_) {
    should.equal(
      lobby_api.join_game_request(url, id, guest)
        |> send
        |> read_json(lobby_api.join_game_response_decoder),
      lobby_api.JoinGameResponse(True),
    )
  })
  let third = register(send, "bob")
  should.equal(
    lobby_api.join_game_request(url, id, third)
      |> send
      |> read_json(lobby_api.join_game_response_decoder),
    lobby_api.JoinGameResponse(False),
  )
  let impostor =
    lobby_api.start_game_request(url, id, guest)
    |> request.set_body("{\"username\":\"zoe\"}")
    |> send
  should.equal(impostor.status, 403)
  let open = details(send, id)
  should.equal(
    open,
    lobby_api.GameDetails(
      id,
      game.Negotiating,
      "zoe",
      ["alice", "zoe"],
      2,
      settings,
      game.default_cooldowns(["alice", "zoe"], settings),
      dict.from_list([#("zoe", player.Black), #("alice", player.White)]),
    ),
  )
  should.equal(
    lobby_api.start_game_request(url, id, host)
      |> send
      |> read_json(lobby_api.start_game_response_decoder),
    lobby_api.StartGameResponse(True),
  )
  should.equal(
    details(send, id),
    lobby_api.GameDetails(..open, phase: game.Started),
  )
  should.equal(
    lobby_api.games_request(url)
      |> send
      |> read_json(lobby_api.list_games_response_decoder),
    lobby_api.ListGamesResponse([
      lobby_api.GameMetadata(id, game.Started, 2, settings),
    ]),
  )
  should.equal(
    lobby_api.join_game_request(url, id, guest)
      |> send
      |> read_json(lobby_api.join_game_response_decoder),
    lobby_api.JoinGameResponse(False),
  )
  should.equal(
    lobby_api.start_game_request(url, id, host)
      |> send
      |> read_json(lobby_api.start_game_response_decoder),
    lobby_api.StartGameResponse(False),
  )
  list.each(
    [
      lobby_api.leave_game_request(url, id, guest),
      lobby_api.leave_game_request(url, id, host),
      lobby_api.cancel_game_request(url, id, host),
    ],
    fn(req) { should.equal(send(req).status, 409) },
  )
  should.equal(send(lobby_api.cancel_game_request(url, id, guest)).status, 403)
  should.equal(details(send, id).player_count, 2)
}

pub fn guests_can_leave_and_rejoin_but_only_host_can_cancel_test() {
  let send = server()
  let host = register(send, "host")
  let guest = register(send, "guest")
  let settings = game.Settings(13, game.MultiplayerGame, game.Cooldown(10))
  let id = create(send, host, settings)
  should.equal(send(lobby_api.join_game_request(url, id, guest)).status, 200)
  should.equal(send(lobby_api.cancel_game_request(url, id, guest)).status, 403)
  should.equal(send(lobby_api.leave_game_request(url, id, host)).status, 409)
  list.each([1, 2], fn(_) {
    should.equal(send(lobby_api.leave_game_request(url, id, guest)).status, 204)
  })
  should.equal(
    details(send, id),
    lobby_api.GameDetails(
      id,
      game.Negotiating,
      "host",
      ["host"],
      1,
      settings,
      game.default_cooldowns(["host"], settings),
      dict.from_list([#("host", player.Black)]),
    ),
  )
  should.equal(
    lobby_api.start_game_request(url, id, host)
      |> send
      |> read_json(lobby_api.start_game_response_decoder),
    lobby_api.StartGameResponse(False),
  )
  should.equal(send(lobby_api.join_game_request(url, id, guest)).status, 200)
  let third = register(send, "third")
  should.equal(
    lobby_api.join_game_request(url, id, third)
      |> send
      |> read_json(lobby_api.join_game_response_decoder),
    lobby_api.JoinGameResponse(True),
  )
  should.equal(details(send, id).player_count, 3)
  should.equal(send(lobby_api.cancel_game_request(url, id, host)).status, 204)
  should.equal(send(lobby_api.game_request(url, id)).status, 404)
  should.equal(send(lobby_api.leave_game_request(url, id, guest)).status, 404)
  should.equal(send(lobby_api.cancel_game_request(url, id, host)).status, 404)
  should.equal(
    lobby_api.games_request(url)
      |> send
      |> read_json(lobby_api.list_games_response_decoder),
    lobby_api.ListGamesResponse([]),
  )
}

pub fn host_can_kick_and_handicap_waiting_players_test() {
  let send = server()
  let host = register(send, "host")
  let guest = register(send, "guest")
  let replacement = register(send, "replacement")
  let id = create(send, host, game.default_settings)
  should.equal(send(lobby_api.join_game_request(url, id, guest)).status, 200)
  list.each(
    [
      lobby_api.kick_player_request(url, id, guest, "host"),
      lobby_api.player_cooldown_request(url, id, guest, "guest", 15),
    ],
    fn(req) { should.equal(send(req).status, 403) },
  )
  should.equal(
    send(lobby_api.kick_player_request(url, id, host, "host")).status,
    409,
  )
  should.equal(
    send(lobby_api.kick_player_request(url, id, host, "missing")).status,
    404,
  )
  should.equal(
    send(lobby_api.player_cooldown_request(url, id, host, "missing", 10)).status,
    404,
  )
  list.each([0, -1, 4, 3601], fn(seconds) {
    should.equal(
      send(lobby_api.player_cooldown_request(url, id, host, "guest", seconds)).status,
      400,
    )
  })
  let malformed =
    lobby_api.player_cooldown_request(url, id, host, "guest", 10)
    |> request.set_body(
      "{\"player\":\"guest\",\"cooldown_seconds\":\"not a number\"}",
    )
    |> send
  should.equal(malformed.status, 400)
  should.equal(
    send(lobby_api.player_cooldown_request(url, id, host, "guest", 15)).status,
    204,
  )
  should.equal(
    send(lobby_api.player_cooldown_request(url, id, host, "host", 8)).status,
    204,
  )
  let adjusted = details(send, id)
  should.equal(
    adjusted.cooldowns,
    dict.from_list([#("host", 8), #("guest", 15)]),
  )
  // A retry of join, or leaving and rejoining, cannot discard a handicap.
  should.equal(send(lobby_api.join_game_request(url, id, guest)).status, 200)
  should.equal(details(send, id).cooldowns, adjusted.cooldowns)
  should.equal(send(lobby_api.leave_game_request(url, id, guest)).status, 204)
  should.equal(details(send, id).cooldowns, dict.from_list([#("host", 8)]))
  should.equal(send(lobby_api.join_game_request(url, id, guest)).status, 200)
  should.equal(details(send, id).cooldowns, adjusted.cooldowns)
  should.equal(
    send(lobby_api.kick_player_request(url, id, host, "guest")).status,
    204,
  )
  should.equal(details(send, id).players, ["host"])
  should.equal(details(send, id).cooldowns, dict.from_list([#("host", 8)]))
  should.equal(send(lobby_api.join_game_request(url, id, guest)).status, 403)
  should.equal(
    lobby_api.join_game_request(url, id, replacement)
      |> send
      |> read_json(lobby_api.join_game_response_decoder),
    lobby_api.JoinGameResponse(True),
  )
  should.equal(send(lobby_api.start_game_request(url, id, host)).status, 200)
  let started = details(send, id)
  should.equal(started.phase, game.Started)
  should.equal(
    started.cooldowns,
    dict.from_list([#("host", 8), #("replacement", 5)]),
  )
  list.each(
    [
      lobby_api.kick_player_request(url, id, host, "replacement"),
      lobby_api.player_cooldown_request(url, id, host, "replacement", 20),
    ],
    fn(req) { should.equal(send(req).status, 409) },
  )
  should.equal(details(send, id), started)
}

pub fn invalid_settings_are_rejected_without_creating_rooms_test() {
  let send = server()
  let host = register(send, "host")
  list.each(
    [
      game.Settings(8, game.TwoPlayerGame, game.Cooldown(5)),
      game.Settings(19, game.TwoPlayerGame, game.Cooldown(0)),
      game.Settings(19, game.MultiplayerGame, game.Cooldown(61)),
    ],
    fn(settings) {
      should.equal(
        send(lobby_api.create_game_request(url, host, settings)).status,
        400,
      )
    },
  )
  let unknown_type =
    lobby_api.create_game_request(url, host, game.default_settings)
    |> request.set_body(
      "{\"game_type\":\"unknown\",\"board_size\":19,\"cooldown_seconds\":5}",
    )
    |> send
  should.equal(unknown_type.status, 400)
  should.equal(
    lobby_api.games_request(url)
      |> send
      |> read_json(lobby_api.list_games_response_decoder),
    lobby_api.ListGamesResponse([]),
  )
}

pub fn mutations_require_a_valid_signed_unexpired_token_test() {
  let send = server()
  let host = register(send, "host")
  let id = create(send, host, game.default_settings)
  let expired =
    ywt.encode(
      [],
      [
        claim.subject("host", []),
        claim.expires_at(duration.seconds(-60), duration.seconds(0)),
      ],
      test_sign_key(),
    )
  let assert Ok(other_key) =
    sign_key.hs256(bit_array.from_string(
      "a-different-server-key-0123456789abcdef",
    ))
  let other_server = players.start(other_key)
  let assert Ok(auth.LogInResponse(forged)) =
    players.try_register(other_server, "host")
  list.each(
    ["", "Bearer invalid", "Bearer " <> expired, "Bearer " <> forged],
    fn(header) {
      list.each(
        [
          lobby_api.create_game_request(url, host, game.default_settings),
          lobby_api.join_game_request(url, id, host),
          lobby_api.start_game_request(url, id, host),
          lobby_api.leave_game_request(url, id, host),
          lobby_api.cancel_game_request(url, id, host),
          lobby_api.kick_player_request(url, id, host, "host"),
          lobby_api.player_cooldown_request(url, id, host, "host", 10),
        ],
        fn(req) {
          let res =
            req
            |> request.set_header("authorization", header)
            |> request.set_body("{\"username\":\"host\"}")
            |> send
          should.equal(res.status, 401)
        },
      )
    },
  )
  should.equal(details(send, id).players, ["host"])
}

pub fn missing_games_and_cors_test() {
  let send = server()
  let jwt = register(send, "alice")
  list.each(
    [
      lobby_api.game_request(url, "missing"),
      lobby_api.join_game_request(url, "missing", jwt),
      lobby_api.start_game_request(url, "missing", jwt),
      lobby_api.leave_game_request(url, "missing", jwt),
      lobby_api.cancel_game_request(url, "missing", jwt),
      lobby_api.kick_player_request(url, "missing", jwt, "alice"),
      lobby_api.player_cooldown_request(url, "missing", jwt, "alice", 10),
    ],
    fn(req) { should.equal(send(req).status, 404) },
  )
  let preflight =
    lobby_api.create_game_request(url, jwt, game.default_settings)
    |> request.set_method(Options)
    |> request.set_header("origin", "https://client.test")
    |> request.set_header("access-control-request-method", "POST")
    |> request.set_header("access-control-request-headers", "authorization")
    |> send
  should.equal(preflight.status, 200)
  should.equal(
    response.get_header(preflight, "access-control-allow-origin"),
    Ok("https://client.test"),
  )
  should.equal(
    response.get_header(preflight, "access-control-allow-headers"),
    Ok("content-type, authorization"),
  )
  let assert Ok(req) = request.to(url <> "/games")
  should.equal(send(request.set_method(req, Post)).status, 401)
}
