import config
import gleam/dynamic/decode
import gleam/int
import gleam/javascript/promise
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import rsvp

// Main

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

// Model

pub type Model {
  Model(ping: Option(Duration), server_url: String)
}

fn init(_) {
  let assert Ok(server_url) = config.server_urls |> list.first
  #(Model(ping: None, server_url: server_url), ping_server(server_url))
}

fn decoder(start: Timestamp) {
  decode.success(Nil)
  |> decode.map(fn(_) { timestamp.difference(start, timestamp.system_time()) })
}

fn ping_server(server_url) -> Effect(Msg) {
  let start = timestamp.system_time()
  let url = server_url <> "/ping"
  let handler = rsvp.expect_json(decoder(start), ServerResponded)
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
    ServerResponded(duration_res) ->{
      #(
        Model(..model, ping: option.from_result(duration_res)),
        wait(1000, PingRequested),
      )
    }
  }
}

// View

fn duration_in_ms(d: Duration) -> Int {
  let #(seconds, nanoseconds) = duration.to_seconds_and_nanoseconds(d)
  seconds * 1000 + nanoseconds / 1_000_000
}

fn view(model: Model) -> Element(Msg) {
  case model.ping {
    Some(ping) ->
      html.h1([], [html.text(duration_in_ms(ping) |> int.to_string)])
    None -> html.h1([], [html.text("disconnected")])
  }
}
