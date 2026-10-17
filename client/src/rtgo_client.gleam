import config
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/javascript/promise
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import gleam/uri.{type Uri}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import modem
import rsvp
import rtgo_client/board
import rtgo_client/player_info
import rtgo_shared/auth
import rtgo_shared/game as shared_game
import rtgo_shared/go
import rtgo_shared/lobby_api
import rtgo_shared/play_api
import rtgo_shared/player as shared_player

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "body", Nil)
  Nil
}

pub type Route {
  PlayerInfo
  CreateJoinGame
  Play(game_id: String)
}

pub type Model {
  Model(
    route: Route,
    player: player_info.PlayerStatus,
    ping: Option(Duration),
    server_url: String,
    game: go.Game,
    lobby_games: List(lobby_api.GameMetadata),
    loading_lobby: Bool,
    lobby_loaded: Bool,
    current_game: Option(lobby_api.GameDetails),
    loading_game: Bool,
    // Each visit gets its own generation, including revisits to the same room.
    page_version: Int,
    pending_action: Bool,
    saving_cooldown: Bool,
    after_save: Option(Msg),
    load_error: Option(String),
    action_error: Option(String),
    create_board_size: Int,
    create_game_type: shared_game.GameType,
    create_cooldown: String,
    cooldown_drafts: Dict(String, String),
    live: Option(play_api.State),
    loading_board: Bool,
    hovered: Option(go.Point),
    premove: Option(go.Point),
    expanded_menu: Option(String),
  )
}

pub fn initial_model(
  route: Route,
  player: player_info.PlayerStatus,
  server_url: String,
) -> Model {
  let shared_game.Cooldown(default_cooldown) =
    shared_game.default_settings.time_settings
  Model(
    route: route,
    player: player,
    ping: None,
    server_url: server_url,
    game: go.new_game(19),
    lobby_games: [],
    loading_lobby: False,
    lobby_loaded: False,
    current_game: None,
    loading_game: False,
    page_version: 0,
    pending_action: False,
    saving_cooldown: False,
    after_save: None,
    load_error: None,
    action_error: None,
    create_board_size: shared_game.default_settings.board_size,
    create_game_type: shared_game.default_settings.game_type,
    create_cooldown: int.to_string(default_cooldown),
    cooldown_drafts: dict.new(),
    live: None,
    loading_board: False,
    hovered: None,
    premove: None,
    expanded_menu: None,
  )
}

pub fn creation_settings(model: Model) -> Result(shared_game.Settings, Nil) {
  use seconds <- result.try(int.parse(model.create_cooldown))
  let settings =
    shared_game.Settings(
      model.create_board_size,
      model.create_game_type,
      shared_game.Cooldown(seconds),
    )
  case shared_game.valid_settings(settings) {
    True -> Ok(settings)
    False -> Error(Nil)
  }
}

fn route_from_uri(uri: Uri) -> Route {
  case uri.path_segments(uri.path) {
    [] -> PlayerInfo
    ["create"] -> CreateJoinGame
    ["play", game_id] -> Play(game_id)
    _ -> PlayerInfo
  }
}

fn route_to_str(route: Route) -> String {
  case route {
    PlayerInfo -> "/"
    CreateJoinGame -> "/create"
    Play(game_id) -> "/play/" <> game_id
  }
}

fn on_url_change(uri: Uri) -> Msg {
  RouteChanged(route_from_uri(uri))
}

fn init(_) {
  let route =
    modem.initial_uri()
    |> result.map(route_from_uri)
    |> result.unwrap(PlayerInfo)
  let assert Ok(server_url) = config.server_urls |> list.first
  let #(player, login) = player_info.default_login(server_url, LoggedInResponse)
  let #(model, load) =
    initial_model(route, player, server_url)
    |> update(RouteChanged(route))
  #(
    model,
    effect.batch([
      login,
      load,
      ping_server(server_url),
      modem.init(on_url_change),
    ]),
  )
}

fn ping_decoder(start: Timestamp) {
  decode.success(Nil)
  |> decode.map(fn(_) { timestamp.difference(start, timestamp.system_time()) })
}

fn ping_server(server_url: String) -> Effect(Msg) {
  let start = timestamp.system_time()
  let handler = rsvp.expect_json(ping_decoder(start), PingResponded)
  rsvp.get(server_url <> "/ping", handler)
}

fn load_lobby_games(model: Model) -> Effect(Msg) {
  rsvp.send(
    lobby_api.games_request(model.server_url),
    rsvp.expect_json(lobby_api.list_games_response_decoder(), fn(result) {
      GamesLoaded(model.page_version, result)
    }),
  )
}

fn load_game(model: Model, id: String) -> Effect(Msg) {
  rsvp.send(
    lobby_api.game_request(model.server_url, id),
    rsvp.expect_json(lobby_api.get_game_response_decoder(), fn(result) {
      GameLoaded(model.page_version, result)
    }),
  )
}

pub type Msg {
  RouteChanged(Route)
  Refresh(Int)
  PingRequested
  PingResponded(Result(Duration, rsvp.Error))
  Register(String)
  LoggedInResponse(Result(auth.LogInResponse, rsvp.Error))
  GamesLoaded(Int, Result(lobby_api.ListGamesResponse, rsvp.Error))
  GameLoaded(Int, Result(lobby_api.GetGameResponse, rsvp.Error))
  CreateGamePressed
  BoardSizeChanged(String)
  GameTypeChanged(String)
  CooldownChanged(String)
  LeaveGamePressed(String)
  CancelGamePressed(String)
  GameLeft(Int, Result(Nil, rsvp.Error))
  GameCancelled(Int, Result(Nil, rsvp.Error))
  KickPlayerPressed(String, String)
  PlayerKicked(Int, String, Result(Nil, rsvp.Error))
  PlayerCooldownChanged(String, String)
  SetPlayerCooldownPressed(String, String)
  PlayerCooldownSet(Int, String, Int, Result(Nil, rsvp.Error))
  GameCreated(Int, Result(lobby_api.CreateGameResponse, rsvp.Error))
  JoinGamePressed(String)
  GameJoined(Int, String, Result(lobby_api.JoinGameResponse, rsvp.Error))
  StartGamePressed(String)
  GameStarted(Int, String, Result(lobby_api.StartGameResponse, rsvp.Error))
  OpenGame(String)
  BackToLobby
  BoardRefresh(Int)
  BoardLoaded(Int, Result(play_api.State, rsvp.Error))
  PointHovered(Option(go.Point))
  ToggleMenu(String)
  PlayPoint(go.Point)
  CancelPremove
  MoveResponded(Int, Result(play_api.State, rsvp.Error))
}

