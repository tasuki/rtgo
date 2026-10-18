import gleam/dict
import gleam/http/request
import gleam/list
import gleeunit/should
import rtgo_server/lobby
import rtgo_server/players
import rtgo_server/test_support.{read_json, test_sign_key}
import rtgo_shared/auth
import rtgo_shared/auth_api
import rtgo_shared/game
import rtgo_shared/lobby_api
import rtgo_shared/play_api

const url = "https://rtgo.test"

pub fn browser_move_lifecycle_is_authenticated_and_authoritative_test() {
  let users = players.start(test_sign_key())
  let rooms = lobby.start()
  let send = test_support.send(_, users, rooms)
  let auth.LogInResponse(host) =
    auth_api.register_request(url, "host")
    |> send
    |> read_json(auth.log_in_response_decoder)
  let auth.LogInResponse(guest) =
    auth_api.register_request(url, "guest")
    |> send
    |> read_json(auth.log_in_response_decoder)
  let auth.LogInResponse(outsider) =
    auth_api.register_request(url, "outsider")
    |> send
    |> read_json(auth.log_in_response_decoder)
  let settings =
    game.Settings(..game.default_settings, time_settings: game.Cooldown(1))
  let lobby_api.CreateGameResponse(id) =
    lobby_api.create_game_request(url, host, settings)
    |> send
    |> read_json(lobby_api.create_game_response_decoder)

  should.equal(send(play_api.state_request(url, "missing")).status, 404)
  should.equal(
    send(play_api.move_request(url, "missing", host, #(0, 0))).status,
    404,
  )
  should.equal(send(play_api.state_request(url, id)).status, 409)
  should.equal(send(play_api.move_request(url, id, host, #(0, 0))).status, 409)
  should.equal(send(lobby_api.join_game_request(url, id, guest)).status, 200)
  should.equal(send(lobby_api.start_game_request(url, id, host)).status, 200)
  let opening =
    play_api.state_request(url, id) |> send |> read_json(play_api.state_decoder)
  should.equal(opening.revision, 0)
  should.equal(dict.is_empty(opening.board.stones), True)
  should.equal(
    list.all(opening.players, fn(status) {
      status.cooldown_ms > 0
      && status.cooldown_ms <= 1000
      && status.pass_in_ms == status.cooldown_ms + 10_000
    }),
    True,
  )
  should.equal(send(play_api.move_request(url, id, host, #(0, 0))).status, 409)

  list.each(["", "invalid"], fn(jwt) {
    should.equal(send(play_api.move_request(url, id, jwt, #(0, 0))).status, 401)
  })
  should.equal(
    send(play_api.move_request(url, id, outsider, #(0, 0))).status,
    403,
  )
  let assert Ok(lobby.Running(subject:, ..)) = lobby.get_game(rooms, id)
  test_support.wait_until_ready(subject, "host")
  should.equal(send(play_api.move_request(url, id, host, #(-1, 0))).status, 409)
  should.equal(send(play_api.move_request(url, id, host, #(19, 0))).status, 409)
  let malformed =
    play_api.move_request(url, id, host, #(0, 0))
    |> request.set_body("{\"x\":1.5,\"y\":0}")
    |> send
  should.equal(malformed.status, 400)
  let played =
    play_api.move_request(url, id, host, #(0, 0))
    |> send
    |> read_json(play_api.state_decoder)
  should.equal(played.revision, 1)
  should.equal(played.finished, False)
  should.equal(dict.size(played.board.stones), 1)
  let assert Ok(p) = dict.get(played.board.stones, #(0, 0))
  should.equal(p.username, "host")
  let assert Ok(status) =
    list.find(played.players, fn(s) { s.player.username == "host" })
  should.equal(status.cooldown_ms > 0, True)
  should.equal(status.pass_in_ms > 10_000, True)
  should.equal(send(play_api.move_request(url, id, host, #(1, 0))).status, 409)
  // A conflicting move is rejected atomically and does not consume the guest's move.
  should.equal(send(play_api.move_request(url, id, guest, #(0, 0))).status, 409)
  let reply =
    play_api.move_request(url, id, guest, #(1, 0))
    |> request.set_body("{\"x\":1,\"y\":0,\"username\":\"host\"}")
    |> send
    |> read_json(play_api.state_decoder)
  should.equal(reply.revision, 2)
  let assert Ok(p) = dict.get(reply.board.stones, #(1, 0))
  should.equal(p.username, "guest")
  let observed =
    play_api.state_request(url, id) |> send |> read_json(play_api.state_decoder)
  should.equal(observed.board.stones, reply.board.stones)
  should.equal(observed.revision, 2)
}
