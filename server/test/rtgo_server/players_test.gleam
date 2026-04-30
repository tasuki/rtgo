import gleam/bit_array
import gleeunit/should
import rtgo_server/players
import rtgo_shared/auth
import ywt/sign_key

fn test_players() {
  let assert Ok(key) =
    sign_key.hs256(bit_array.from_string("01234567890123456789012345678901"))
  players.start(key)
}

pub fn register_test() {
  let subject = test_players()

  let assert Ok(auth.LogInResponse(jwt)) =
    players.try_register(subject, "alice")

  jwt |> should.not_equal("")
}

pub fn log_in_test() {
  let subject = test_players()

  let assert Ok(auth.LogInResponse(jwt)) =
    players.try_register(subject, "alice")

  players.try_login(subject, jwt)
  |> should.be_ok()
}

pub fn duplicate_name_is_rejected_while_registered_test() {
  let subject = test_players()

  let assert Ok(_) = players.try_register(subject, "alice")

  players.try_register(subject, "alice")
  |> should.equal(Error(auth.RegistrationFailedResponse("alice")))
}
