import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/json
import player
import players
import router_utils.{allow_cors, json_response, json_response_obj}
import wisp.{type Request, type Response}

pub fn handle(
  players_actor: process.Subject(players.Message),
  req: Request,
) -> Response {
  use req <- allow_cors(req)

  case req.method, wisp.path_segments(req) {
    Get, [] -> json_response(200, [])
    Get, ["ping"] -> json_response(200, [])
    Post, ["log_in"] -> {
      use req_json <- wisp.require_json(req)
      let decoder = player.log_in_request_decoder()

      case decode.run(req_json, decoder) {
        Error(_) ->
          json_response(400, [#("msg", json.string("Could not decode json"))])
        Ok(lir) -> {
          case players.try_login(players_actor, lir.name) {
            Ok(lir) ->
              json_response_obj(200, player.log_in_response_to_json(lir))
            Error(err) ->
              json_response_obj(409, player.log_in_failed_response_to_json(err))
          }
        }
      }
    }
    _, _ ->
      json_response(404, [
        #("msg", json.string("404: Not Found")),
      ])
  }
}
// TODO handle 5xx with json too
