import gleam/dict.{type Dict}
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
