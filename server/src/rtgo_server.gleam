import envoy
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/result
import logging
import mist
import rtgo_server/players
import rtgo_server/router
import wisp/wisp_mist
import ywt/sign_key

pub fn main() -> Nil {
  logging.configure()
  let debug_level = case envoy.get("DEBUG_LEVEL") {
    Ok("DEBUG") -> logging.Debug
    _ -> logging.Info
  }
  logging.set_level(debug_level)

  let assert Ok(secret_key) = envoy.get("SECRET_KEY_BASE")
  let assert Ok(port) = envoy.get("SERVER_PORT") |> result.try(int.parse)
  let assert Ok(sign_key_secret) =
    envoy.get("SIGN_KEY") |> result.map(bit_array.from_string)

  let assert Ok(sign_key) = sign_key.hs256(sign_key_secret)
  let players_actor = players.start(sign_key)

  let assert Ok(_) =
    wisp_mist.handler(router.handle(players_actor, _), secret_key)
    |> mist.new
    |> mist.port(port)
    |> mist.start()

  process.sleep_forever()
}
