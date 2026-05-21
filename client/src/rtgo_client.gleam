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

// Main

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "body", Nil)
  Nil
}

// Model

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
    current_game: Option(lobby_api.GameDetails),
    loading_game: Bool,
  )
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
  let route: Route =
    modem.initial_uri()
    |> result.map(route_from_uri)
    |> result.unwrap(PlayerInfo)

  let assert Ok(server_url) = config.server_urls |> list.first
  let #(player_status, effect) =
    player_info.default_login(server_url, LoggedInResponse)

  #(
    Model(
      route: route,
      player: player_status,
      ping: None,
      server_url: server_url,
      game: go.new_game(13),
      lobby_games: [],
      loading_lobby: False,
      current_game: None,
      loading_game: False,
    ),
    effect.batch([
      effect,
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
  let url = server_url <> "/ping"
  let handler = rsvp.expect_json(ping_decoder(start), PingResponded)
  rsvp.get(url, handler)
}

fn load_lobby_games(server_url: String) -> Effect(Msg) {
  rsvp.send(
    lobby_api.games_request(server_url),
    rsvp.expect_json(lobby_api.list_games_response_decoder(), GamesLoaded),
  )
}

fn load_game(server_url: String, id: String) -> Effect(Msg) {
  rsvp.send(
    lobby_api.game_request(server_url, id),
    rsvp.expect_json(lobby_api.get_game_response_decoder(), GameLoaded),
  )
}

fn create_game(server_url: String, username: String) -> Effect(Msg) {
  rsvp.send(
    lobby_api.create_game_request(server_url, username),
    rsvp.expect_json(lobby_api.create_game_response_decoder(), GameCreated),
  )
}

fn join_game(server_url: String, id: String, username: String) -> Effect(Msg) {
  rsvp.send(
    lobby_api.join_game_request(server_url, id, username),
    rsvp.expect_json(lobby_api.join_game_response_decoder(), fn(result) {
      GameJoined(id, result)
    }),
  )
}

fn start_game(server_url: String, id: String, username: String) -> Effect(Msg) {
  rsvp.send(
    lobby_api.start_game_request(server_url, id, username),
    rsvp.expect_json(lobby_api.start_game_response_decoder(), fn(result) {
      GameStarted(id, result)
    }),
  )
}

// Update

pub type Msg {
  RouteChanged(Route)
  PingRequested
  PingResponded(Result(Duration, rsvp.Error))
  Register(String)
  LoggedInResponse(Result(auth.LogInResponse, rsvp.Error))
  GamesLoaded(Result(lobby_api.ListGamesResponse, rsvp.Error))
  GameLoaded(Result(lobby_api.GetGameResponse, rsvp.Error))
  CreateGamePressed
  GameCreated(Result(lobby_api.CreateGameResponse, rsvp.Error))
  JoinGamePressed(String)
  GameJoined(String, Result(lobby_api.JoinGameResponse, rsvp.Error))
  StartGamePressed(String)
  GameStarted(String, Result(lobby_api.StartGameResponse, rsvp.Error))
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

fn current_username(model: Model) -> Result(String, Nil) {
  player_info.desired_name(model.player)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    RouteChanged(route) -> {
      let #(new_model, eff) = case route {
        CreateJoinGame -> #(
          Model(
            ..model,
            route: route,
            loading_lobby: True,
            current_game: None,
            loading_game: False,
          ),
          load_lobby_games(model.server_url),
        )
        Play(id) -> #(
          Model(..model, route: route, current_game: None, loading_game: True),
          load_game(model.server_url, id),
        )
        PlayerInfo -> #(
          Model(..model, route: route, current_game: None, loading_game: False),
          effect.none(),
        )
      }
      #(new_model, eff)
    }
    PingRequested -> #(model, ping_server(model.server_url))
    PingResponded(duration_res) -> #(
      Model(..model, ping: option.from_result(duration_res)),
      wait(1000, PingRequested),
    )

    Register(name) -> #(
      model,
      player_info.register(model.server_url, name, LoggedInResponse),
    )

    LoggedInResponse(Ok(lir)) -> {
      case player_info.decode_login_jwt(lir.jwt) {
        Ok(jwt) -> {
          let _ = player_info.storage_set_login(lir.jwt)
          let #(name, _exp) = jwt
          #(
            Model(
              ..model,
              player: player_info.LoggedIn(name),
              loading_lobby: True,
            ),
            effect.batch([
              modem.push(route_to_str(CreateJoinGame), None, None),
              load_lobby_games(model.server_url),
            ]),
          )
        }
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
      let #(player_info, eff) = case e {
        rsvp.NetworkError -> #(
          player_info.OtherError(
            "Network error! Perhaps you're offline, your DNS is broken, "
            <> "or our server is down. Who knows!",
          ),
          effect.none(),
        )
        rsvp.HttpError(res) if res.status == 400 -> {
          case player_info.desired_name(model.player) {
            Ok(dn) -> #(
              player_info.OtherError(
                "Login failed, trying to re-register you...",
              ),
              player_info.register(model.server_url, dn, LoggedInResponse),
            )
            Error(_) -> #(
              player_info.OtherError("Login failed..."),
              effect.none(),
            )
          }
        }
        rsvp.HttpError(res) if res.status == 409 -> {
          #(
            case
              json.parse(res.body, auth.registration_failed_response_decoder())
            {
              Ok(rf) -> player_info.NameAlreadyTaken(rf.already_taken)
              Error(e) -> player_info.OtherError("Error: " <> string.inspect(e))
            },
            effect.none(),
          )
        }
        other_error -> #(
          player_info.OtherError("Other error: " <> string.inspect(other_error)),
          effect.none(),
        )
      }
      #(Model(..model, player: player_info), eff)
    }

    GamesLoaded(Ok(lobby_api.ListGamesResponse(games))) -> {
      #(Model(..model, lobby_games: games, loading_lobby: False), effect.none())
    }

    GamesLoaded(Error(_)) -> {
      #(Model(..model, lobby_games: [], loading_lobby: False), effect.none())
    }

    GameLoaded(Ok(lobby_api.GetGameResponse(game))) -> {
      #(
        Model(..model, current_game: Some(game), loading_game: False),
        effect.none(),
      )
    }

    GameLoaded(Error(_)) -> {
      #(Model(..model, current_game: None, loading_game: False), effect.none())
    }

    CreateGamePressed -> {
      case current_username(model) {
        Ok(username) -> #(
          Model(..model, loading_lobby: True),
          create_game(model.server_url, username),
        )
        Error(_) -> #(model, effect.none())
      }
    }

    GameCreated(Ok(lobby_api.CreateGameResponse(id))) -> {
      #(
        Model(..model, loading_lobby: False),
        modem.push(route_to_str(Play(id)), None, None),
      )
    }

    GameCreated(Error(_)) -> #(
      Model(..model, loading_lobby: False),
      effect.none(),
    )

    JoinGamePressed(id) -> {
      case current_username(model) {
        Ok(username) -> #(model, join_game(model.server_url, id, username))
        Error(_) -> #(model, effect.none())
      }
    }

    GameJoined(id, Ok(lobby_api.JoinGameResponse(joined))) -> {
      case joined {
        True -> #(model, modem.push(route_to_str(Play(id)), None, None))
        False -> #(model, load_lobby_games(model.server_url))
      }
    }

    GameJoined(_, Error(_)) -> #(model, load_lobby_games(model.server_url))

    StartGamePressed(id) -> {
      case current_username(model) {
        Ok(username) -> #(model, start_game(model.server_url, id, username))
        Error(_) -> #(model, effect.none())
      }
    }

    GameStarted(id, Ok(lobby_api.StartGameResponse(started))) -> {
      case started {
        True -> #(
          Model(..model, loading_game: True),
          load_game(model.server_url, id),
        )
        False -> #(model, effect.none())
      }
    }

    GameStarted(_, Error(_)) -> #(model, effect.none())

    OpenGame(game_id) -> #(
      model,
      modem.push(route_to_str(Play(game_id)), None, None),
    )

    BackToLobby -> #(
      model,
      modem.push(route_to_str(CreateJoinGame), None, None),
    )
  }
}

