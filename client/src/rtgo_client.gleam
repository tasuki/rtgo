import config
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/javascript/promise
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
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
import rtgo_client/color_picker
import rtgo_client/player_info
import rtgo_client/replay
import rtgo_shared/auth
import rtgo_shared/auth_api
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
  Replay(record_id: Option(String))
}

pub type Model {
  Model(
    route: Route,
    player: player_info.PlayerStatus,
    preferred_color: shared_player.Color,
    pending_preference: Bool,
    preference_version: Int,
    preference_error: Option(String),
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
    create_timing: String,
    create_reserve: String,
    create_gap: String,
    drag_in_flight: Int,
    cooldown_drafts: Dict(String, String),
    live: Option(play_api.State),
    loading_board: Bool,
    hovered: Option(go.Point),
    premove: Option(go.Point),
    expanded_menu: Option(String),
    replay: replay.Model,
  )
}

pub fn initial_model(
  route: Route,
  player: player_info.PlayerStatus,
  server_url: String,
) -> Model {
  let default_cooldown = shared_game.base_cooldown(shared_game.default_settings)
  Model(
    route: route,
    player: player,
    preferred_color: shared_player.Black,
    pending_preference: False,
    preference_version: 0,
    preference_error: None,
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
    create_timing: "crazy_cooldown",
    create_reserve: "5",
    create_gap: "1000",
    drag_in_flight: 0,
    cooldown_drafts: dict.new(),
    live: None,
    loading_board: False,
    hovered: None,
    premove: None,
    expanded_menu: None,
    replay: replay.new(),
  )
}

pub fn creation_settings(model: Model) -> Result(shared_game.Settings, Nil) {
  use timing <- result.try(case model.create_timing {
    "drag_derby" -> Ok(shared_game.DragDerby)
    mode -> {
      use seconds <- result.try(int.parse(model.create_cooldown))
      case mode {
        "crazy_cooldown" -> Ok(shared_game.Cooldown(seconds))
        "cushy_cooldown" -> Ok(shared_game.CushyCooldown(seconds))
        "stone_savings" -> {
          use cap <- result.try(int.parse(model.create_reserve))
          use gap <- result.try(int.parse(model.create_gap))
          Ok(shared_game.StoneSavings(seconds, cap, gap))
        }
        _ -> Error(Nil)
      }
    }
  })
  let settings =
    shared_game.Settings(
      model.create_board_size,
      model.create_game_type,
      timing,
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
    ["replay"] -> Replay(None)
    ["replay", id] -> Replay(Some(id))
    _ -> PlayerInfo
  }
}

