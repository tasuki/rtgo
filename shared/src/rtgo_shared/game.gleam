import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import rtgo_shared/player

pub type Handicap {
  EvenGame
  // FixedPlacement(komi: Int, handicaps: Int)
  // FreePlacement(komi: Int, handicaps: Int)
}

pub type Players {
  TwoPlayers(black: String, white: String, handicap: Handicap)
  MultiPlayer(players: Dict(player.Color, String))
}

pub type TimeSettings {
  // DragDerby
  Cooldown(gain_move_seconds: Int)
  // Accumulation(gain_move_seconds: Int, max_moves: Int)
}

pub type GameType {
  TwoPlayerGame
  MultiplayerGame
}

pub type Settings {
  Settings(board_size: Int, game_type: GameType, time_settings: TimeSettings)
}

pub const default_settings = Settings(19, TwoPlayerGame, Cooldown(5))

pub fn colors(settings: Settings) -> List(player.Color) {
  case settings.game_type {
    TwoPlayerGame -> player.two_player_colors
    MultiplayerGame -> player.all_colors
  }
}

pub fn valid_settings(settings: Settings) -> Bool {
  let Cooldown(seconds) = settings.time_settings
  list.contains([9, 13, 19], settings.board_size)
  && seconds >= 1
  && seconds <= 60
}

pub fn game_type_label(game_type: GameType) -> String {
  case game_type {
    TwoPlayerGame -> "Two-player"
    MultiplayerGame -> "Multiplayer"
  }
}

pub fn settings_to_json(settings: Settings) -> json.Json {
  let Cooldown(seconds) = settings.time_settings
  let game_type = case settings.game_type {
    TwoPlayerGame -> "two_player"
    MultiplayerGame -> "multiplayer"
  }
  json.object([
    #("board_size", json.int(settings.board_size)),
    #("game_type", json.string(game_type)),
    #("cooldown_seconds", json.int(seconds)),
  ])
}

pub fn settings_decoder() -> decode.Decoder(Settings) {
  let decoder = {
    use board_size <- decode.field("board_size", decode.int)
    use game_type <- decode.field("game_type", decode.string)
    use seconds <- decode.field("cooldown_seconds", decode.int)
    case game_type {
      "two_player" ->
        decode.success(Settings(board_size, TwoPlayerGame, Cooldown(seconds)))
      "multiplayer" ->
        decode.success(Settings(board_size, MultiplayerGame, Cooldown(seconds)))
      _ ->
        decode.failure(default_settings, "two_player or multiplayer game type")
    }
  }
  decode.then(decoder, fn(settings) {
    case valid_settings(settings) {
      True -> decode.success(settings)
      False ->
        decode.failure(
          default_settings,
          "board size 9, 13 or 19 and cooldown 1–60 seconds",
        )
    }
  })
}

pub type GamePhase {
  Negotiating
  Started
  Finished
}

pub type Game {
  Game(
    id: String,
    host: String,
    board_size: Int,
    players: Players,
    time_settings: TimeSettings,
    phase: GamePhase,
  )
}
