import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/json
import gleam/uri
import rtgo_shared/auth
import rtgo_shared/player

pub const register_path = "/register"

pub const log_in_path = "/log_in"

pub fn path_segments(path: String) -> List(String) {
  case uri.path_segments(path) {
    [""] -> []
    segments -> segments
  }
}

pub fn register_request(
  server_url: String,
  username: String,
) -> request.Request(String) {
  register_request_with_color(server_url, username, player.Black)
}

pub fn register_request_with_color(
  server_url: String,
  username: String,
  color: player.Color,
) -> request.Request(String) {
  let assert Ok(uri) = uri.parse(server_url <> register_path)
  let assert Ok(req) = request.from_uri(uri)

  req
  |> request.set_method(Post)
  |> request.set_header("content-type", "application/json")
  |> request.set_body(
    json.to_string(
      auth.registration_request_to_json(auth.RegistrationRequest(
        username,
        color,
      )),
    ),
  )
}

pub fn preferred_color_request(
  server_url: String,
  jwt: String,
) -> request.Request(String) {
  let assert Ok(req) = request.to(server_url <> "/profile/color")
  req
  |> request.set_method(Get)
  |> request.set_header("authorization", "Bearer " <> jwt)
}

pub fn set_preferred_color_request(
  server_url: String,
  jwt: String,
  color: player.Color,
) -> request.Request(String) {
  preferred_color_request(server_url, jwt)
  |> request.set_method(Post)
  |> request.set_header("content-type", "application/json")
  |> request.set_body(json.to_string(preferred_color_to_json(color)))
}

pub fn preferred_color_to_json(color: player.Color) -> json.Json {
  json.object([#("preferred_color", player.color_to_json(color))])
}

pub fn preferred_color_decoder() -> decode.Decoder(player.Color) {
  use color <- decode.field("preferred_color", player.color_decoder())
  decode.success(color)
}

pub fn log_in_request(
  server_url: String,
  jwt: String,
) -> request.Request(String) {
  let assert Ok(uri) = uri.parse(server_url <> log_in_path)
  let assert Ok(req) = request.from_uri(uri)

  req
  |> request.set_method(Post)
  |> request.set_header("content-type", "application/json")
  |> request.set_body(
    json.to_string(auth.log_in_request_to_json(auth.LogInRequest(jwt))),
  )
}
