import gleam/dict
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/json
import gleam/list
import gleam/string
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
    lobby.Open(room) -> {
      let lobby.Lobby(host:, players:, settings:, ..) = room
      lobby_api.GameDetails(
        id: id,
        phase: shared_game.Negotiating,
        host: host,
        players: list.sort(dict.keys(players), string.compare),
        player_count: dict.size(players),
        settings: settings,
        cooldowns: lobby.player_cooldowns(room),
      )
    }
    lobby.Running(host:, subject:, settings:) -> {
      let game.Snapshot(players:, cooldowns:, ..) = game.get_game(subject)
      let names = list.sort(dict.keys(players), string.compare)
      lobby_api.GameDetails(
        id: id,
        phase: shared_game.Started,
        host: host,
        players: names,
        player_count: dict.size(players),
        settings: settings,
        cooldowns: cooldowns,
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
          let #(id, lobby.Metadata(phase, player_count, settings)) = entry
          lobby_api.GameMetadata(id, phase, player_count, settings)
        })
      json_response_obj(
        200,
        lobby_api.list_games_response_to_json(lobby_api.ListGamesResponse(games)),
      )
    }

    Post, _ if path_segments == games_segments -> {
      use username <- router_utils.require_player(req, players_actor)
      use settings <- router_utils.on_json(req, shared_game.settings_decoder)
      case lobby.create_game(lobby_actor, username, settings) {
        Ok(id) ->
          json_response_obj(
            200,
            lobby_api.create_game_response_to_json(lobby_api.CreateGameResponse(
              id,
            )),
          )
        Error(_) ->
          json_response(400, [#("msg", json.string("Invalid game settings"))])
      }
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
      use username <- router_utils.require_player(req, players_actor)
      case lobby.join_game(lobby_actor, id, username) {
        Ok(joined) ->
          json_response_obj(
            200,
            lobby_api.join_game_response_to_json(lobby_api.JoinGameResponse(
              joined,
            )),
          )
        Error(lobby.Kicked) ->
          json_response(403, [
            #("msg", json.string("You were kicked from this room by the host")),
          ])
        Error(_) ->
          json_response(404, [#("msg", json.string("404: Not Found"))])
      }
    }

    Post, ["games", id, "start"] -> {
      use username <- router_utils.require_player(req, players_actor)
      case lobby.start_game(lobby_actor, id, username) {
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
    }

    Post, ["games", id, "leave"] -> {
      use username <- router_utils.require_player(req, players_actor)
      change_response(lobby.leave_game(lobby_actor, id, username))
    }

    Post, ["games", id, "cancel"] -> {
      use username <- router_utils.require_player(req, players_actor)
      change_response(lobby.cancel_game(lobby_actor, id, username))
    }

    Post, ["games", id, "kick"] -> {
      use username <- router_utils.require_player(req, players_actor)
      use target <- router_utils.on_json(
        req,
        lobby_api.kick_player_request_decoder,
      )
      change_response(lobby.kick_player(lobby_actor, id, username, target))
    }

    Post, ["games", id, "cooldown"] -> {
      use username <- router_utils.require_player(req, players_actor)
      use change <- router_utils.on_json(
        req,
        lobby_api.player_cooldown_request_decoder,
      )
      let #(target, seconds) = change
      change_response(lobby.set_player_cooldown(
        lobby_actor,
        id,
        username,
        target,
        seconds,
      ))
    }

    _, _ ->
      json_response(404, [
        #("msg", json.string("404: Not Found")),
      ])
  }
}

fn change_response(result: Result(Nil, lobby.Error)) -> Response {
  case result {
    Ok(Nil) -> wisp.response(204)
    Error(lobby.GameNotFound) ->
      json_response(404, [#("msg", json.string("Game not found"))])
    Error(lobby.NotHost) ->
      json_response(403, [
        #("msg", json.string("Only the host can perform this action")),
      ])
    Error(lobby.HostMustCancel) ->
      json_response(409, [
        #("msg", json.string("The host must cancel instead of leaving")),
      ])
    Error(lobby.AlreadyStarted) ->
      json_response(409, [#("msg", json.string("The game has already started"))])
    Error(lobby.InvalidSettings) ->
      json_response(400, [#("msg", json.string("Invalid game settings"))])
    Error(lobby.PlayerNotFound) ->
      json_response(404, [
        #("msg", json.string("Player is no longer in this room")),
      ])
    Error(lobby.CannotKickHost) ->
      json_response(409, [
        #(
          "msg",
          json.string("The host cannot be kicked; cancel the room instead"),
        ),
      ])
    Error(lobby.InvalidPlayerCooldown) ->
      json_response(400, [
        #(
          "msg",
          json.string(
            "Player cooldown must be at least the game's base cooldown and at most 3600 seconds",
          ),
        ),
      ])
    Error(lobby.Kicked) ->
      json_response(403, [
        #("msg", json.string("You were kicked from this room by the host")),
      ])
  }
}
// TODO handle 5xx with json too
