import board
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
import go
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import modem
import player
import player_info
import rsvp

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

// Update

pub type Msg {
  RouteChanged(Route)
  PingRequested
  PingResponded(Result(Duration, rsvp.Error))
  Register(String)
  LoggedInResponse(Result(player.LogInResponse, rsvp.Error))
}

pub fn wait(milliseconds: Int, msg: msg) -> Effect(msg) {
  effect.from(fn(dispatch) {
    promise.wait(milliseconds)
    |> promise.tap(fn(_) { dispatch(msg) })
    Nil
  })
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    RouteChanged(route) -> #(Model(..model, route: route), effect.none())
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
            Model(..model, player: player_info.LoggedIn(name)),
            modem.push(route_to_str(CreateJoinGame), None, None),
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
              json.parse(
                res.body,
                player.registration_failed_response_decoder(),
              )
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

fn view(model: Model) -> Element(Msg) {
  let #(ping_class, ping) = view_ping(model.ping)
  html.div([attribute.id("container")], [
    html.div([attribute.id("menu")], [
      view_menu_item("", "!", "menu"),
      view_menu_item("ping " <> ping_class, ping, ""),
    ]),
    case model.route {
      PlayerInfo -> player_info.view(model.player, Register)
      CreateJoinGame ->
        html.div([attribute.id("page-container")], [
          html.text("create join game"),
        ])
      Play(_) ->
        html.div([attribute.id("board-container")], [
          html.div([attribute.id("board")], [board.view(model.game)]),
        ])
    },
  ])
}
