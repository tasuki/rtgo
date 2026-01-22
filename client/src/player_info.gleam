import gleam/dynamic/decode
import gleam/list
import gleam/result
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element/html
import lustre/event
import player
import plinth/javascript/storage
import rsvp
import ywt

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

fn storage_get_login() {
  storage.get_item(storage(), "login")
}

pub fn decode_login_jwt(jwt: String) {
  let decoder = {
    use sub <- decode.field("sub", decode.string)
    use exp <- decode.field("exp", decode.int)
    decode.success(#(sub, exp))
  }
  ywt.decode_unsafely_without_validation(jwt, decoder)
}

pub fn storage_set_login(jwt: String) {
  storage.set_item(storage(), "login", jwt)
}

pub fn log_in(server_url: String, username: String, msg) -> Effect(msg) {
  rsvp.post(
    server_url <> "/log_in",
    player.log_in_request_to_json(player.LogInRequest(username)),
    rsvp.expect_json(player.log_in_response_decoder(), msg),
  )
}

pub fn default_login(server_url: String, msg) {
  case storage_get_login() {
    Ok(jwt) ->
      case decode_login_jwt(jwt) {
        Ok(#(name, _exp)) -> {
          #(VerifyingName(name), log_in(server_url, jwt, msg))
        }
        Error(_) -> #(PickingName, effect.none())
      }
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
