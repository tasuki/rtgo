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
  Cooldown(gain_move_seconds: Int)
  CushyCooldown(gain_move_seconds: Int)
  StoneSavings(gain_move_seconds: Int, max_moves: Int, minimum_gap_ms: Int)
  DragDerby
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

pub const max_player_cooldown = 3600

pub fn base_cooldown(settings: Settings) -> Int {
  interval_seconds(settings.time_settings)
}

fn interval_seconds(timing: TimeSettings) -> Int {
  case timing {
    Cooldown(seconds) | CushyCooldown(seconds) | StoneSavings(seconds, _, _) ->
      seconds
    DragDerby -> 0
  }
}

pub fn default_cooldowns(
  players: List(String),
  settings: Settings,
) -> Dict(String, Int) {
  dict.from_list(
    list.map(players, fn(name) { #(name, base_cooldown(settings)) }),
  )
}

pub fn valid_player_cooldown(settings: Settings, seconds: Int) -> Bool {
  case settings.time_settings {
    DragDerby -> seconds == 0
    _ -> seconds >= base_cooldown(settings) && seconds <= max_player_cooldown
  }
}

pub fn valid_settings(settings: Settings) -> Bool {
  list.contains([9, 13, 19], settings.board_size)
  && valid_timing(settings.time_settings)
}

pub fn game_type_label(game_type: GameType) -> String {
  case game_type {
    TwoPlayerGame -> "Two-player"
    MultiplayerGame -> "Multiplayer"
  }
}

pub fn timing_id(timing: TimeSettings) -> String {
  case timing {
    Cooldown(_) -> "crazy_cooldown"
    CushyCooldown(_) -> "cushy_cooldown"
    StoneSavings(_, _, _) -> "stone_savings"
    DragDerby -> "drag_derby"
  }
}

pub fn timing_label(timing: TimeSettings) -> String {
  case timing {
    Cooldown(_) -> "Crazy Cooldown"
    CushyCooldown(_) -> "Cushy Cooldown"
    StoneSavings(_, _, _) -> "Stone Savings"
    DragDerby -> "Drag Derby"
  }
}

pub fn valid_timing(timing: TimeSettings) -> Bool {
  case timing {
    DragDerby -> True
    Cooldown(seconds) | CushyCooldown(seconds) -> seconds >= 1 && seconds <= 60
    StoneSavings(seconds, cap, gap) ->
      seconds >= 1
      && seconds <= 60
      && cap >= 1
      && cap <= 20
      && gap >= 0
      && gap <= seconds * 1000
  }
}

pub fn timing_to_json(timing: TimeSettings) -> json.Json {
  let seconds = interval_seconds(timing)
  let extras = case timing {
    StoneSavings(_, cap, gap) -> [
      #("max_moves", json.int(cap)),
      #("minimum_gap_ms", json.int(gap)),
    ]
    _ -> []
  }
  json.object([
    #("mode", json.string(timing_id(timing))),
    #("gain_move_seconds", json.int(seconds)),
    ..extras
  ])
}

pub fn timing_decoder() -> decode.Decoder(TimeSettings) {
  let decoder = {
    use mode <- decode.field("mode", decode.string)
    use seconds <- decode.optional_field("gain_move_seconds", 0, decode.int)
    case mode {
      "crazy_cooldown" -> decode.success(Cooldown(seconds))
      "cushy_cooldown" -> decode.success(CushyCooldown(seconds))
      "stone_savings" -> {
        use cap <- decode.field("max_moves", decode.int)
        use gap <- decode.field("minimum_gap_ms", decode.int)
        decode.success(StoneSavings(seconds, cap, gap))
      }
      "drag_derby" ->
        case seconds == 0 {
          True -> decode.success(DragDerby)
          False -> decode.failure(DragDerby, "Drag Derby has no cooldown")
        }
      _ -> decode.failure(Cooldown(5), "supported timing mode")
    }
  }
  decode.then(decoder, fn(timing) {
    case valid_timing(timing) {
      True -> decode.success(timing)
      False -> decode.failure(Cooldown(5), "valid timing parameters")
    }
  })
}

pub fn settings_to_json(settings: Settings) -> json.Json {
  let game_type = case settings.game_type {
    TwoPlayerGame -> "two_player"
    MultiplayerGame -> "multiplayer"
  }
  json.object([
    #("board_size", json.int(settings.board_size)),
    #("game_type", json.string(game_type)),
    #("cooldown_seconds", json.int(base_cooldown(settings))),
    #("timing", timing_to_json(settings.time_settings)),
  ])
}

pub fn settings_decoder() -> decode.Decoder(Settings) {
  let decoder = {
    use board_size <- decode.field("board_size", decode.int)
    use game_type <- decode.field("game_type", decode.string)
    use seconds <- decode.optional_field("cooldown_seconds", 0, decode.int)
    use timing <- decode.optional_field(
      "timing",
      Cooldown(seconds),
      timing_decoder(),
    )
    case game_type {
      "two_player" ->
        decode.success(Settings(board_size, TwoPlayerGame, timing))
      "multiplayer" ->
        decode.success(Settings(board_size, MultiplayerGame, timing))
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
          "board size 9, 13 or 19 and valid timing parameters",
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
