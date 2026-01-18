import gleam/json.{type Json}
import wisp.{type Response}

pub type JsonData =
  List(#(String, Json))

pub fn json_response(response_code: Int, data: JsonData) -> Response {
  json.object(data)
  |> json.to_string()
  |> wisp.json_response(response_code)
}
