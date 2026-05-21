import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{Options}
import gleam/http/request
import gleam/http/response
import gleam/json.{type Json}
import gleam/result
import gleam/string
import rtgo_server/players
import wisp.{type Request, type Response}

pub type JsonData =
  List(#(String, Json))

pub fn json_response(response_code: Int, data: JsonData) -> Response {
  json.object(data)
  |> json.to_string()
  |> wisp.json_response(response_code)
}

pub fn json_response_obj(response_code: Int, data: Json) -> Response {
  json.to_string(data)
  |> wisp.json_response(response_code)
}

pub fn on_json(
  req: Request,
  decoder: fn() -> decode.Decoder(a),
  on_ok: fn(a) -> response.Response(wisp.Body),
) -> response.Response(wisp.Body) {
  use req_json <- wisp.require_json(req)
  case decode.run(req_json, decoder()) {
    Error(_) ->
      json_response(400, [#("msg", json.string("Could not decode json"))])
    Ok(ok) -> on_ok(ok)
  }
}

pub fn require_player(
  req: Request,
  players_actor: process.Subject(players.Message),
  next: fn(String) -> Response,
) -> Response {
  let authenticated = {
    use header <- result.try(request.get_header(req, "authorization"))
    case string.split_once(header, " ") {
      Ok(#("Bearer", jwt)) -> players.authenticate(players_actor, jwt)
      _ -> Error(Nil)
    }
  }
  case authenticated {
    Ok(username) -> next(username)
    Error(_) ->
      json_response(401, [#("msg", json.string("Please log in again"))])
  }
}

pub fn allow_cors(
  req: Request,
  handle_request: fn(Request) -> Response,
) -> Response {
  let origin = request.get_header(req, "origin") |> result.unwrap("*")

  let response = case req.method {
    Options -> wisp.response(200)
    _ -> handle_request(req)
  }

  response
  |> wisp.set_header("access-control-allow-origin", origin)
  |> wisp.set_header("access-control-allow-methods", "GET, POST, OPTIONS")
  |> wisp.set_header(
    "access-control-allow-headers",
    "content-type, authorization",
  )
  |> wisp.set_header("vary", "origin")
}