pub fn wait(milliseconds: Int, msg: msg) -> Effect(msg) {
  effect.from(fn(dispatch) {
    promise.wait(milliseconds)
    |> promise.tap(fn(_) { dispatch(msg) })
    Nil
  })
}

fn refresh_later(model: Model) -> Effect(Msg) {
  // Schedule after completion rather than on a fixed interval: at most one poll
  // is in flight. Old responses and timers are ignored after navigation.
  wait(1000, Refresh(model.page_version))
}

fn credentials(model: Model) -> Result(#(String, String), Nil) {
  case model.player {
    player_info.LoggedIn(name, jwt) -> Ok(#(name, jwt))
    _ -> Error(Nil)
  }
}

fn action_failed(model: Model, message: String) -> #(Model, Effect(Msg)) {
  #(
    Model(
      ..model,
      pending_action: False,
      saving_cooldown: False,
      after_save: None,
      action_error: Some(message),
    ),
    effect.none(),
  )
}

fn action_error(error: rsvp.Error) -> String {
  case error {
    rsvp.HttpError(res) if res.status == 401 ->
      "Your login expired. Reload to log in again."
    rsvp.HttpError(res)
      if res.status == 400
      || res.status == 403
      || res.status == 404
      || res.status == 409
    -> {
      let decoder = {
        use message <- decode.field("msg", decode.string)
        decode.success(message)
      }
      json.parse(res.body, decoder)
      |> result.unwrap("This action is no longer available.")
    }
    _ -> "Could not reach the server. Please try again."
  }
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  let stale = case msg {
    Refresh(version)
    | GamesLoaded(version, _)
    | GameLoaded(version, _)
    | GameCreated(version, _)
    | GameJoined(version, _, _)
    | GameStarted(version, _, _)
    | GameLeft(version, _)
    | GameCancelled(version, _)
    | PlayerKicked(version, _, _)
    | PlayerCooldownSet(version, _, _, _)
    | BoardRefresh(version)
    | BoardLoaded(version, _)
    | MoveResponded(version, _) -> version != model.page_version
    _ -> False
  }
  let follows_save = case msg {
    StartGamePressed(_) | KickPlayerPressed(_, _) | CancelGamePressed(_) ->
      model.saving_cooldown
    _ -> False
  }
  case stale, follows_save {
    True, _ -> #(model, effect.none())
    False, True ->
      case model.after_save {
        None -> #(Model(..model, after_save: Some(msg)), effect.none())
        Some(_) -> #(model, effect.none())
      }
    False, False -> update_current(model, msg)
  }
}

