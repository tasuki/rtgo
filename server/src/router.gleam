import gleam/json
import router_utils.{allow_cors, json_response}
import wisp.{type Request, type Response}

pub fn handle(req: Request) -> Response {
  use req <- allow_cors(req)

  case wisp.path_segments(req) {
    [] -> json_response(200, [])
    ["ping"] -> json_response(200, [])
    _ ->
      json_response(404, [
        #("msg", json.string("not found")),
      ])
  }
}
// TODO handle 5xx with json too
