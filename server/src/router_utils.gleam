import gleam/http.{Options}
import gleam/http/request
import gleam/json.{type Json}
import gleam/result
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
  |> wisp.set_header("access-control-allow-headers", "content-type")
  |> wisp.set_header("vary", "origin")
}