// View

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

fn view_game(game: lobby_api.GameMetadata) -> Element(Msg) {
  let lobby_api.GameMetadata(id:, phase:, player_count:) = game
  let #(phase_text, click_msg) = case phase {
    shared_game.Negotiating -> #("open", JoinGamePressed(id))
    shared_game.Started -> #("in progress", OpenGame(id))
    shared_game.Finished -> #("finished", OpenGame(id))
  }

  html.button([attribute.class("game-row"), event.on_click(click_msg)], [
    html.span([attribute.class("game-id")], [html.text(id)]),
    html.span([attribute.class("game-phase")], [html.text(phase_text)]),
    html.span([attribute.class("game-count")], [
      html.text(int.to_string(player_count) <> " players"),
    ]),
  ])
}

fn view_games(
  title: String,
  games: List(lobby_api.GameMetadata),
) -> Element(Msg) {
  html.div([attribute.class("lobby-section")], [
    html.h2([], [html.text(title)]),
    case games {
      [] -> html.p([], [html.text("none")])
      _ -> html.div([attribute.class("games-list")], list.map(games, view_game))
    },
  ])
}

fn view_lobby(model: Model) -> Element(Msg) {
  let open_games =
    list.filter(model.lobby_games, fn(game) {
      let lobby_api.GameMetadata(phase:, ..) = game
      phase == shared_game.Negotiating
    })
  let running_games =
    list.filter(model.lobby_games, fn(game) {
      let lobby_api.GameMetadata(phase:, ..) = game
      phase == shared_game.Started
    })

  html.div([attribute.id("page-container"), attribute.class("lobby-page")], [
    html.div([attribute.class("lobby-header")], [
      html.h1([], [html.text("Lobby")]),
      html.button(
        [
          attribute.disabled(model.loading_lobby),
          event.on_click(CreateGamePressed),
        ],
        [html.text("Create game")],
      ),
    ]),
    case model.loading_lobby && model.lobby_games == [] {
      True -> html.p([], [html.text("Loading...")])
      False ->
        html.div([], [
          view_games("Open for joining", open_games),
          view_games("In progress", running_games),
        ])
    },
  ])
}