fn update_current(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    RouteChanged(route) -> {
      let model =
        Model(
          ..model,
          route: route,
          page_version: model.page_version + 1,
          current_game: None,
          live: None,
          loading_board: False,
          hovered: None,
          premove: None,
          expanded_menu: None,
          cooldown_drafts: dict.new(),
          loading_game: False,
          loading_lobby: False,
          pending_action: False,
          saving_cooldown: False,
          after_save: None,
          load_error: None,
          action_error: None,
        )
      update(model, Refresh(model.page_version))
    }
    Refresh(_) if model.loading_lobby || model.loading_game -> #(
      model,
      effect.none(),
    )
    Refresh(_) ->
      case model.route {
        CreateJoinGame -> #(
          Model(..model, loading_lobby: True),
          load_lobby_games(model),
        )
        Play(id) -> #(Model(..model, loading_game: True), load_game(model, id))
        PlayerInfo -> #(model, effect.none())
      }
    PingRequested -> #(model, ping_server(model.server_url))
    PingResponded(duration_res) -> #(
      Model(..model, ping: option.from_result(duration_res)),
      wait(1000, PingRequested),
    )
    Register(name) -> #(
      Model(..model, player: player_info.VerifyingName(name)),
      player_info.register(model.server_url, name, LoggedInResponse),
    )
    LoggedInResponse(Ok(lir)) -> {
      case player_info.decode_login_jwt(lir.jwt) {
        Ok(#(name, _exp)) -> #(
          Model(..model, player: player_info.LoggedIn(name, lir.jwt)),
          effect.batch([
            player_info.save_login(lir.jwt),
            // Preserve a shared room link across login/registration.
            case model.route {
              PlayerInfo ->
                modem.replace(route_to_str(CreateJoinGame), None, None)
              _ -> effect.none()
            },
          ]),
        )
        Error(e) -> #(
          Model(
            ..model,
            player: player_info.OtherError("Error: " <> string.inspect(e)),
          ),
          effect.none(),
        )
      }
    }
    LoggedInResponse(Error(e)) -> {
      let #(player, eff) = case e {
        rsvp.NetworkError -> #(
          player_info.OtherError(
            "Could not reach the server. Please try again.",
          ),
          effect.none(),
        )
        rsvp.HttpError(res) if res.status == 400 -> {
          case player_info.desired_name(model.player) {
            Ok(name) -> #(
              player_info.VerifyingName(name),
              player_info.register(model.server_url, name, LoggedInResponse),
            )
            Error(_) -> #(
              player_info.OtherError("Login failed."),
              effect.none(),
            )
          }
        }
        rsvp.HttpError(res) if res.status == 409 -> #(
          case
            json.parse(res.body, auth.registration_failed_response_decoder())
          {
            Ok(rf) -> player_info.NameAlreadyTaken(rf.already_taken)
            Error(e) -> player_info.OtherError("Error: " <> string.inspect(e))
          },
          effect.none(),
        )
        _ -> #(
          player_info.OtherError("Login failed. Please try again."),
          effect.none(),
        )
      }
      #(Model(..model, player: player), eff)
    }
    GamesLoaded(_, result) -> {
      let model = case result {
        Ok(lobby_api.ListGamesResponse(games)) ->
          Model(
            ..model,
            lobby_games: games,
            loading_lobby: False,
            lobby_loaded: True,
            load_error: None,
          )
        Error(_) ->
          Model(
            ..model,
            loading_lobby: False,
            load_error: Some("Could not refresh the lobby. Retrying..."),
          )
      }
      #(model, refresh_later(model))
    }
    GameLoaded(_, result) -> {
      let model = case result {
        Ok(lobby_api.GetGameResponse(game)) ->
          Model(
            ..model,
            current_game: Some(game),
            cooldown_drafts: dict.filter(model.cooldown_drafts, fn(name, _) {
              list.contains(game.players, name)
            }),
            game: go.new_game(game.settings.board_size),
            loading_game: False,
            load_error: None,
          )
        Error(rsvp.HttpError(res)) if res.status == 404 ->
          Model(
            ..model,
            current_game: None,
            loading_game: False,
            load_error: Some("Game not found. It may have been cancelled."),
          )
        Error(_) ->
          Model(
            ..model,
            loading_game: False,
            load_error: Some("Could not refresh the room. Retrying..."),
          )
      }
      let poll = case result {
        Ok(lobby_api.GetGameResponse(lobby_api.GameDetails(
          phase: shared_game.Negotiating,
          ..,
        ))) -> refresh_later(model)
        Ok(_) -> effect.none()
        Error(rsvp.HttpError(res)) if res.status == 404 -> effect.none()
        Error(_) -> refresh_later(model)
      }
      case result {
        Ok(lobby_api.GetGameResponse(details))
          if details.phase != shared_game.Negotiating
        -> update(model, BoardRefresh(model.page_version))
        _ -> #(model, poll)
      }
    }
    BoardRefresh(_) ->
      case model.route, model.loading_board {
        Play(id), False -> #(
          Model(..model, loading_board: True),
          rsvp.send(
            play_api.state_request(model.server_url, id),
            rsvp.expect_json(play_api.state_decoder(), fn(res) {
              BoardLoaded(model.page_version, res)
            }),
          ),
        )
        _, _ -> #(model, effect.none())
      }
    BoardLoaded(_, response) -> {
      let model = Model(..model, loading_board: False)
      let #(model, premove_effect) = case response {
        Ok(state) -> accept_board(model, state) |> send_premove_if_ready
        Error(_) -> #(
          Model(
            ..model,
            load_error: Some("Live updates disconnected. Retrying..."),
          ),
          effect.none(),
        )
      }
      let poll = case model.live {
        Some(state) if state.finished -> effect.none()
        _ -> wait(250, BoardRefresh(model.page_version))
      }
      #(model, effect.batch([poll, premove_effect]))
    }
    PointHovered(point) -> #(Model(..model, hovered: point), effect.none())
    ToggleMenu(key) -> #(
      Model(..model, expanded_menu: case model.expanded_menu == Some(key) {
        True -> None
        False -> Some(key)
      }),
      effect.none(),
    )
    PlayPoint(point) ->
      case
        local_status(model),
        model.pending_action,
        empty_point(model.game, point)
      {
        Some(status), False, True if status.cooldown_ms > 0 -> #(
          Model(
            ..model,
            premove: case model.premove == Some(point) {
              True -> None
              False -> Some(point)
            },
            hovered: None,
            expanded_menu: None,
            action_error: None,
          ),
          effect.none(),
        )
        Some(_), False, True -> send_move(model, point)
        _, _, _ -> #(model, effect.none())
      }
    CancelPremove -> #(Model(..model, premove: None), effect.none())
    MoveResponded(_, response) ->
      case response {
        Ok(state) -> #(
          accept_board(Model(..model, pending_action: False), state),
          effect.none(),
        )
        Error(error) -> action_failed(model, action_error(error))
      }
    BoardSizeChanged(value) -> {
      let size = int.parse(value) |> result.unwrap(model.create_board_size)
      #(Model(..model, create_board_size: size), effect.none())
    }
    GameTypeChanged(value) -> {
      let game_type = case value {
        "two_player" -> shared_game.TwoPlayerGame
        "multiplayer" -> shared_game.MultiplayerGame
        _ -> model.create_game_type
      }
      #(Model(..model, create_game_type: game_type), effect.none())
    }
    CooldownChanged(value) -> #(
      Model(..model, create_cooldown: value),
      effect.none(),
    )
    CreateGamePressed ->
      case credentials(model), model.pending_action, creation_settings(model) {
        Ok(#(_, jwt)), False, Ok(settings) -> #(
          Model(..model, pending_action: True, action_error: None),
          rsvp.send(
            lobby_api.create_game_request(model.server_url, jwt, settings),
            rsvp.expect_json(
              lobby_api.create_game_response_decoder(),
              fn(result) { GameCreated(model.page_version, result) },
            ),
          ),
        )
        Ok(_), False, Error(_) ->
          action_failed(
            model,
            "Choose a board size of 9, 13 or 19 and a cooldown of 1–60 seconds.",
          )
        _, _, _ -> #(model, effect.none())
      }
    GameCreated(_, Ok(lobby_api.CreateGameResponse(id))) -> #(
      Model(..model, pending_action: False),
      modem.push(route_to_str(Play(id)), None, None),
    )
    GameCreated(_, Error(error)) -> action_failed(model, action_error(error))
    JoinGamePressed(id) ->
      case credentials(model), model.pending_action {
        Ok(#(_, jwt)), False -> #(
          Model(..model, pending_action: True, action_error: None),
          rsvp.send(
            lobby_api.join_game_request(model.server_url, id, jwt),
            rsvp.expect_json(lobby_api.join_game_response_decoder(), fn(result) {
              GameJoined(model.page_version, id, result)
            }),
          ),
        )
        _, _ -> #(model, effect.none())
      }
    GameJoined(_, id, Ok(lobby_api.JoinGameResponse(True))) -> #(
      Model(..model, pending_action: False),
      modem.push(route_to_str(Play(id)), None, None),
    )
    GameJoined(_, _, Ok(lobby_api.JoinGameResponse(False))) ->
      action_failed(model, "This game is full or has already started.")
    GameJoined(_, _, Error(error)) -> action_failed(model, action_error(error))
    StartGamePressed(id) ->
      case
        credentials(model),
        model.pending_action,
        dict.size(model.cooldown_drafts) > 0
      {
        Ok(_), False, True ->
          action_failed(
            model,
            "Enter valid cooldowns before starting the game.",
          )
        Ok(#(_, jwt)), False, False -> #(
          Model(..model, pending_action: True, action_error: None),
          rsvp.send(
            lobby_api.start_game_request(model.server_url, id, jwt),
            rsvp.expect_json(
              lobby_api.start_game_response_decoder(),
              fn(result) { GameStarted(model.page_version, id, result) },
            ),
          ),
        )
        _, _, _ -> #(model, effect.none())
      }
    GameStarted(_, id, Ok(lobby_api.StartGameResponse(True))) ->
      update(model, RouteChanged(Play(id)))
    GameStarted(_, _, Ok(lobby_api.StartGameResponse(False))) ->
      action_failed(
        model,
        "The game needs two players, or has already started.",
      )
    GameStarted(_, _, Error(error)) -> action_failed(model, action_error(error))
    LeaveGamePressed(id) ->
      case credentials(model), model.pending_action {
        Ok(#(_, jwt)), False -> #(
          Model(..model, pending_action: True, action_error: None),
          rsvp.send(
            lobby_api.leave_game_request(model.server_url, id, jwt),
            rsvp.expect_ok_response(fn(result) {
              GameLeft(model.page_version, result |> result.replace(Nil))
            }),
          ),
        )
        _, _ -> #(model, effect.none())
      }
    CancelGamePressed(id) ->
      case credentials(model), model.pending_action {
        Ok(#(_, jwt)), False -> #(
          Model(..model, pending_action: True, action_error: None),
          rsvp.send(
            lobby_api.cancel_game_request(model.server_url, id, jwt),
            rsvp.expect_ok_response(fn(result) {
              GameCancelled(model.page_version, result |> result.replace(Nil))
            }),
          ),
        )
        _, _ -> #(model, effect.none())
      }
    GameLeft(_, Ok(Nil)) | GameCancelled(_, Ok(Nil)) -> #(
      Model(..model, pending_action: False),
      modem.push(route_to_str(CreateJoinGame), None, None),
    )
    GameLeft(_, Error(error)) | GameCancelled(_, Error(error)) ->
      action_failed(model, action_error(error))
    PlayerCooldownChanged(target, value) -> #(
      Model(
        ..model,
        cooldown_drafts: dict.insert(model.cooldown_drafts, target, value),
      ),
      effect.none(),
    )
    KickPlayerPressed(id, target) ->
      case host_room(model, id), model.pending_action {
        Ok(#(jwt, details)), False if target != details.host -> {
          case list.contains(details.players, target) {
            False -> #(model, effect.none())
            True -> #(
              Model(..model, pending_action: True, action_error: None),
              rsvp.send(
                lobby_api.kick_player_request(model.server_url, id, jwt, target),
                rsvp.expect_ok_response(fn(result) {
                  PlayerKicked(
                    model.page_version,
                    target,
                    result |> result.replace(Nil),
                  )
                }),
              ),
            )
          }
        }
        _, _ -> #(model, effect.none())
      }
    PlayerKicked(_, target, Ok(Nil)) ->
      case model.current_game {
        Some(details) -> {
          let players =
            list.filter(details.players, fn(name) { name != target })
          room_changed(
            model,
            lobby_api.GameDetails(
              ..details,
              players: players,
              player_count: list.length(players),
              cooldowns: dict.delete(details.cooldowns, target),
            ),
            target,
          )
        }
        None -> #(model, effect.none())
      }
    PlayerKicked(_, _, Error(error)) ->
      action_failed(model, action_error(error))
    SetPlayerCooldownPressed(id, target) ->
      case host_room(model, id), model.pending_action {
        Ok(#(jwt, details)), False -> {
          let seconds = cooldown_value(model, details, target) |> int.parse
          let unchanged = case seconds {
            Ok(seconds) -> dict.get(details.cooldowns, target) == Ok(seconds)
            Error(_) -> False
          }
          case seconds, unchanged {
            Ok(_), True -> #(
              Model(
                ..model,
                cooldown_drafts: dict.delete(model.cooldown_drafts, target),
                action_error: None,
              ),
              effect.none(),
            )
            Ok(seconds), False ->
              case
                shared_game.valid_player_cooldown(details.settings, seconds)
                && list.contains(details.players, target)
              {
                True -> #(
                  Model(
                    ..model,
                    pending_action: True,
                    saving_cooldown: True,
                    action_error: None,
                  ),
                  rsvp.send(
                    lobby_api.player_cooldown_request(
                      model.server_url,
                      id,
                      jwt,
                      target,
                      seconds,
                    ),
                    rsvp.expect_ok_response(fn(result) {
                      PlayerCooldownSet(
                        model.page_version,
                        target,
                        seconds,
                        result |> result.replace(Nil),
                      )
                    }),
                  ),
                )
                False ->
                  action_failed(
                    model,
                    "Cooldown must be at least the game's base cooldown and at most 3600 seconds.",
                  )
              }
            Error(_), _ ->
              action_failed(
                model,
                "Enter a whole number of seconds for the player's cooldown.",
              )
          }
        }
        _, _ -> #(model, effect.none())
      }
    PlayerCooldownSet(_, target, seconds, Ok(Nil)) ->
      case model.current_game {
        Some(details) -> {
          let queued = model.after_save
          let #(updated, refresh) =
            room_changed(
              model,
              lobby_api.GameDetails(
                ..details,
                cooldowns: dict.insert(details.cooldowns, target, seconds),
              ),
              target,
            )
          case queued {
            None -> #(updated, refresh)
            Some(action) -> {
              let #(updated, follow_up) = update(updated, action)
              #(updated, effect.batch([refresh, follow_up]))
            }
          }
        }
        None -> #(model, effect.none())
      }
    PlayerCooldownSet(_, _, _, Error(error)) ->
      action_failed(model, action_error(error))
    OpenGame(id) -> #(model, modem.push(route_to_str(Play(id)), None, None))
    BackToLobby -> #(
      model,
      modem.push(route_to_str(CreateJoinGame), None, None),
    )
  }
}

