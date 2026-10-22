import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleeunit/should
import rtgo_server/game
import rtgo_server/lobby
import rtgo_server/players
import rtgo_server/router
import wisp/simulate
import ywt/sign_key

pub fn test_sign_key() {
  let assert Ok(key) =
    sign_key.hs256(bit_array.from_string(
      "integration-test-sign-key-0123456789abcdef",
    ))
  key
}

/// Live-actor tests wait for the advertised opening cooldown. Exact timing
/// boundaries are covered by the pure game_timing tests without sleeping.
pub fn wait_until_ready(
  subject: process.Subject(game.Message),
  name: String,
) -> Nil {
  let assert Ok(status) =
    game.get_game(subject).live.players
    |> list.find(fn(status) { status.player.username == name })
  process.sleep(status.cooldown_ms)
}

/// Exercise the same request builders and response decoders as the browser.
pub fn send(
  client_request: request.Request(String),
  actor: process.Subject(players.Message),
  lobby_actor: process.Subject(lobby.Message),
) -> response.Response(String) {
  let request.Request(method:, headers:, body:, path:, ..) = client_request
  let base_request = case body {
    "" -> simulate.request(method, path)
    _ -> simulate.request(method, path) |> simulate.string_body(body)
  }
  let server_request =
    list.fold(headers, base_request, fn(req, header) {
      request.set_header(req, header.0, header.1)
    })
  let server_request =
    request.Request(..server_request, query: client_request.query)
  let server_response = router.handle(actor, lobby_actor, server_request)
  response.Response(
    status: server_response.status,
    headers: server_response.headers,
    body: simulate.read_body(server_response),
  )
}

pub fn read_json(
  response: response.Response(String),
  decoder: fn() -> decode.Decoder(a),
) -> a {
  should.equal(response.status, 200)
  let assert Ok(value) = json.parse(response.body, decoder())
  value
}
