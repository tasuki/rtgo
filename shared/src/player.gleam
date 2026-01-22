import gleam/dynamic/decode
import gleam/json

pub type Color {
  Black
  White
  Cyan
  Green
  Orange
  Pink
  Purple
  Blue
}

pub fn color_to_str(color: Color) {
  case color {
    Black -> "#333"
    White -> "#FFF"
    Cyan -> "#0FC"
    Green -> "#CF0"
    Orange -> "#F80"
    Pink -> "#F3C"
    Purple -> "#85F"
    Blue -> "#08F"
  }
}

pub type Player {
  Player(name: String, color: Color)
}

// Log in request

pub type LogInRequest {
  LogInRequest(name: String)
}

pub fn log_in_request_to_json(log_in_request: LogInRequest) -> json.Json {
  let LogInRequest(name:) = log_in_request
  json.object([
    #("name", json.string(name)),
  ])
}

pub fn log_in_request_decoder() -> decode.Decoder(LogInRequest) {
  use name <- decode.field("name", decode.string)
  decode.success(LogInRequest(name:))
}

// Log in response

pub type LogInResponse {
  LogInResponse(logged_in_as: String)
}

pub fn log_in_response_to_json(log_in_response: LogInResponse) -> json.Json {
  let LogInResponse(logged_in_as:) = log_in_response
  json.object([
    #("logged_in_as", json.string(logged_in_as)),
  ])
}

pub fn log_in_response_decoder() -> decode.Decoder(LogInResponse) {
  use logged_in_as <- decode.field("logged_in_as", decode.string)
  decode.success(LogInResponse(logged_in_as:))
}

// Log in failed response

pub type LogInFailedResponse {
  LogInFailedResponse(name_taken: String)
}

pub fn log_in_failed_response_to_json(log_in_failed_response: LogInFailedResponse) -> json.Json {
  let LogInFailedResponse(name_taken:) = log_in_failed_response
  json.object([
    #("name_taken", json.string(name_taken)),
  ])
}

pub fn log_in_failed_response_decoder() -> decode.Decoder(LogInFailedResponse) {
  use name_taken <- decode.field("name_taken", decode.string)
  decode.success(LogInFailedResponse(name_taken:))
}

