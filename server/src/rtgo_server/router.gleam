import gleam/dict
import gleam/erlang/process
import gleam/http.{Get, Post}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import gleam/time/timestamp
import rtgo_server/game
import rtgo_server/katago
import rtgo_server/lobby
import rtgo_server/players
import rtgo_server/recorder
import rtgo_server/router_utils.{allow_cors, json_response, json_response_obj}
import rtgo_shared/auth
import rtgo_shared/auth_api
import rtgo_shared/game as shared_game
import rtgo_shared/go
import rtgo_shared/lobby_api
import rtgo_shared/play_api
import rtgo_shared/sgf
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
        colors: dict.map_values(players, fn(_, p) { p.color }),
      )
    }
    lobby.Running(host:, subject:, settings:) -> {
      let game.Snapshot(players:, cooldowns:, phase:, ..) =
        game.get_game(subject)
      let names = list.sort(dict.keys(players), string.compare)
      lobby_api.GameDetails(
        id: id,
        phase: phase,
        host: host,
        players: names,
        player_count: dict.size(players),
        settings: settings,
        cooldowns: cooldowns,
        colors: dict.map_values(players, fn(_, p) { p.color }),
      )
    }
  }
}

fn play_response(
  subject: process.Subject(game.Message),
  outcome: Result(Nil, game.Error),
) -> Response {
  case outcome {
    Ok(Nil) ->
      json_response_obj(
        200,
        play_api.state_to_json(game.get_game(subject).live),
      )
    Error(game.UnknownPlayer) ->
      json_response(403, [
        #("msg", json.string("Only players in this game can move or pass")),
      ])
    Error(game.CoolingDown) ->
      json_response(409, [
        #("msg", json.string("Your next action is still cooling down")),
      ])
    Error(game.GameFinished) ->
      json_response(409, [#("msg", json.string("The game has finished"))])
    Error(game.InvalidMove(error)) -> {
      let message = case error {
        go.OutOfBounds -> "That point is outside the board"
        go.Occupied -> "That point is occupied"
        go.Suicide -> "That move has no liberties"
        go.Ko -> "That move repeats a previous board (superko)"
      }
      json_response(409, [#("msg", json.string(message))])
    }
  }
}

/// Preserve chronological ordering when the client groups games by phase.
fn newest_first(
  a: #(String, lobby.Metadata),
  b: #(String, lobby.Metadata),
) -> order.Order {
  let by_date = case { a.1 }.started_at, { b.1 }.started_at {
    Some(a), Some(b) -> timestamp.compare(b, a)
    Some(_), None -> order.Lt
    None, Some(_) -> order.Gt
    None, None -> order.Eq
  }
  case by_date {
    order.Eq -> string.compare(a.0, b.0)
    _ -> by_date
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
        case
          players.try_register_with_color(
            players_actor,
            rr.username,
            rr.preferred_color,
          )
        {
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

    Get, ["profile", "color"] -> {
      use username <- router_utils.require_player(req, players_actor)
      json_response_obj(
        200,
        auth_api.preferred_color_to_json(players.preferred_color(
          players_actor,
          username,
        )),
      )
    }
    Post, ["profile", "color"] -> {
      use username <- router_utils.require_player(req, players_actor)
      use color <- router_utils.on_json(req, auth_api.preferred_color_decoder)
      players.set_preferred_color(players_actor, username, color)
      json_response_obj(200, auth_api.preferred_color_to_json(color))
    }

    Get, _ if path_segments == games_segments -> {
      let games =
        lobby.list_games(lobby_actor)
        |> dict.to_list()
        |> list.sort(newest_first)
        |> list.map(fn(entry) {
          let #(id, lobby.Metadata(phase:, player_count:, settings:, ..)) =
            entry
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
      case
        lobby.create_game_with_preference(
          lobby_actor,
          username,
          settings,
          players.preferred_color(players_actor, username),
        )
      {
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

    Get, ["games", id, "sgf"] -> {
      let recorded = case lobby.get_game(lobby_actor, id) {
        Ok(lobby.Running(subject:, ..)) -> {
          let #(started_at, record) = game.get_recording(subject)
          Ok(#(recorder.filename(id, started_at), sgf.encode(record)))
        }
        _ -> recorder.read_named(id)
      }
      case recorded {
        Ok(#(filename, text)) ->
          wisp.response(200)
          |> wisp.set_header(
            "content-type",
            "application/x-go-sgf; charset=utf-8",
          )
          |> wisp.set_header(
            "content-disposition",
            "attachment; filename=\"" <> filename <> "\"",
          )
          |> wisp.set_header("cache-control", "no-store")
          |> wisp.string_body(text)
        Error(_) ->
          json_response(404, [#("msg", json.string("Recording not found"))])
      }
    }

    Get, ["games", id, "board"] -> {
      use subject <- running_game(lobby_actor, id)
      json_response_obj(
        200,
        play_api.state_to_json(game.get_game(subject).live),
      )
    }

    Post, ["games", id, "moves"] -> {
      use username <- router_utils.require_player(req, players_actor)
      use subject <- running_game(lobby_actor, id)
      use point <- router_utils.on_json(req, play_api.move_decoder)
      play_response(subject, game.play(subject, username, point))
    }

    Post, ["games", id, "pass"] -> {
      use username <- router_utils.require_player(req, players_actor)
      use subject <- running_game(lobby_actor, id)
      play_response(subject, game.pass(subject, username))
    }

    Post, ["games", id, "join"] -> {
      use username <- router_utils.require_player(req, players_actor)
      case
        lobby.join_game_with_preference(
          lobby_actor,
          id,
          username,
          players.preferred_color(players_actor, username),
        )
      {
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

    Post, ["games", id, "bots"] -> {
      use username <- router_utils.require_player(req, players_actor)
      case katago.available() {
        True -> change_response(lobby.add_bot(lobby_actor, id, username))
        False ->
          json_response(503, [
            #("msg", json.string("KataGo is not installed on this server")),
          ])
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

    Post, ["games", id, "color"] -> {
      use username <- router_utils.require_player(req, players_actor)
      use color <- router_utils.on_json(req, lobby_api.choose_color_decoder)
      change_response(lobby.choose_color(lobby_actor, id, username, color))
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

fn running_game(
  lobby_actor: process.Subject(lobby.Message),
  id: String,
  next: fn(process.Subject(game.Message)) -> Response,
) -> Response {
  case lobby.get_game(lobby_actor, id) {
    Ok(lobby.Running(subject:, ..)) -> next(subject)
    Ok(_) ->
      json_response(409, [#("msg", json.string("The game has not started"))])
    Error(_) -> json_response(404, [#("msg", json.string("Game not found"))])
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
    Error(lobby.ColorTaken) ->
      json_response(409, [
        #("msg", json.string("That color is already taken. Choose another.")),
      ])
    Error(lobby.InvalidColor) ->
      json_response(400, [
        #("msg", json.string("That color is not available for this game type")),
      ])
    Error(lobby.RoomFull) ->
      json_response(409, [#("msg", json.string("This room is full"))])
    Error(lobby.Kicked) ->
      json_response(403, [
        #("msg", json.string("You were kicked from this room by the host")),
      ])
  }
}
// TODO handle 5xx with json too