fn route_to_str(route: Route) -> String {
  case route {
    PlayerInfo -> "/"
    CreateJoinGame -> "/create"
    Play(game_id) -> "/play/" <> game_id
    Replay(None) -> "/replay"
    Replay(Some(id)) -> "/replay/" <> id
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
  let server_url = config.server_url()
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
  ReplayMsg(replay.Msg)
  SgfLoaded(Int, Result(String, rsvp.Error))
  Refresh(Int)
  PingRequested
  PingResponded(Result(Duration, rsvp.Error))
  Register(String)
  PreferredColorChanged(String)
  PreferredColorLoaded(Int, Result(shared_player.Color, rsvp.Error))
  PreferredColorSaved(
    Int,
    shared_player.Color,
    Result(shared_player.Color, rsvp.Error),
  )
  ChooseGameColor(String)
  GameColorChosen(Int, String, shared_player.Color, Result(Nil, rsvp.Error))
  LoggedInResponse(Result(auth.LogInResponse, rsvp.Error))
  GamesLoaded(Int, Result(lobby_api.ListGamesResponse, rsvp.Error))
  GameLoaded(Int, Result(lobby_api.GetGameResponse, rsvp.Error))
  CreateGamePressed
  BoardSizeChanged(String)
  GameTypeChanged(String)
  CooldownChanged(String)
  TimeModeChanged(String)
  SavingsCapChanged(String)
  SavingsGapChanged(String)
  LeaveGamePressed(String)
  CancelGamePressed(String)
  GameLeft(Int, Result(Nil, rsvp.Error))
  GameCancelled(Int, Result(Nil, rsvp.Error))
  AddBotPressed(String)
  BotAdded(Int, Result(Nil, rsvp.Error))
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
  DragPoints(List(go.Point))
  DragResponded(Int, Result(play_api.State, rsvp.Error))
  PassPressed
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
      || res.status == 503
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
    SgfLoaded(version, _)
    | Refresh(version)
    | GamesLoaded(version, _)
    | GameLoaded(version, _)
    | GameCreated(version, _)
    | GameJoined(version, _, _)
    | GameStarted(version, _, _)
    | GameLeft(version, _)
    | GameCancelled(version, _)
    | BotAdded(version, _)
    | PlayerKicked(version, _, _)
    | PlayerCooldownSet(version, _, _, _)
    | BoardRefresh(version)
    | BoardLoaded(version, _)
    | MoveResponded(version, _)
    | DragResponded(version, _)
    | GameColorChosen(version, _, _, _) -> version != model.page_version
    PreferredColorLoaded(version, _) | PreferredColorSaved(version, _, _) ->
      version != model.preference_version
    _ -> False
  }
  let follows_save = case msg {
    StartGamePressed(_)
    | KickPlayerPressed(_, _)
    | CancelGamePressed(_)
    | ChooseGameColor(_)
    | AddBotPressed(_) -> model.saving_cooldown
    _ -> False
  }
  case stale, follows_save {
    True, _ -> #(model, effect.none())
    False, True ->
      case model.after_save {
        None -> #(Model(..model, after_save: Some(msg)), effect.none())
        Some(_) -> #(model, effect.none())
      }
    False, False ->
      case model.pending_preference, msg {
        True, CreateGamePressed | True, JoinGamePressed(_) -> #(
          model,
          effect.none(),
        )
        _, _ -> update_current(model, msg)
      }
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
          drag_in_flight: 0,
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
          replay: replay.new(),
        )
      update(model, Refresh(model.page_version))
    }
    ReplayMsg(msg) -> #(
      Model(..model, replay: replay.update(model.replay, msg)),
      effect.none(),
    )
    SgfLoaded(_, response) -> {
      let replay = case response {
        Ok(source) -> replay.load(model.replay, source)
        Error(error) ->
          replay.Model(..model.replay, error: Some(action_error(error)))
      }
      #(Model(..model, replay: replay, loading_game: False), effect.none())
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
        Replay(Some(id)) -> #(
          Model(..model, loading_game: True),
          rsvp.get(
            model.server_url <> "/games/" <> uri.percent_encode(id) <> "/sgf",
            rsvp.expect_ok_response(fn(res) {
              SgfLoaded(
                model.page_version,
                result.map(res, fn(response) { response.body }),
              )
            }),
          ),
        )
        Replay(None) | PlayerInfo -> #(model, effect.none())
      }
    PingRequested -> #(model, ping_server(model.server_url))
    PingResponded(duration_res) -> #(
      Model(..model, ping: option.from_result(duration_res)),
      wait(1000, PingRequested),
    )
    Register(name) -> #(
      Model(..model, player: player_info.VerifyingName(name)),
      player_info.register_with_color(
        model.server_url,
        name,
        model.preferred_color,
        LoggedInResponse,
      ),
    )
    LoggedInResponse(Ok(lir)) -> {
      case player_info.decode_login_jwt(lir.jwt) {
        Ok(#(name, _exp)) -> #(
          Model(
            ..model,
            player: player_info.LoggedIn(name, lir.jwt),
            pending_preference: True,
            preference_version: model.preference_version + 1,
            preference_error: None,
          ),
          effect.batch([
            player_info.save_login(lir.jwt),
            rsvp.send(
              auth_api.preferred_color_request(model.server_url, lir.jwt),
              rsvp.expect_json(auth_api.preferred_color_decoder(), fn(res) {
                PreferredColorLoaded(model.preference_version + 1, res)
              }),
            ),
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
              player_info.register_with_color(
                model.server_url,
                name,
                model.preferred_color,
                LoggedInResponse,
              ),
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
    PreferredColorChanged(value) ->
      case shared_player.color_from_name(value) {
        Error(_) -> #(model, effect.none())
        Ok(color) ->
          case
            credentials(model),
            model.pending_preference || model.pending_action
          {
            Ok(#(_, jwt)), False if color != model.preferred_color -> #(
              Model(
                ..model,
                preferred_color: color,
                pending_preference: True,
                preference_version: model.preference_version + 1,
                preference_error: None,
              ),
              rsvp.send(
                auth_api.set_preferred_color_request(
                  model.server_url,
                  jwt,
                  color,
                ),
                rsvp.expect_json(auth_api.preferred_color_decoder(), fn(res) {
                  PreferredColorSaved(
                    model.preference_version + 1,
                    model.preferred_color,
                    res,
                  )
                }),
              ),
            )
            Error(_), _ -> #(
              Model(..model, preferred_color: color),
              effect.none(),
            )
            _, _ -> #(model, effect.none())
          }
      }
    PreferredColorLoaded(_, response) ->
      case response {
        Ok(color) -> #(
          Model(
            ..model,
            preferred_color: color,
            pending_preference: False,
            preference_error: None,
          ),
          effect.none(),
        )
        Error(error) -> #(
          Model(
            ..model,
            pending_preference: False,
            preference_error: Some(action_error(error)),
          ),
          effect.none(),
        )
      }
    PreferredColorSaved(_, previous, response) ->
      case response {
        Ok(color) -> #(
          Model(
            ..model,
            preferred_color: color,
            pending_preference: False,
            preference_error: None,
          ),
          effect.none(),
        )
        Error(error) -> #(
          Model(
            ..model,
            preferred_color: previous,
            pending_preference: False,
            preference_error: Some(action_error(error)),
          ),
          effect.none(),
        )
      }
    ChooseGameColor(value) ->
      case
        model.route,
        credentials(model),
        model.current_game,
        shared_player.color_from_name(value),
        model.pending_action
      {
        Play(id), Ok(#(name, jwt)), Some(details), Ok(color), False
          if details.id == id && details.phase == shared_game.Negotiating
        -> {
          let taken =
            details.colors
            |> dict.to_list
            |> list.any(fn(entry) { entry.0 != name && entry.1 == color })
          case
            list.contains(details.players, name)
            && list.contains(shared_game.colors(details.settings), color)
            && !taken
            && dict.get(details.colors, name) != Ok(color)
          {
            False -> #(model, effect.none())
            True -> #(
              Model(..model, pending_action: True, action_error: None),
              rsvp.send(
                lobby_api.choose_color_request(model.server_url, id, jwt, color),
                rsvp.expect_ok_response(fn(res) {
                  GameColorChosen(
                    model.page_version,
                    name,
                    color,
                    result.replace(res, Nil),
                  )
                }),
              ),
            )
          }
        }
        _, _, _, _, _ -> #(model, effect.none())
      }
    GameColorChosen(_, name, color, Ok(Nil)) ->
      case model.current_game {
        Some(details) -> {
          let model =
            Model(
              ..model,
              current_game: Some(
                lobby_api.GameDetails(
                  ..details,
                  colors: dict.insert(details.colors, name, color),
                ),
              ),
              pending_action: False,
              loading_game: True,
              page_version: model.page_version + 1,
              action_error: None,
              load_error: None,
            )
          #(model, load_game(model, details.id))
        }
        None -> #(model, effect.none())
      }
    GameColorChosen(_, _, _, Error(error)) ->
      action_failed(model, action_error(error))
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
        Some(state) if state.finished && state.scoring != play_api.Scoring ->
          effect.none()
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
    PassPressed ->
      case
        model.route,
        credentials(model),
        local_status(model),
        model.pending_action,
        model.drag_in_flight
      {
        Play(id), Ok(#(_, jwt)), Some(status), False, 0
          if status.cooldown_ms == 0 && status.pass_in_ms != 0
        -> #(
          Model(
            ..model,
            pending_action: True,
            premove: None,
            action_error: None,
          ),
          rsvp.send(
            play_api.pass_request(model.server_url, id, jwt),
            rsvp.expect_json(play_api.state_decoder(), fn(res) {
              MoveResponded(model.page_version, res)
            }),
          ),
        )
        _, _, _, _, _ -> #(model, effect.none())
      }
    DragPoints(points) -> send_drag(model, points)
    DragResponded(_, response) -> {
      let model =
        Model(..model, drag_in_flight: int.max(0, model.drag_in_flight - 1))
      case response {
        Ok(state) -> #(accept_board(model, state), effect.none())
        Error(error) -> #(
          Model(..model, action_error: Some(action_error(error))),
          effect.none(),
        )
      }
    }
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
        Some(_), False, True ->
          case is_drag(model) {
            True -> send_drag(model, [point])
            False -> send_move(model, point)
          }
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
    TimeModeChanged(value) -> #(
      Model(..model, create_timing: value),
      effect.none(),
    )
    SavingsCapChanged(value) -> #(
      Model(..model, create_reserve: value),
      effect.none(),
    )
    SavingsGapChanged(value) -> #(
      Model(..model, create_gap: value),
      effect.none(),
    )
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
            "Choose a valid board size and timing settings. Base interval: 1–60s; reserve: 1–20; minimum gap: 0 to the base interval.",
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
    AddBotPressed(id) ->
      case host_room(model, id), model.pending_action {
        Ok(#(jwt, _)), False -> #(
          Model(..model, pending_action: True, action_error: None),
          rsvp.send(
            lobby_api.add_bot_request(model.server_url, id, jwt),
            rsvp.expect_ok_response(fn(res) {
              BotAdded(model.page_version, result.replace(res, Nil))
            }),
          ),
        )
        _, _ -> #(model, effect.none())
      }
    BotAdded(_, Ok(Nil)) ->
      update(Model(..model, pending_action: False), Refresh(model.page_version))
    BotAdded(_, Error(error)) -> action_failed(model, action_error(error))
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
              colors: dict.delete(details.colors, target),
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

