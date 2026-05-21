import gleam/bit_array
import gleam/http.{Options, Post}
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/time/duration
import gleeunit/should
import rtgo_server/lobby
import rtgo_server/players
import rtgo_server/test_support.{read_json, test_sign_key}
import rtgo_shared/auth
import rtgo_shared/auth_api
import rtgo_shared/game
import rtgo_shared/lobby_api
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
    lobby_api.GameDetails(id, game.Negotiating, "host", ["host"], 1, settings),
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
