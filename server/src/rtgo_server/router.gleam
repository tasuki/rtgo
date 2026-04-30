import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/json
import rtgo_server/players
import rtgo_server/router_utils.{allow_cors, json_response, json_response_obj}
import rtgo_shared/auth
import rtgo_shared/auth_api
import wisp.{type Request, type Response}

pub fn handle(
  players_actor: process.Subject(players.Message),
  req: Request,
) -> Response {
  use req <- allow_cors(req)

  let path_segments = wisp.path_segments(req)
  let register_segments = auth_api.path_segments(auth_api.register_path)
  let log_in_segments = auth_api.path_segments(auth_api.log_in_path)

  case req.method, path_segments {
    Get, [] -> json_response(200, [])
    Get, ["ping"] -> json_response(200, [])

    Post, _ if path_segments == register_segments -> {
      router_utils.on_json(req, auth.registration_request_decoder, fn(rr) {
        case players.try_register(players_actor, rr.username) {
          Ok(lir) -> json_response_obj(200, auth.log_in_response_to_json(lir))
          Error(err) ->
            json_response_obj(
              409,
              auth.registration_failed_response_to_json(err),
            )
        }
      })
    }

    Post, _ if path_segments == log_in_segments -> {
      router_utils.on_json(req, auth.log_in_request_decoder, fn(lir) {
        case players.try_login(players_actor, lir.jwt) {
          Ok(lir) -> json_response_obj(200, auth.log_in_response_to_json(lir))
          Error(err) ->
            json_response_obj(400, auth.log_in_failed_response_to_json(err))
        }
      })
    }

    _, _ ->
      json_response(404, [
        #("msg", json.string("404: Not Found")),
      ])
  }
}
// TODO handle 5xx with json too
