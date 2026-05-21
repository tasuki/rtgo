import gleam/dict
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/json
import gleam/list
import gleam/result
import rtgo_server/game
import rtgo_server/lobby
import rtgo_server/players
import rtgo_server/router_utils.{allow_cors, json_response, json_response_obj}
import rtgo_shared/auth
import rtgo_shared/auth_api
import rtgo_shared/game as shared_game
import rtgo_shared/lobby_api
import wisp.{type Request, type Response}

fn game_details(id: String, entry: lobby.Entry) -> lobby_api.GameDetails {
  case entry {
    lobby.Open(lobby.Lobby(host:, players: players)) ->
      lobby_api.GameDetails(
        id: id,
        phase: shared_game.Negotiating,
        host: host,
        players: dict.keys(players),
        player_count: dict.size(players),
      )
    lobby.Running(subject) -> {
      let game.Snapshot(players:, ..) = game.get_game(subject)
      let names = dict.keys(players)
      let host = names |> list.first |> result.unwrap("")
      lobby_api.GameDetails(
        id: id,
        phase: shared_game.Started,
        host: host,
        players: names,
        player_count: dict.size(players),
      )
    }
  }
}

pub fn handle(
  players_actor: process.Subject(players.Message),
  lobby_actor: process.Subject(lobby.Message),
  req: Request,
) -> Response {
  use req <- allow_cors(req)

  let path_segments = wisp.path_segments(req)
  let register_segments = auth_api.path_segments(auth_api.register_path)
  let log_in_segments = auth_api.path_segments(auth_api.log_in_path)
  let games_segments = auth_api.path_segments(lobby_api.games_path)

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

    Get, _ if path_segments == games_segments -> {
      let games =
        lobby.list_games(lobby_actor)
        |> dict.to_list()
        |> list.map(fn(entry) {
          let #(id, lobby.Metadata(phase, player_count)) = entry
          lobby_api.GameMetadata(id, phase, player_count)
        })
      json_response_obj(
        200,
        lobby_api.list_games_response_to_json(lobby_api.ListGamesResponse(games)),
      )
    }

    Post, _ if path_segments == games_segments -> {
      router_utils.on_json(req, lobby_api.create_game_request_decoder, fn(body) {
        let id = lobby.create_game(lobby_actor, body.username)
        json_response_obj(
          200,
          lobby_api.create_game_response_to_json(lobby_api.CreateGameResponse(
            id,
          )),
        )
      })
    }

    Get, ["games", id] -> {
      case lobby.get_game(lobby_actor, id) {
        Ok(entry) ->
          json_response_obj(
            200,
            lobby_api.get_game_response_to_json(
              lobby_api.GetGameResponse(game_details(id, entry)),
            ),
          )
        Error(_) ->
          json_response(404, [#("msg", json.string("404: Not Found"))])
      }
    }

    Post, ["games", id, "join"] -> {
      router_utils.on_json(req, lobby_api.join_game_request_decoder, fn(body) {
        case lobby.join_game(lobby_actor, id, body.username) {
          Ok(joined) ->
            json_response_obj(
              200,
              lobby_api.join_game_response_to_json(lobby_api.JoinGameResponse(
                joined,
              )),
            )
          Error(_) ->
            json_response(404, [#("msg", json.string("404: Not Found"))])
        }
      })
    }

    Post, ["games", id, "start"] -> {
      router_utils.on_json(req, lobby_api.start_game_request_decoder, fn(body) {
        case lobby.start_game(lobby_actor, id, body.username) {
          Ok(started) ->
            json_response_obj(
              200,
              lobby_api.start_game_response_to_json(lobby_api.StartGameResponse(
                started,
              )),
            )
          Error(lobby.NotHost) ->
            json_response(403, [#("msg", json.string("403: Not Host"))])
          Error(_) ->
            json_response(404, [#("msg", json.string("404: Not Found"))])
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
