import gleam/list
import gleam/result
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element/html
import lustre/event
import plinth/javascript/storage
import rsvp
import rtgo_shared/auth
import rtgo_shared/auth_api
import ywt

// Model

pub type PlayerStatus {
  PickingName
  VerifyingName(String)
  NameAlreadyTaken(String)
  OtherError(String)
  LoggedIn(name: String, jwt: String)
}

pub fn desired_name(ps: PlayerStatus) -> Result(String, Nil) {
  case ps {
    NameAlreadyTaken(n) -> Ok(n)
    VerifyingName(n) -> Ok(n)
    LoggedIn(n, _) -> Ok(n)
    _ -> Error(Nil)
  }
}

fn storage() {
  let assert Ok(local_storage) = storage.local()
  local_storage
}

pub fn save_login(jwt: String) -> Effect(msg) {
  effect.from(fn(_) {
    let _ = storage.set_item(storage(), "login", jwt)
    Nil
  })
}

fn storage_get_login() {
  storage.get_item(storage(), "login")
}

pub fn decode_login_jwt(jwt: String) {
  ywt.decode_unsafely_without_validation(jwt, auth.jwt_decoder())
}

pub fn register(server_url: String, username: String, msg) -> Effect(msg) {
  rsvp.send(
    auth_api.register_request(server_url, username),
    rsvp.expect_json(auth.log_in_response_decoder(), msg),
  )
}

pub fn log_in(server_url: String, jwt: String, msg) -> Effect(msg) {
  rsvp.send(
    auth_api.log_in_request(server_url, jwt),
    rsvp.expect_json(auth.log_in_response_decoder(), msg),
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

  let registration_form =
    html.form([event.on_submit(msg_handler)], [
      html.label([attribute.for("username")], [html.text("Choose your name...")]),
      html.input([
        attribute.id("username"),
        attribute.name("username"),
        attribute.required(True),
        attribute.autocomplete("username"),
      ]),
      html.button([attribute.type_("submit")], [html.text("Continue")]),
    ])

  let inside = case player_status {
    PickingName -> registration_form
    VerifyingName(verifying_name) ->
      html.div([], [html.text("Trying to log you in as " <> verifying_name)])
    NameAlreadyTaken(taken_name) ->
      html.div([], [
        html.div([], [
          html.text(
            "Oh noes! "
            <> "Someone is currently registered in as "
            <> taken_name
            <> ". "
            <> "Try another name or wait until they go away.",
          ),
        ]),
        html.br([]),
        registration_form,
      ])
    OtherError(err) ->
      html.div([], [
        html.div([], [
          html.text("An error occurred: " <> err),
        ]),
        html.br([]),
        registration_form,
      ])
    LoggedIn(name, _) -> html.div([], [html.text("Logged in as " <> name)])
  }

  html.div([attribute.id("page-container")], [inside])
}
