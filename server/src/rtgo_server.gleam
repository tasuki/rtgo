import envoy
import gleam/erlang/process
import gleam/int
import gleam/result
import mist
import router
import wisp/wisp_mist

pub fn main() -> Nil {
  let assert Ok(secret_key_base) = envoy.get("SECRET_KEY_BASE")
  let assert Ok(port) = envoy.get("SERVER_PORT") |> result.try(int.parse)

  let assert Ok(_) =
    wisp_mist.handler(router.handle, secret_key_base)
    |> mist.new
    |> mist.port(port)
    |> mist.start()

  process.sleep_forever()
}