fn accept_board(model: Model, state: play_api.State) -> Model {
  case model.live {
    Some(current) if current.revision > state.revision -> model
    _ -> {
      let model =
        Model(..model, live: Some(state), game: state.board, load_error: None)
      case model.premove, local_status(model) {
        Some(_), None -> Model(..model, premove: None)
        Some(point), Some(_) ->
          case empty_point(model.game, point) {
            True -> model
            False ->
              Model(
                ..model,
                premove: None,
                action_error: Some(
                  "Premove cancelled: that point is now occupied.",
                ),
              )
          }
        _, _ -> model
      }
    }
  }
}

fn local_status(model: Model) -> Option(play_api.PlayerStatus) {
  case model.route, credentials(model), model.live {
    Play(_), Ok(#(name, _)), Some(state) if !state.finished -> {
      state.players
      |> list.find(fn(status) { status.player.username == name })
      |> option.from_result
    }
    _, _, _ -> None
  }
}

fn selectable_player(model: Model) -> Option(shared_player.Player) {
  case model.pending_action {
    True -> None
    False -> local_status(model) |> option.map(fn(status) { status.player })
  }
}

fn empty_point(game: go.Game, point: go.Point) -> Bool {
  point.0 >= 0
  && point.0 < game.board_size
  && point.1 >= 0
  && point.1 < game.board_size
  && !dict.has_key(game.stones, point)
}