fn is_drag(model: Model) -> Bool {
  case model.current_game {
    Some(details) -> details.settings.time_settings == shared_game.DragDerby
    None -> False
  }
}

fn send_drag(model: Model, points: List(go.Point)) -> #(Model, Effect(Msg)) {
  case
    is_drag(model),
    model.route,
    credentials(model),
    local_status(model),
    model.pending_action
  {
    True, Play(id), Ok(#(_, jwt)), Some(_), False -> {
      let points =
        list.filter(points, fn(point) { empty_point(model.game, point) })
      #(
        Model(
          ..model,
          drag_in_flight: model.drag_in_flight + list.length(points),
          premove: None,
          hovered: None,
          expanded_menu: None,
          action_error: None,
        ),
        effect.batch(
          list.map(points, fn(point) {
            rsvp.send(
              play_api.move_request(model.server_url, id, jwt, point),
              rsvp.expect_json(play_api.state_decoder(), fn(res) {
                DragResponded(model.page_version, res)
              }),
            )
          }),
        ),
      )
    }
    _, _, _, _, _ -> #(model, effect.none())
  }
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
      attribute.disabled(model.pending_action || model.pending_preference),
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
  let size = int.to_string(settings.board_size)
  shared_game.game_type_label(settings.game_type)
  <> " · "
  <> size
  <> "×"
  <> size
  <> " · "
  <> shared_game.timing_label(settings.time_settings)
  <> case settings.time_settings {
    shared_game.DragDerby -> " · unlimited"
    shared_game.StoneSavings(seconds, cap, gap) ->
      " · "
      <> int.to_string(seconds)
      <> "s base · "
      <> int.to_string(cap)
      <> " stone reserve · "
      <> int.to_string(gap)
      <> "ms minimum gap"
    _ ->
      " · "
      <> int.to_string(shared_game.base_cooldown(settings))
      <> "s cooldown"
  }
}

