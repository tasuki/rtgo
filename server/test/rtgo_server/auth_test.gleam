import gleam/dynamic/decode
import gleam/http.{Post}
import gleam/json
import gleeunit/should
import rtgo_server/lobby
import rtgo_server/players
import rtgo_server/router
import rtgo_server/test_support.{
  read_json as read_client_json, send as run_client_request, test_sign_key,
}
import rtgo_shared/auth
import rtgo_shared/auth_api
import rtgo_shared/player
import wisp
import wisp/simulate
import ywt

pub fn registration_and_login_test() {
  let actor = players.start(test_sign_key())
  let lobby_actor = lobby.start()

  let register_response =
    router.handle(actor, lobby_actor, register_request("alice"))
  should.equal(register_response.status, 200)

  let first_login =
    register_response
    |> read_json(auth.log_in_response_decoder)
  should.equal(validate_jwt_username(first_login.jwt), Ok("alice"))

  let login_response =
    router.handle(actor, lobby_actor, login_request(first_login.jwt))
  should.equal(login_response.status, 200)

  let second_login =
    login_response
    |> read_json(auth.log_in_response_decoder)
  should.equal(validate_jwt_username(second_login.jwt), Ok("alice"))
}

pub fn duplicate_registration_returns_conflict_test() {
  let actor = players.start(test_sign_key())
  let lobby_actor = lobby.start()

  let _ = router.handle(actor, lobby_actor, register_request("alice"))
  let response = router.handle(actor, lobby_actor, register_request("alice"))

  should.equal(response.status, 409)
  should.equal(
    read_json(response, auth.registration_failed_response_decoder),
    auth.RegistrationFailedResponse("alice"),
  )
}

pub fn client_registration_flow_test() {
  let actor = players.start(test_sign_key())
  let lobby_actor = lobby.start()
  let server_url = "https://rtgo.test"

  let register_response =
    auth_api.register_request(server_url, "alice")
    |> run_client_request(actor, lobby_actor)
  should.equal(register_response.status, 200)

  let first_login =
    register_response
    |> read_client_json(auth.log_in_response_decoder)
  should.equal(validate_jwt_username(first_login.jwt), Ok("alice"))

  let log_in_response =
    auth_api.log_in_request(server_url, first_login.jwt)
    |> run_client_request(actor, lobby_actor)
  should.equal(log_in_response.status, 200)

  let second_login =
    log_in_response
    |> read_client_json(auth.log_in_response_decoder)
  should.equal(validate_jwt_username(second_login.jwt), Ok("alice"))
}

pub fn invalid_login_returns_bad_request_test() {
  let actor = players.start(test_sign_key())
  let lobby_actor = lobby.start()

  let response = router.handle(actor, lobby_actor, login_request("not-a-jwt"))

  should.equal(response.status, 400)
  let failure = read_json(response, auth.log_in_failed_response_decoder)
  should.not_equal(failure.msg, "")
}

fn register_request(username: String) {
  simulate.request(Post, auth_api.register_path)
  |> simulate.json_body(
    auth.registration_request_to_json(auth.RegistrationRequest(
      username,
      player.Black,
    )),
  )
}

fn login_request(jwt: String) {
  simulate.request(Post, auth_api.log_in_path)
  |> simulate.json_body(auth.log_in_request_to_json(auth.LogInRequest(jwt)))
}

fn read_json(response: wisp.Response, decoder: fn() -> decode.Decoder(a)) -> a {
  let body = simulate.read_body(response)
  let assert Ok(value) = json.parse(body, decoder())
  value
}

fn validate_jwt_username(jwt: String) {
  case ywt.decode_unsafely_without_validation(jwt, auth.jwt_decoder()) {
    Ok(#(username, _exp)) -> Ok(username)
    Error(_) -> Error(Nil)
  }
}
