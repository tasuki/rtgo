import board
import config
import gleam/dynamic/decode
import gleam/int
import gleam/javascript/promise
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import go
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import rsvp

// Main

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "body", Nil)
  Nil
}

// Model

pub type Model {
  Model(ping: Option(Duration), server_url: String, game: go.Game)
}

fn init(_) {
  let assert Ok(server_url) = config.server_urls |> list.first
  #(
    Model(ping: None, server_url: server_url, game: go.new_game(13)),
    ping_server(server_url),
  )
}

fn ping_decoder(start: Timestamp) {
  decode.success(Nil)
  |> decode.map(fn(_) { timestamp.difference(start, timestamp.system_time()) })
}

fn ping_server(server_url) -> Effect(Msg) {
  let start = timestamp.system_time()
  let url = server_url <> "/ping"
  let handler = rsvp.expect_json(ping_decoder(start), ServerResponded)
  rsvp.get(url, handler)
}

// Update

pub type Msg {
  PingRequested
  ServerResponded(Result(Duration, rsvp.Error))
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
    PingRequested -> {
      #(model, ping_server(model.server_url))
    }
    ServerResponded(duration_res) -> {
      #(
        Model(..model, ping: option.from_result(duration_res)),
        wait(1000, PingRequested),
      )
    }
  }
}

// View

fn duration_in_s(d: Duration) -> #(String, String) {
  let #(seconds, nanoseconds) = duration.to_seconds_and_nanoseconds(d)
  let tenths = { nanoseconds + 50_000_000 } / 100_000_000
  let str = int.to_string(seconds) <> "." <> int.to_string(tenths)
  case seconds, tenths {
    0, 0 -> #("green", str)
    0, 1 -> #("yellow", str)
    _, _ -> #("orange", str)
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
    html.div([attribute.id("board-container")], [
      html.div([attribute.id("board")], [board.view(model.game)]),
    ]),
  ])
}
