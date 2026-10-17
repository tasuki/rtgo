import gleam/dynamic/decode
import gleam/json
import rtgo_shared/player

pub type RegistrationRequest {
  RegistrationRequest(username: String, preferred_color: player.Color)
}

pub fn registration_request_to_json(
  registration_request: RegistrationRequest,
) -> json.Json {
  let RegistrationRequest(username:, preferred_color:) = registration_request
  json.object([
    #("username", json.string(username)),
    #("preferred_color", player.color_to_json(preferred_color)),
  ])
}

pub fn registration_request_decoder() -> decode.Decoder(RegistrationRequest) {
  use username <- decode.field("username", decode.string)
  use preferred_color <- decode.optional_field(
    "preferred_color",
    player.Black,
    player.color_decoder(),
  )
  decode.success(RegistrationRequest(username:, preferred_color:))
}

pub type RegistrationFailedResponse {
  RegistrationFailedResponse(already_taken: String)
}

pub fn registration_failed_response_to_json(
  registration_failed_response: RegistrationFailedResponse,
) -> json.Json {
  let RegistrationFailedResponse(already_taken:) = registration_failed_response
  json.object([
    #("already_taken", json.string(already_taken)),
  ])
}

pub fn registration_failed_response_decoder() -> decode.Decoder(
  RegistrationFailedResponse,
) {
  use already_taken <- decode.field("already_taken", decode.string)
  decode.success(RegistrationFailedResponse(already_taken:))
}

pub type LogInRequest {
  LogInRequest(jwt: String)
}

pub fn log_in_request_to_json(log_in_request: LogInRequest) -> json.Json {
  let LogInRequest(jwt:) = log_in_request
  json.object([
    #("jwt", json.string(jwt)),
  ])
}

pub fn log_in_request_decoder() -> decode.Decoder(LogInRequest) {
  use jwt <- decode.field("jwt", decode.string)
  decode.success(LogInRequest(jwt:))
}

pub type LogInResponse {
  LogInResponse(jwt: String)
}

pub fn log_in_response_to_json(log_in_response: LogInResponse) -> json.Json {
  let LogInResponse(jwt:) = log_in_response
  json.object([
    #("jwt", json.string(jwt)),
  ])
}

pub fn log_in_response_decoder() -> decode.Decoder(LogInResponse) {
  use jwt <- decode.field("jwt", decode.string)
  decode.success(LogInResponse(jwt:))
}

pub fn jwt_decoder() {
  use sub <- decode.field("sub", decode.string)
  use exp <- decode.field("exp", decode.int)
  decode.success(#(sub, exp))
}

pub type LogInFailedResponse {
  LogInFailedResponse(msg: String)
}

pub fn log_in_failed_response_to_json(
  log_in_failed_response: LogInFailedResponse,
) -> json.Json {
  let LogInFailedResponse(msg:) = log_in_failed_response
  json.object([
    #("msg", json.string(msg)),
  ])
}

pub fn log_in_failed_response_decoder() -> decode.Decoder(LogInFailedResponse) {
  use msg <- decode.field("msg", decode.string)
  decode.success(LogInFailedResponse(msg:))
}
