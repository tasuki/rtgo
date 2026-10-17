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

pub fn color_name(color: Color) -> String {
  case color {
    Black -> "black"
    White -> "white"
    Cyan -> "cyan"
    Green -> "green"
    Orange -> "orange"
    Pink -> "pink"
    Purple -> "purple"
    Blue -> "blue"
  }
}

pub fn color_from_name(name: String) -> Result(Color, Nil) {
  case name {
    "black" -> Ok(Black)
    "white" -> Ok(White)
    "cyan" -> Ok(Cyan)
    "green" -> Ok(Green)
    "orange" -> Ok(Orange)
    "pink" -> Ok(Pink)
    "purple" -> Ok(Purple)
    "blue" -> Ok(Blue)
    _ -> Error(Nil)
  }
}

pub fn color_to_json(color: Color) -> json.Json {
  json.string(color_name(color))
}

pub fn color_decoder() -> decode.Decoder(Color) {
  decode.then(decode.string, fn(name) {
    case color_from_name(name) {
      Ok(color) -> decode.success(color)
      Error(_) -> decode.failure(Black, "player color")
    }
  })
}

pub const all_colors = [Black, White, Cyan, Green, Orange, Pink, Purple, Blue]

pub const two_player_colors = [Black, White]

pub type Player {
  Player(username: String, color: Color)
}