fn send_move(model: Model, point: go.Point) -> #(Model, Effect(Msg)) {
  case model.route, credentials(model) {
    Play(id), Ok(#(_, jwt)) -> #(
      Model(
        ..model,
        pending_action: True,
        premove: None,
        action_error: None,
        hovered: None,
        expanded_menu: None,
      ),
      rsvp.send(
        play_api.move_request(model.server_url, id, jwt, point),
        rsvp.expect_json(play_api.state_decoder(), fn(res) {
          MoveResponded(model.page_version, res)
        }),
      ),
    )
    _, _ -> #(model, effect.none())
  }
}

fn send_premove_if_ready(model: Model) -> #(Model, Effect(Msg)) {
  case model.premove, local_status(model), model.pending_action {
    Some(point), Some(status), False if status.cooldown_ms == 0 -> {
      // Validate against the latest board. Only the server has complete superko
      // history, so it still has the final say. Never retry a sent premove.
      case go.play(model.game, status.player, point) {
        Ok(_) -> send_move(model, point)
        Error(_) -> #(
          Model(
            ..model,
            premove: None,
            action_error: Some(
              "Premove cancelled: that move is no longer legal.",
            ),
          ),
          effect.none(),
        )
      }
    }
    _, _, _ -> #(model, effect.none())
  }
}

fn host_room(
  model: Model,
  id: String,
) -> Result(#(String, lobby_api.GameDetails), Nil) {
  case credentials(model), model.current_game {
    Ok(#(name, jwt)), Some(details)
      if details.host == name
      && details.id == id
      && details.phase == shared_game.Negotiating
    -> Ok(#(jwt, details))
    _, _ -> Error(Nil)
  }
}

fn cooldown_value(
  model: Model,
  details: lobby_api.GameDetails,
  name: String,
) -> String {
  dict.get(model.cooldown_drafts, name)
  |> result.unwrap({
    dict.get(details.cooldowns, name)
    |> result.unwrap(shared_game.base_cooldown(details.settings))
    |> int.to_string
  })
}

fn room_changed(
  model: Model,
  details: lobby_api.GameDetails,
  target: String,
) -> #(Model, Effect(Msg)) {
  // Retain the visible room, but invalidate any pre-edit polls and timers.
  let model =
    Model(
      ..model,
      current_game: Some(details),
      cooldown_drafts: dict.delete(model.cooldown_drafts, target),
      page_version: model.page_version + 1,
      loading_game: True,
      pending_action: False,
      saving_cooldown: False,
      after_save: None,
      load_error: None,
      action_error: None,
    )
  #(model, load_game(model, details.id))
}

fn duration_in_s(d: Duration) -> #(String, String) {
  let #(seconds, nanoseconds) = duration.to_seconds_and_nanoseconds(d)
  let tenths = { nanoseconds + 50_000_000 } / 100_000_000
  let str = int.to_string(seconds) <> "." <> int.to_string(tenths)
  case seconds, tenths {
    0, t if t <= 1 -> #("green", str)
    0, t if t <= 3 -> #("yellow", str)
    0, _ -> #("orange", str)
    _, _ -> #("red", str)
  }
}

fn view_ping(ping: Option(Duration)) -> #(String, String) {
  case ping {
    Some(ping) -> duration_in_s(ping)
    None -> #("red", "d/c")
  }
}

fn view_menu_item(class: String, text: String, tooltip: String) {
  html.div([attribute.class("item")], [
    html.div([attribute.class("icon"), attribute.class(class)], [
      html.text(text),
      html.span([attribute.class("tooltip")], [html.text(" " <> tooltip)]),
    ]),
  ])
}

fn view_game(model: Model, game: lobby_api.GameMetadata) -> Element(Msg) {
  let lobby_api.GameMetadata(id:, phase:, player_count:, ..) = game
  let #(phase_text, click_msg) = case phase {
    shared_game.Negotiating -> #("open", JoinGamePressed(id))
    shared_game.Started -> #("in progress", OpenGame(id))
    shared_game.Finished -> #("finished", OpenGame(id))
  }
  html.button(
    [
      attribute.class("game-row"),
      attribute.disabled(model.pending_action),
      event.on_click(click_msg),
    ],
    [
      html.span([attribute.class("game-id")], [
        html.text(id),
        html.small([attribute.class("game-settings")], [
          html.text(settings_summary(game.settings)),
        ]),
      ]),
      html.span([attribute.class("game-phase")], [html.text(phase_text)]),
      html.span([attribute.class("game-count")], [
        html.text(int.to_string(player_count) <> " players"),
      ]),
    ],
  )
}

fn view_games(
  model: Model,
  title: String,
  games: List(lobby_api.GameMetadata),
) -> Element(Msg) {
  html.div([attribute.class("lobby-section")], [
    html.h2([], [html.text(title)]),
    case games {
      [] -> html.p([], [html.text("none")])
      _ ->
        html.div(
          [attribute.class("games-list")],
          list.map(games, fn(game) { view_game(model, game) }),
        )
    },
  ])
}

fn view_errors(model: Model) -> Element(Msg) {
  html.div(
    [attribute.attribute("role", "status")],
    [model.load_error, model.action_error]
      |> list.filter_map(option.to_result(_, Nil))
      |> list.map(fn(message) {
        html.p([attribute.class("error")], [html.text(message)])
      }),
  )
}

