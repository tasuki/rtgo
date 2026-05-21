import config
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
import lustre/event
import modem
import rsvp
import rtgo_client/board
import rtgo_client/player_info
import rtgo_shared/auth
import rtgo_shared/game as shared_game
import rtgo_shared/go
import rtgo_shared/lobby_api

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
    load_error: Option(String),
    action_error: Option(String),
    create_board_size: Int,
    create_game_type: shared_game.GameType,
    create_cooldown: String,
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
    load_error: None,
    action_error: None,
    create_board_size: shared_game.default_settings.board_size,
    create_game_type: shared_game.default_settings.game_type,
    create_cooldown: int.to_string(default_cooldown),
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
  GameCreated(Int, Result(lobby_api.CreateGameResponse, rsvp.Error))
  JoinGamePressed(String)
  GameJoined(Int, String, Result(lobby_api.JoinGameResponse, rsvp.Error))
  StartGamePressed(String)
  GameStarted(Int, String, Result(lobby_api.StartGameResponse, rsvp.Error))
  OpenGame(String)
  BackToLobby
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
    Model(..model, pending_action: False, action_error: Some(message)),
    effect.none(),
  )
}

fn action_error(error: rsvp.Error) -> String {
  case error {
    rsvp.HttpError(res) if res.status == 401 ->
      "Your login expired. Reload to log in again."
    rsvp.HttpError(res) if res.status == 403 || res.status == 409 -> {
      let decoder = {
        use message <- decode.field("msg", decode.string)
        decode.success(message)
      }
      json.parse(res.body, decoder)
      |> result.unwrap("This action is no longer available.")
    }
    rsvp.HttpError(res) if res.status == 404 -> "This game no longer exists."
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
    | GameCancelled(version, _) -> version != model.page_version
    _ -> False
  }
  case stale {
    True -> #(model, effect.none())
    False -> update_current(model, msg)
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
          loading_game: False,
          loading_lobby: False,
          pending_action: False,
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
      #(model, poll)
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
      case credentials(model), model.pending_action {
        Ok(#(_, jwt)), False -> #(
          Model(..model, pending_action: True, action_error: None),
          rsvp.send(
            lobby_api.start_game_request(model.server_url, id, jwt),
            rsvp.expect_json(
              lobby_api.start_game_response_decoder(),
              fn(result) { GameStarted(model.page_version, id, result) },
            ),
          ),
        )
        _, _ -> #(model, effect.none())
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
    OpenGame(id) -> #(model, modem.push(route_to_str(Play(id)), None, None))
    BackToLobby -> #(
      model,
      modem.push(route_to_str(CreateJoinGame), None, None),
    )
  }
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
      html.ul(
        [],
        list.map(players, fn(name) { html.li([], [html.text(name)]) }),
      ),
    ]),
    case is_host, is_member {
      True, _ ->
        html.button(
          [
            attribute.disabled(player_count < 2 || model.pending_action),
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
      _, True -> html.p([], [html.text("Waiting for host to start the game.")])
    },
    case is_host, is_member {
      True, _ ->
        html.button(
          [
            attribute.class("danger"),
            attribute.disabled(model.pending_action),
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
  ])
}

fn view_play(model: Model) -> Element(Msg) {
  case model.current_game {
    Some(details) ->
      case details.phase {
        shared_game.Negotiating -> view_game_room(model, details)
        _ ->
          html.div([attribute.id("board-container")], [
            html.button(
              [attribute.class("back-to-lobby"), event.on_click(BackToLobby)],
              [html.text("Back to lobby")],
            ),
            html.div([attribute.id("board")], [board.view(model.game)]),
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

pub fn view(model: Model) -> Element(Msg) {
  let #(ping_class, ping) = view_ping(model.ping)
  html.div([attribute.id("container")], [
    html.div([attribute.id("menu")], [
      view_menu_item("", "!", "menu"),
      view_menu_item("ping " <> ping_class, ping, ""),
    ]),
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