fn create_game_field(
  id: String,
  label: String,
  controls: List(Element(Msg)),
) -> Element(Msg) {
  html.div([attribute.class("create-game-field")], [
    html.label([attribute.for(id)], [html.text(label)]),
    html.div([attribute.class("create-game-control")], controls),
  ])
}

fn view_create_form(model: Model) -> Element(Msg) {
  html.form(
    [
      attribute.class("create-game"),
      event.on_submit(fn(_) { CreateGamePressed }),
    ],
    [
      html.h2([], [html.text("Create game")]),
      create_game_field("game-type", "Game type", [
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
      ]),
      create_game_field("board-size", "Board size", [
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
      ]),
      create_game_field("time-mode", "Time system", [
        html.select(
          [
            attribute.id("time-mode"),
            attribute.attribute("aria-describedby", "time-mode-help"),
            attribute.disabled(model.pending_action),
            event.on_change(TimeModeChanged),
          ],
          list.map(
            [
              #("crazy_cooldown", "Crazy Cooldown"),
              #("cushy_cooldown", "Cushy Cooldown"),
              #("stone_savings", "Stone Savings"),
              #("simul_slaughter", "Simul Slaughter — coming later"),
              #("drag_derby", "Drag Derby"),
            ],
            fn(entry) {
              html.option(
                [
                  attribute.value(entry.0),
                  attribute.selected(model.create_timing == entry.0),
                  attribute.disabled(entry.0 == "simul_slaughter"),
                ],
                entry.1,
              )
            },
          ),
        ),
        html.p(
          [
            attribute.id("time-mode-help"),
            attribute.class("create-game-help"),
          ],
          [
            html.text(case model.create_timing {
              "cushy_cooldown" ->
                "Ready time credits up to 25% of your next cooldown. No banked stones."
              "stone_savings" ->
                "Bank stones: each additional stored stone takes longer to earn (1×, 2×, 3×…). Pass explicitly; saving will not auto-pass."
              "drag_derby" ->
                "No cooldown. Click and drag to paint the board with placement attempts."
              _ ->
                "One stone, then your full cooldown. Everyone starts cooling down."
            }),
          ],
        ),
      ]),
      create_game_field(
        "cooldown",
        case model.create_timing {
          "stone_savings" -> "Base recharge interval (seconds)"
          _ -> "Cooldown (seconds)"
        },
        [
          html.input([
            attribute.id("cooldown"),
            attribute.type_("number"),
            attribute.min("1"),
            attribute.max("60"),
            attribute.required(True),
            attribute.value(model.create_cooldown),
            attribute.disabled(
              model.pending_action || model.create_timing == "drag_derby",
            ),
            event.on_input(CooldownChanged),
          ]),
        ],
      ),
      case model.create_timing {
        "stone_savings" ->
          html.div([attribute.class("create-game-savings")], [
            create_game_field("savings-cap", "Maximum saved stones", [
              html.input([
                attribute.id("savings-cap"),
                attribute.type_("number"),
                attribute.min("1"),
                attribute.max("20"),
                attribute.required(True),
                attribute.value(model.create_reserve),
                attribute.disabled(model.pending_action),
                event.on_input(SavingsCapChanged),
              ]),
            ]),
            create_game_field(
              "savings-gap",
              "Minimum placement gap (milliseconds)",
              [
                html.input([
                  attribute.id("savings-gap"),
                  attribute.type_("number"),
                  attribute.min("0"),
                  attribute.max(int.to_string(
                    { int.parse(model.create_cooldown) |> result.unwrap(5) }
                    * 1000,
                  )),
                  attribute.required(True),
                  attribute.value(model.create_gap),
                  attribute.disabled(model.pending_action),
                  event.on_input(SavingsGapChanged),
                ]),
              ],
            ),
          ])
        _ -> html.text("")
      },
      html.button(
        [
          attribute.type_("submit"),
          attribute.disabled(model.pending_action || model.pending_preference),
        ],
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
  let finished_games =
    list.filter(model.lobby_games, fn(game) {
      game.phase == shared_game.Finished
    })
  html.div([attribute.id("page-container"), attribute.class("lobby-page")], [
    html.div([attribute.class("lobby-header")], [
      html.h1([], [html.text("Lobby")]),
    ]),
    case credentials(model) {
      Ok(#(name, _)) -> html.p([], [html.text("Playing as " <> name)])
      Error(_) -> html.text("")
    },
    color_picker.view(
      "preferred-color",
      "Preferred color",
      Some(model.preferred_color),
      shared_player.all_colors,
      [],
      model.pending_preference || model.pending_action,
      PreferredColorChanged,
    ),
    case model.preference_error {
      Some(message) ->
        html.p(
          [attribute.class("error"), attribute.attribute("role", "status")],
          [html.text(message)],
        )
      None -> html.text("")
    },
    view_errors(model),
    html.a([attribute.href("/replay")], [html.text("Replay an SGF recording")]),
    view_create_form(model),
    case
      model.loading_lobby && !model.lobby_loaded && model.load_error == None
    {
      True -> html.p([], [html.text("Loading...")])
      False ->
        html.div([], [
          view_games(model, "Open for joining", open_games),
          view_games(model, "In progress", running_games),
          view_games(model, "Finished games", finished_games),
        ])
    },
  ])
}

fn room_controls_busy(model: Model) -> Bool {
  model.pending_action && !model.saving_cooldown || model.after_save != None
}

fn view_room_color(
  model: Model,
  details: lobby_api.GameDetails,
  name: String,
) -> Element(Msg) {
  let color = dict.get(details.colors, name) |> option.from_result
  case credentials(model) {
    Ok(#(current, _)) if current == name -> {
      let used =
        details.colors
        |> dict.to_list
        |> list.filter_map(fn(entry) {
          case entry.0 == name {
            True -> Error(Nil)
            False -> Ok(entry.1)
          }
        })
      color_picker.view(
        "game-color-" <> name,
        "Your color",
        color,
        shared_game.colors(details.settings),
        used,
        room_controls_busy(model),
        ChooseGameColor,
      )
    }
    _ ->
      case color {
        None -> html.text("")
        Some(color) ->
          html.span([attribute.class("room-color")], [
            html.span(
              [
                attribute.class("player-color"),
                attribute.attribute("aria-hidden", "true"),
                attribute.style(
                  "background-color",
                  shared_player.color_to_str(color),
                ),
              ],
              [],
            ),
            html.text(shared_player.color_name(color)),
          ])
      }
  }
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
          html.text(case details.settings.time_settings {
            shared_game.DragDerby -> "Unlimited placements"
            shared_game.StoneSavings(_, _, _) ->
              int.to_string(seconds) <> "s base recharge"
            shared_game.CushyCooldown(_) ->
              int.to_string(seconds) <> "s cooldown · up to 25% credit"
            _ -> int.to_string(seconds) <> "s between moves"
          }),
        ]),
      ]),
      view_room_color(model, details, name),
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
              attribute.disabled(
                model.pending_action
                || details.settings.time_settings == shared_game.DragDerby,
              ),
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
    html.div([attribute.class("game-actions")], [
      case is_host {
        True ->
          html.button(
            [
              attribute.disabled(
                room_controls_busy(model)
                || player_count
                >= list.length(shared_game.colors(details.settings)),
              ),
              event.on_click(AddBotPressed(id)),
            ],
            [html.text("Add KataGo bot")],
          )
        False -> html.text("")
      },
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
              attribute.disabled(
                model.pending_action || model.pending_preference,
              ),
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
    html.div([attribute.class("lobby-section")], [
      html.h2([], [html.text("Players")]),
      html.p([], [
        html.text(case details.settings.time_settings {
          shared_game.DragDerby -> "Drag Derby has no timing handicaps."
          shared_game.StoneSavings(_, _, _) ->
            "Longer base recharge intervals handicap a player by earning stones more slowly."
          _ ->
            "Longer cooldowns handicap a player by making them wait longer between moves."
        }),
      ]),
      keyed.ul(
        [attribute.class("players-list")],
        list.map(players, fn(name) {
          #(name, view_player(model, details, name, is_host))
        }),
      ),
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
                board.view_with_drag(
                  model.game,
                  model.live
                    |> option.map(fn(s) { s.dead_stones })
                    |> option.unwrap([]),
                  final_area(model.live),
                  selectable_player(model),
                  model.hovered,
                  model.premove,
                  PointHovered,
                  PlayPoint,
                  CancelPremove,
                  is_drag(model),
                  DragPoints,
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

fn result_ready(state: play_api.State) -> Bool {
  state.finished
  && {
    state.scoring == play_api.Estimated || state.scoring == play_api.Unavailable
  }
}

fn final_area(
  live: Option(play_api.State),
) -> Dict(go.Point, shared_player.Player) {
  case live {
    Some(state) ->
      case result_ready(state) {
        True -> state.board |> go.remove_stones(state.dead_stones) |> go.area
        False -> dict.new()
      }
    None -> dict.new()
  }
}

fn result_players(state: play_api.State) -> List(play_api.PlayerStatus) {
  case result_ready(state) {
    False -> state.players
    True ->
      list.sort(state.players, fn(a, b) {
        let a_score =
          dict.get(state.scores, a.player.username) |> result.unwrap(0)
        let b_score =
          dict.get(state.scores, b.player.username) |> result.unwrap(0)
        case int.compare(b_score, a_score) {
          order.Eq -> string.compare(a.player.username, b.player.username)
          compared -> compared
        }
      })
  }
}

fn seconds_text(milliseconds: Int) -> String {
  int.to_string({ milliseconds + 999 } / 1000) <> "s"
}

fn result_text(state: play_api.State) -> String {
  case state.scoring {
    play_api.Scoring -> "Scoring with KataGo…"
    play_api.Estimated -> "KataGo estimate: " <> winner_text(state)
    play_api.Unavailable -> "Unassisted area score: " <> winner_text(state)
    play_api.NotScored -> "Awaiting score"
  }
}

fn scoring_explanation(state: play_api.State) -> String {
  case state.scoring {
    play_api.Scoring ->
      "KataGo is estimating dead groups. Moves are locked; the result will update automatically."
    play_api.Estimated ->
      "KataGo estimate. Dead stones excluded: "
      <> int.to_string(list.length(state.dead_stones))
      <> " (marked ×). Shading shows scored area (stones + territory). Uncertain groups stay. Multiplayer estimates are approximate. Chinese-like area scoring; no komi; shared borders are neutral."
    play_api.Unavailable ->
      "KataGo unavailable. This is an unassisted area score; dead stones were not removed. Shading shows scored area (stones + territory)."
    play_api.NotScored ->
      "Chinese-like area scoring: stones + surrounded space. No komi; shared borders are neutral."
  }
}

fn winner_text(state: play_api.State) -> String {
  let best =
    list.fold(state.players, 0, fn(best, status) {
      int.max(
        best,
        dict.get(state.scores, status.player.username) |> result.unwrap(0),
      )
    })
  let winners =
    result_players(state)
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

fn view_recording_actions(model: Model) -> Element(Msg) {
  case model.route, model.live {
    Play(id), Some(state) if state.finished ->
      html.div([attribute.class("game-actions")], [
        html.a([attribute.href("/replay/" <> id)], [html.text("Replay game")]),
        html.a(
          [
            attribute.href(model.server_url <> "/games/" <> id <> "/sgf"),
            attribute.attribute("download", ""),
          ],
          [html.text("Download SGF")],
        ),
      ])
    _, _ -> html.text("")
  }
}

fn end_description(state: play_api.State) -> String {
  case state.end_in_ms < 0 {
    True -> "Everyone passing ends the game. Saving stones does not auto-pass."
    False ->
      "Everyone passing ends the game in "
      <> seconds_text(state.end_in_ms)
      <> " unless someone moves."
  }
}

fn view_pass_button(model: Model) -> Element(Msg) {
  case local_status(model) {
    Some(status) ->
      html.button(
        [
          attribute.type_("button"),
          attribute.disabled(
            model.pending_action
            || model.drag_in_flight > 0
            || status.cooldown_ms > 0
            || status.pass_in_ms == 0,
          ),
          event.on_click(PassPressed),
        ],
        [
          html.text(case status.pass_in_ms == 0 {
            True -> "Passing — play to resume"
            False -> "Pass"
          }),
        ],
      )
    None -> html.text("")
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
            True if state.scoring == play_api.Scoring -> "Scoring…"
            True -> "Game over"
            False -> "Playing"
          }),
        ]),
        case model.current_game {
          Some(details) ->
            html.p([], [html.text(settings_summary(details.settings))])
          None -> html.text("")
        },
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
            True -> scoring_explanation(state)
            False -> end_description(state)
          }),
        ]),
        view_pass_button(model),
        view_recording_actions(model),
        html.ul(
          [attribute.class("live-players")],
          list.map(result_players(state), fn(status) {
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
              html.text(case is_drag(model) {
                True ->
                  "Click and drag to place stones immediately. Unlimited attempts; normal board legality still applies. Pass to finish, or play to resume before everyone passes."
                False ->
                  "Click or tap to play, or queue a premove while waiting. Click elsewhere to replace it; click it again or press Escape to cancel. Pass when ready; a legal move clears your pass without bypassing timing. KataGo estimates dead groups when play ends."
              }),
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
    True if state.scoring == play_api.Scoring -> "Scoring…"
    True ->
      int.to_string(
        dict.get(state.scores, status.player.username) |> result.unwrap(0),
      )
      <> " points"
    False -> {
      let bank = case dict.get(state.savings, status.player.username) {
        Ok(bank) ->
          int.to_string(bank.credits)
          <> "/"
          <> int.to_string(bank.capacity)
          <> " stones · "
          <> case bank.recharge_ms {
            0 -> "bank full · "
            _ -> "next in " <> seconds_text(bank.recharge_ms) <> " · "
          }
        Error(_) -> ""
      }
      bank
      <> case status.pass_in_ms {
        0 -> "Passing (can still play)"
        _ if status.cooldown_ms > 0 ->
          "Ready in " <> seconds_text(status.cooldown_ms)
        _ if status.pass_in_ms < 0 -> "Ready · explicit pass"
        _ -> "Ready · passing in " <> seconds_text(status.pass_in_ms)
      }
    }
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
            False -> end_description(state)
          }
          let end =
            menu_popover(
              model,
              "end",
              case state.finished {
                True if state.scoring == play_api.Scoring -> "…"
                True -> "✓"
                False if state.end_in_ms < 0 -> "P"
                False -> int.to_string({ state.end_in_ms + 999 } / 1000)
              },
              end_label,
              "timer-icon end-icon",
              [],
              [
                html.strong([], [
                  html.text(case state.finished {
                    True if state.scoring == play_api.Scoring -> "Scoring…"
                    True -> "Game over"
                    False -> "Passing"
                  }),
                ]),
                html.p([], [html.text(end_label)]),
                view_pass_button(model),
                view_recording_actions(model),
                html.p([], [
                  html.text(case state.finished {
                    True -> scoring_explanation(state)
                    False ->
                      "Pass when ready, or play to clear your pass. Passing never resets timing or grants credits. Everyone passing ends the game. Outside Stone Savings, ten seconds of readiness also passes automatically."
                  }),
                ]),
              ],
            )
          [
            end,
            ..list.map(result_players(state), fn(status) {
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
                True if state.scoring == play_api.Scoring -> "…"
                True ->
                  int.to_string(
                    dict.get(state.scores, p.username) |> result.unwrap(0),
                  )
                False if status.cooldown_ms > 0 ->
                  int.to_string({ status.cooldown_ms + 999 } / 1000)
                False if status.pass_in_ms == 0 -> "P"
                False if status.pass_in_ms < 0 ->
                  case dict.get(state.savings, p.username) {
                    Ok(bank) -> int.to_string(bank.credits)
                    Error(_) -> "✓"
                  }
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
                  case own {
                    True -> view_pass_button(model)
                    False -> html.text("")
                  },
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
    case model.route, model.player {
      Replay(_), _ ->
        html.div(
          [attribute.id("page-container"), attribute.class("lobby-page")],
          [
            html.a([attribute.href("/create")], [html.text("Back to lobby")]),
            case model.route {
              Replay(Some(id)) ->
                html.a(
                  [
                    attribute.href(
                      model.server_url
                      <> "/games/"
                      <> uri.percent_encode(id)
                      <> "/sgf",
                    ),
                    attribute.attribute("download", ""),
                  ],
                  [html.text("Download SGF")],
                )
              _ -> html.text("")
            },
            element.map(
              replay.view(model.replay, model.loading_game),
              ReplayMsg,
            ),
          ],
        )
      _, player_info.LoggedIn(name, _) ->
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
          Replay(_) -> html.text("")
        }
      _, _ ->
        player_info.view(
          model.player,
          model.preferred_color,
          PreferredColorChanged,
          Register,
        )
    },
  ])
}