fn settings_summary(settings: shared_game.Settings) -> String {
  let shared_game.Cooldown(seconds) = settings.time_settings
  let size = int.to_string(settings.board_size)
  shared_game.game_type_label(settings.game_type)
  <> " · "
  <> size
  <> "×"
  <> size
  <> " · "
  <> int.to_string(seconds)
  <> "s cooldown"
}

fn view_create_form(model: Model) -> Element(Msg) {
  html.form(
    [
      attribute.class("create-game"),
      event.on_submit(fn(_) { CreateGamePressed }),
    ],
    [
      html.h2([], [html.text("Create game")]),
      html.label([attribute.for("game-type")], [html.text("Game type")]),
      html.select(
        [
          attribute.id("game-type"),
          attribute.disabled(model.pending_action),
          event.on_change(GameTypeChanged),
        ],
        [
          html.option(
            [
              attribute.value("two_player"),
              attribute.selected(
                model.create_game_type == shared_game.TwoPlayerGame,
              ),
            ],
            "Two-player (black and white)",
          ),
          html.option(
            [
              attribute.value("multiplayer"),
              attribute.selected(
                model.create_game_type == shared_game.MultiplayerGame,
              ),
            ],
            "Multiplayer (up to 8 players)",
          ),
        ],
      ),
      html.label([attribute.for("board-size")], [html.text("Board size")]),
      html.select(
        [
          attribute.id("board-size"),
          attribute.disabled(model.pending_action),
          event.on_change(BoardSizeChanged),
        ],
        list.map([9, 13, 19], fn(size) {
          let text = int.to_string(size)
          html.option(
            [
              attribute.value(text),
              attribute.selected(size == model.create_board_size),
            ],
            text <> "×" <> text,
          )
        }),
      ),
      html.label([attribute.for("cooldown")], [html.text("Cooldown (seconds)")]),
      html.input([
        attribute.id("cooldown"),
        attribute.type_("number"),
        attribute.min("1"),
        attribute.max("60"),
        attribute.required(True),
        attribute.value(model.create_cooldown),
        attribute.disabled(model.pending_action),
        event.on_input(CooldownChanged),
      ]),
      html.button(
        [attribute.type_("submit"), attribute.disabled(model.pending_action)],
        [html.text("Create game")],
      ),
    ],
  )
}

