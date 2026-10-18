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

pub fn passing_is_authenticated_reversible_and_finishes_atomically_test() {
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
  let settings = game.Settings(9, game.TwoPlayerGame, game.DragDerby)
  let lobby_api.CreateGameResponse(id) =
    lobby_api.create_game_request(url, host, settings)
    |> send
    |> read_json(lobby_api.create_game_response_decoder)
  should.equal(send(play_api.pass_request(url, "missing", host)).status, 404)
  should.equal(send(play_api.pass_request(url, id, host)).status, 409)
  should.equal(send(lobby_api.join_game_request(url, id, guest)).status, 200)
  should.equal(send(lobby_api.start_game_request(url, id, host)).status, 200)
  should.equal(send(play_api.pass_request(url, id, "")).status, 401)
  should.equal(send(play_api.pass_request(url, id, outsider)).status, 403)
  let passed =
    play_api.pass_request(url, id, host)
    |> request.set_body("{\"username\":\"guest\"}")
    |> send
    |> read_json(play_api.state_decoder)
  let assert Ok(host_status) =
    list.find(passed.players, fn(s) { s.player.username == "host" })
  let assert Ok(guest_status) =
    list.find(passed.players, fn(s) { s.player.username == "guest" })
  should.equal(host_status.pass_in_ms, 0)
  should.equal(guest_status.pass_in_ms > 0, True)
  should.equal(passed.finished, False)
  let resumed =
    play_api.move_request(url, id, host, #(0, 0))
    |> send
    |> read_json(play_api.state_decoder)
  let assert Ok(status) =
    list.find(resumed.players, fn(s) { s.player.username == "host" })
  should.equal(status.pass_in_ms > 0, True)
  should.equal(send(play_api.pass_request(url, id, guest)).status, 200)
  let finished =
    play_api.pass_request(url, id, host)
    |> send
    |> read_json(play_api.state_decoder)
  should.equal(finished.finished, True)
  should.equal(send(play_api.move_request(url, id, host, #(1, 0))).status, 409)
  should.equal(send(play_api.pass_request(url, id, guest)).status, 409)
}