fn view_game_room(model: Model, details: lobby_api.GameDetails) -> Element(Msg) {
  let lobby_api.GameDetails(id:, host:, players:, player_count:, ..) = details
  let is_host = case current_username(model) {
    Ok(username) -> username == host
    Error(_) -> False
  }
  let can_start = is_host && player_count >= 2

  html.div([attribute.id("page-container"), attribute.class("lobby-page")], [
    html.div([attribute.class("lobby-header")], [
      html.h1([], [html.text(id)]),
      html.button([event.on_click(BackToLobby)], [html.text("Back")]),
    ]),
    html.p([], [html.text("Host: " <> host)]),
    html.div([attribute.class("lobby-section")], [
      html.h2([], [html.text("Players")]),
      html.ul(
        [],
        list.map(players, fn(name) { html.li([], [html.text(name)]) }),
      ),
    ]),
    case is_host {
      True ->
        html.button(
          [attribute.disabled(!can_start), event.on_click(StartGamePressed(id))],
          [html.text("Start game")],
        )
      False -> html.p([], [html.text("Waiting for host to start the game.")])
    },
  ])
}

fn view(model: Model) -> Element(Msg) {
  let #(ping_class, ping) = view_ping(model.ping)
  html.div([attribute.id("container")], [
    html.div([attribute.id("menu")], [
      view_menu_item("", "!", "menu"),
      view_menu_item("ping " <> ping_class, ping, ""),
    ]),
    case model.route {
      PlayerInfo -> player_info.view(model.player, Register)
      CreateJoinGame -> view_lobby(model)
      Play(_) ->
        case model.loading_game {
          True ->
            html.div([attribute.id("page-container")], [html.text("Loading...")])
          False ->
            case model.current_game {
              Some(details) -> {
                let lobby_api.GameDetails(phase:, ..) = details
                case phase {
                  shared_game.Negotiating -> view_game_room(model, details)
                  _ ->
                    html.div([attribute.id("board-container")], [
                      html.div([attribute.id("board")], [board.view(model.game)]),
                    ])
                }
              }
              None ->
                html.div([attribute.id("page-container")], [
                  html.text("Game not found"),
                ])
            }
        }
    },
  ])
}