fn view_lobby(model: Model) -> Element(Msg) {
  let open_games =
    list.filter(model.lobby_games, fn(game) {
      game.phase == shared_game.Negotiating
    })
  let running_games =
    list.filter(model.lobby_games, fn(game) {
      game.phase == shared_game.Started
    })
  html.div([attribute.id("page-container"), attribute.class("lobby-page")], [
    html.div([attribute.class("lobby-header")], [
      html.h1([], [html.text("Lobby")]),
    ]),
    case credentials(model) {
      Ok(#(name, _)) -> html.p([], [html.text("Playing as " <> name)])
      Error(_) -> html.text("")
    },
    view_errors(model),
    view_create_form(model),
    case
      model.loading_lobby && !model.lobby_loaded && model.load_error == None
    {
      True -> html.p([], [html.text("Loading...")])
      False ->
        html.div([], [
          view_games(model, "Open for joining", open_games),
          view_games(model, "In progress", running_games),
        ])
    },
  ])
}

fn room_controls_busy(model: Model) -> Bool {
  model.pending_action && !model.saving_cooldown || model.after_save != None
}

fn view_player(
  model: Model,
  details: lobby_api.GameDetails,
  name: String,
  is_host: Bool,
) -> Element(Msg) {
  let seconds =
    dict.get(details.cooldowns, name)
    |> result.unwrap(shared_game.base_cooldown(details.settings))
  html.li(
    [attribute.class("player-row"), attribute.attribute("data-player", name)],
    [
      html.div([], [
        html.span([attribute.class("player-name")], [html.text(name)]),
        html.small([attribute.class("player-cooldown")], [
          html.text(int.to_string(seconds) <> "s between moves"),
        ]),
      ]),
      case is_host {
        False -> html.text("")
        True ->
          html.div([attribute.class("player-controls")], [
            html.input([
              attribute.type_("number"),
              attribute.min(
                int.to_string(shared_game.base_cooldown(details.settings)),
              ),
              attribute.max(int.to_string(shared_game.max_player_cooldown)),
              attribute.required(True),
              attribute.attribute("aria-label", "Cooldown seconds for " <> name),
              attribute.value(cooldown_value(model, details, name)),
              attribute.disabled(model.pending_action),
              event.on_input(fn(value) { PlayerCooldownChanged(name, value) }),
              event.on_blur(SetPlayerCooldownPressed(details.id, name)),
              event.advanced("keydown", {
                use key <- decode.field("key", decode.string)
                let handler =
                  event.handler(
                    SetPlayerCooldownPressed(details.id, name),
                    True,
                    False,
                  )
                case key {
                  "Enter" -> decode.success(handler)
                  _ -> decode.failure(handler, "Enter")
                }
              }),
            ]),
            html.button(
              [
                attribute.class("kick-player"),
                attribute.disabled(
                  name == details.host || room_controls_busy(model),
                ),
                event.on_click(KickPlayerPressed(details.id, name)),
              ],
              [html.text("Kick")],
            ),
          ])
      },
    ],
  )
}

fn view_game_room(model: Model, details: lobby_api.GameDetails) -> Element(Msg) {
  let lobby_api.GameDetails(id:, host:, players:, player_count:, ..) = details
  let #(is_host, is_member) = case credentials(model) {
    Ok(#(name, _)) -> #(name == host, list.contains(players, name))
    Error(_) -> #(False, False)
  }
  html.div([attribute.id("page-container"), attribute.class("lobby-page")], [
    html.div([attribute.class("lobby-header")], [
      html.h1([], [html.text(id)]),
      html.button([event.on_click(BackToLobby)], [html.text("Back to lobby")]),
    ]),
    view_errors(model),
    html.p([], [html.text("Host: " <> host)]),
    html.p([], [html.text(settings_summary(details.settings))]),
    html.p([], [html.text("Share this page's URL to invite players.")]),
    html.div([attribute.class("lobby-section")], [
      html.h2([], [html.text("Players")]),
      html.p([], [
        html.text(
          "Longer cooldowns handicap a player by making them wait longer between moves.",
        ),
      ]),
      keyed.ul(
        [attribute.class("players-list")],
        list.map(players, fn(name) {
          #(name, view_player(model, details, name, is_host))
        }),
      ),
    ]),
    html.div([attribute.class("game-actions")], [
      case is_host, is_member {
        True, _ ->
          html.button(
            [
              attribute.disabled(player_count < 2 || room_controls_busy(model)),
              event.on_click(StartGamePressed(id)),
            ],
            [html.text("Start game")],
          )
        _, False ->
          html.button(
            [
              attribute.disabled(model.pending_action),
              event.on_click(JoinGamePressed(id)),
            ],
            [html.text("Join game")],
          )
        _, True ->
          html.p([], [html.text("Waiting for host to start the game.")])
      },
      case is_host, is_member {
        True, _ ->
          html.button(
            [
              attribute.class("danger"),
              attribute.disabled(room_controls_busy(model)),
              event.on_click(CancelGamePressed(id)),
            ],
            [html.text("Cancel game")],
          )
        False, True ->
          html.button(
            [
              attribute.disabled(model.pending_action),
              event.on_click(LeaveGamePressed(id)),
            ],
            [html.text("Leave game")],
          )
        _, _ -> html.text("")
      },
    ]),
  ])
}

fn view_play(model: Model) -> Element(Msg) {
  case model.current_game {
    Some(details) ->
      case details.phase {
        shared_game.Negotiating -> view_game_room(model, details)
        _ ->
          html.div([attribute.id("play-page")], [
            html.div([attribute.id("board-container")], [
              html.div([attribute.id("board")], [
                board.view(
                  model.game,
                  selectable_player(model),
                  model.hovered,
                  model.premove,
                  PointHovered,
                  PlayPoint,
                  CancelPremove,
                ),
              ]),
            ]),
            view_countdown_bars(model),
          ])
      }
    None ->
      html.div([attribute.id("page-container"), attribute.class("lobby-page")], [
        html.button([event.on_click(BackToLobby)], [html.text("Back to lobby")]),
        view_errors(model),
        case model.loading_game && model.load_error == None {
          True -> html.p([], [html.text("Loading...")])
          False -> html.text("")
        },
      ])
  }
}

fn seconds_text(milliseconds: Int) -> String {
  int.to_string({ milliseconds + 999 } / 1000) <> "s"
}

fn result_text(state: play_api.State) -> String {
  let best =
    list.fold(state.players, 0, fn(best, status) {
      int.max(
        best,
        dict.get(state.scores, status.player.username) |> result.unwrap(0),
      )
    })
  let winners =
    state.players
    |> list.filter(fn(status) {
      dict.get(state.scores, status.player.username) |> result.unwrap(0) == best
    })
    |> list.map(fn(status) { status.player.username })
  case winners {
    [name] -> name <> " wins with " <> int.to_string(best) <> " points."
    _ ->
      "Tie: "
      <> string.join(winners, ", ")
      <> " · "
      <> int.to_string(best)
      <> " points."
  }
}

fn view_live_status(model: Model) -> Element(Msg) {
  case model.live {
    None ->
      html.p([attribute.class("play-status")], [html.text("Loading board...")])
    Some(state) ->
      html.div([attribute.class("play-status")], [
        html.h2([], [
          html.text(case state.finished {
            True -> "Game over"
            False -> "Playing"
          }),
        ]),
        case state.finished {
          True ->
            html.p(
              [
                attribute.class("game-result"),
                attribute.attribute("role", "status"),
              ],
              [html.text(result_text(state))],
            )
          False -> html.text("")
        },
        html.p([], [
          html.text(case state.finished {
            True ->
              "Area score: stones + surrounded space. No komi; shared borders are neutral."
            False ->
              "Everyone passing ends the game in "
              <> seconds_text(state.end_in_ms)
              <> " unless someone moves."
          }),
        ]),
        html.ul(
          [attribute.class("live-players")],
          list.map(state.players, fn(status) {
            let p = status.player
            let text = player_status_text(state, status)
            html.li([], [
              html.span(
                [
                  attribute.class("player-color"),
                  attribute.style(
                    "background-color",
                    shared_player.color_to_str(p.color),
                  ),
                ],
                [],
              ),
              html.strong([], [html.text(p.username)]),
              html.span([], [html.text(text)]),
            ])
          }),
        ),
        case credentials(model) {
          Ok(#(name, _)) ->
            case list.any(state.players, fn(s) { s.player.username == name }) {
              True -> html.text("")
              False -> html.p([], [html.text("You are spectating.")])
            }
          _ -> html.text("")
        },
        case state.finished {
          True -> html.text("")
          False ->
            html.small([], [
              html.text(
                "Click or tap to play, or queue a premove during cooldown. Click elsewhere to replace it; click it again or press Escape to cancel. The bars disappear when you can play. Capture dead stones before everyone stops.",
              ),
            ])
        },
      ])
  }
}

fn player_status_text(
  state: play_api.State,
  status: play_api.PlayerStatus,
) -> String {
  case state.finished {
    True ->
      int.to_string(
        dict.get(state.scores, status.player.username) |> result.unwrap(0),
      )
      <> " points"
    False if status.cooldown_ms > 0 ->
      "Ready in " <> seconds_text(status.cooldown_ms)
    False if status.pass_in_ms == 0 -> "Passing (can still play)"
    False -> "Ready · passing in " <> seconds_text(status.pass_in_ms)
  }
}

fn menu_popover(
  model: Model,
  key: String,
  text: String,
  label: String,
  class: String,
  styles: List(attribute.Attribute(Msg)),
  content: List(Element(Msg)),
) -> Element(Msg) {
  let expanded = model.expanded_menu == Some(key)
  let panel_id = "menu-panel-" <> key
  html.div(
    [
      attribute.class(
        "item menu-popover"
        <> case expanded {
          True -> " expanded"
          False -> ""
        },
      ),
    ],
    [
      html.button(
        list.append(
          [
            attribute.class("icon " <> class),
            attribute.type_("button"),
            attribute.attribute("aria-label", label),
            attribute.attribute("aria-expanded", case expanded {
              True -> "true"
              False -> "false"
            }),
            attribute.attribute("aria-controls", panel_id),
            event.on_click(ToggleMenu(key)),
          ],
          styles,
        ),
        [html.text(text)],
      ),
      html.div([attribute.id(panel_id), attribute.class("menu-panel")], content),
    ],
  )
}

fn view_menu(model: Model) -> Element(Msg) {
  let #(ping_class, ping) = view_ping(model.ping)
  let playing = case model.route, model.current_game, model.player {
    Play(_), Some(details), player_info.LoggedIn(_, _)
      if details.phase != shared_game.Negotiating
    -> True
    _, _, _ -> False
  }
  case playing {
    False ->
      html.div([attribute.id("menu")], [
        view_menu_item("", "!", "menu"),
        view_menu_item("ping " <> ping_class, ping, ""),
      ])
    True -> {
      let title = case model.current_game {
        Some(details) -> details.id
        None -> "Game"
      }
      let extra = case model.live {
        None -> []
        Some(state) -> {
          let end_label = case state.finished {
            True -> result_text(state)
            False ->
              "Everyone passing ends the game in "
              <> seconds_text(state.end_in_ms)
              <> " unless someone moves."
          }
          let end =
            menu_popover(
              model,
              "end",
              case state.finished {
                True -> "✓"
                False -> int.to_string({ state.end_in_ms + 999 } / 1000)
              },
              end_label,
              "timer-icon end-icon",
              [],
              [
                html.strong([], [
                  html.text(case state.finished {
                    True -> "Game over"
                    False -> "Automatic passing"
                  }),
                ]),
                html.p([], [html.text(end_label)]),
                html.p([], [
                  html.text(
                    "A player passes after 10 seconds of being ready. A move clears their pass; everyone passing ends the game.",
                  ),
                ]),
              ],
            )
          [
            end,
            ..list.map(state.players, fn(status) {
              let p = status.player
              let own = case credentials(model) {
                Ok(#(name, _)) -> name == p.username
                Error(_) -> False
              }
              let name =
                p.username
                <> case own {
                  True -> " (you)"
                  False -> ""
                }
              let label = name <> ": " <> player_status_text(state, status)
              let text = case state.finished {
                True ->
                  int.to_string(
                    dict.get(state.scores, p.username) |> result.unwrap(0),
                  )
                False if status.cooldown_ms > 0 ->
                  int.to_string({ status.cooldown_ms + 999 } / 1000)
                False if status.pass_in_ms == 0 -> "P"
                False -> int.to_string({ status.pass_in_ms + 999 } / 1000)
              }
              menu_popover(
                model,
                "player-" <> p.username,
                text,
                label,
                "timer-icon player-icon"
                  <> case own {
                  True -> " own-player"
                  False -> ""
                },
                [
                  attribute.style(
                    "background-color",
                    shared_player.color_to_str(p.color),
                  ),
                  attribute.style("color", case p.color {
                    shared_player.Black
                    | shared_player.Blue
                    | shared_player.Purple -> "#FFF"
                    _ -> "#111"
                  }),
                ],
                [
                  html.strong([], [html.text(name)]),
                  html.p([], [html.text(player_status_text(state, status))]),
                ],
              )
            })
          ]
        }
      }
      html.div(
        [
          attribute.id("menu"),
          attribute.class("playing-menu"),
          attribute.style("--menu-count", int.to_string(3 + list.length(extra))),
        ],
        list.append(
          [
            menu_popover(
              model,
              "game",
              "!",
              "Game info: " <> title,
              case model.load_error != None || model.action_error != None {
                True -> "has-error"
                False -> ""
              },
              [],
              [
                html.strong([], [html.text(title)]),
                view_errors(model),
                view_live_status(model),
              ],
            ),
            html.div([attribute.class("item")], [
              html.button(
                [
                  attribute.class("icon"),
                  attribute.type_("button"),
                  attribute.attribute("aria-label", "Back to lobby"),
                  event.on_click(BackToLobby),
                ],
                [
                  html.text("↩"),
                  html.span([attribute.class("tooltip")], [
                    html.text(" Back to lobby"),
                  ]),
                ],
              ),
            ]),
            view_menu_item("ping " <> ping_class, ping, "Connection round trip"),
          ],
          extra,
        ),
      )
    }
  }
}

fn view_countdown_bars(model: Model) -> Element(Msg) {
  case credentials(model), model.live {
    Ok(#(name, _)), Some(state) if !state.finished -> {
      case
        list.find(state.players, fn(status) {
          status.player.username == name && status.cooldown_ms > 0
        })
      {
        Error(_) -> html.text("")
        Ok(status) -> {
          let cooldown = case model.current_game {
            Some(details) ->
              dict.get(details.cooldowns, name)
              |> result.unwrap(shared_game.base_cooldown(details.settings))
            None -> shared_game.base_cooldown(shared_game.default_settings)
          }
          let total = int.max(1, cooldown * 1000)
          let remaining = int.clamp(status.cooldown_ms, min: 0, max: total)
          let label = name <> ": " <> player_status_text(state, status)
          html.div(
            [
              attribute.id("countdown-bars"),
              attribute.style(
                "--remaining",
                int.to_string(remaining * 100 / total) <> "%",
              ),
            ],
            [
              html.div(
                [
                  attribute.class("countdown-bar countdown-first"),
                  attribute.attribute("role", "meter"),
                  attribute.attribute("aria-label", label),
                  attribute.attribute("aria-valuemin", "0"),
                  attribute.attribute("aria-valuemax", int.to_string(total)),
                  attribute.attribute("aria-valuenow", int.to_string(remaining)),
                  attribute.attribute("aria-valuetext", label),
                ],
                [html.div([attribute.class("countdown-fill")], [])],
              ),
              html.div(
                [
                  attribute.class("countdown-bar countdown-last"),
                  attribute.attribute("aria-hidden", "true"),
                ],
                [html.div([attribute.class("countdown-fill")], [])],
              ),
            ],
          )
        }
      }
    }
    _, _ -> html.text("")
  }
}

pub fn view(model: Model) -> Element(Msg) {
  html.div([attribute.id("container")], [
    view_menu(model),
    case model.player {
      player_info.LoggedIn(name, _) ->
        case model.route {
          PlayerInfo ->
            html.div([attribute.id("page-container")], [
              html.p([], [html.text("Playing as " <> name)]),
              html.button([event.on_click(BackToLobby)], [
                html.text("Go to lobby"),
              ]),
            ])
          CreateJoinGame -> view_lobby(model)
          Play(_) -> view_play(model)
        }
      _ -> player_info.view(model.player, Register)
    },
  ])
}
