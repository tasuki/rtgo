import gleam/list
import gleam/result
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element/html
import lustre/event
import player
import plinth/javascript/storage
import rsvp

// Model

pub type PlayerStatus {
  PickingName
  VerifyingName(String)
  NameAlreadyTaken(String)
  OtherError(String)
  LoggedIn(String)
}

fn storage() {
  let assert Ok(local_storage) = storage.local()
  local_storage
}

fn get_name() {
  storage.get_item(storage(), "name")
}

pub fn set_name(name: String) {
  storage.set_item(storage(), "name", name)
}

pub fn log_in(server_url: String, username: String, msg) -> Effect(msg) {
  let url = server_url <> "/log_in"
  let handler = rsvp.expect_json(player.log_in_response_decoder(), msg)
  rsvp.post(
    url,
    player.log_in_request_to_json(player.LogInRequest(username)),
    handler,
  )
}

pub fn default_login(server_url: String, msg) {
  case get_name() {
    Ok(name) -> #(VerifyingName(name), log_in(server_url, name, msg))
    Error(_) -> #(PickingName, effect.none())
  }
}

// View

pub fn view(player_status: PlayerStatus, submit_name_msg: fn(String) -> a) {
  let msg_handler = fn(form_data: List(#(String, String))) {
    let name = form_data |> list.key_find("username") |> result.unwrap("")
    submit_name_msg(name)
  }

  let login_form =
    html.form([event.on_submit(msg_handler)], [
      html.div([], [html.text("Choose your name...")]),
      html.input([attribute.name("username")]),
      html.button([attribute.type_("submit")], [html.text("Submit Post")]),
    ])

  let inside = case player_status {
    PickingName -> login_form
    VerifyingName(verifying_name) ->
      html.div([], [html.text("Trying to log you in as " <> verifying_name)])
    NameAlreadyTaken(taken_name) ->
      html.div([], [
        html.div([], [
          html.text(
            "Oh noes! "
            <> "Someone is currently logged in as "
            <> taken_name
            <> ". "
            <> "Try another name or wait until they go offline.",
          ),
        ]),
        html.br([]),
        login_form,
      ])
    OtherError(err) ->
      html.div([], [
        html.div([], [
          html.text("An error occurred: " <> err),
        ]),
        html.br([]),
        login_form,
      ])
    LoggedIn(name) -> html.div([], [html.text("Logged in as " <> name)])
  }

  html.div([attribute.id("help")], [inside])
}
