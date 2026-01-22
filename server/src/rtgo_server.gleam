import envoy
import gleam/erlang/process
import gleam/int
import gleam/result
import logging
import mist
import players
import router
import wisp/wisp_mist

pub fn main() -> Nil {
  logging.configure()
  let debug_level = case envoy.get("DEBUG_LEVEL") {
    Ok("DEBUG") -> logging.Debug
    _ -> logging.Info
  }
  logging.set_level(debug_level)

  let assert Ok(secret_key_base) = envoy.get("SECRET_KEY_BASE")
  let assert Ok(port) = envoy.get("SERVER_PORT") |> result.try(int.parse)
  let players_actor = players.start()

  let assert Ok(_) =
    wisp_mist.handler(router.handle(players_actor, _), secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.start()

  process.sleep_forever()
}
