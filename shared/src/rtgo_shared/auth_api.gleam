import gleam/http.{Post}
import gleam/http/request
import gleam/json
import gleam/uri
import rtgo_shared/auth

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
  let assert Ok(uri) = uri.parse(server_url <> register_path)
  let assert Ok(req) = request.from_uri(uri)

  req
  |> request.set_method(Post)
  |> request.set_header("content-type", "application/json")
  |> request.set_body(
    json.to_string(
      auth.registration_request_to_json(auth.RegistrationRequest(username)),
    ),
  )
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
