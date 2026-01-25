import gleam/dict.{type Dict}
import rtgo_shared/player

pub type GameMode {
  AlmostNormalGo
  SimulSlaughter
  // DragDerby // bad idea
}

pub type Handicap {
  EvenGame
  // FixedPlacement(komi: Int, handicaps: Int)
  // FreePlacement(komi: Int, handicaps: Int)
}

pub type Draft {
  AlmostNormalConfig(black: String, white: String, handicap: Handicap)
  SimulSlaughterConfig(players: Dict(player.Color, String))
}

pub type GamePhase {
  Lobby(players: List(String))
  Negotiating(draft: Draft)
  Started(draft: Draft, start_time: Int)
  Finished
}

pub type Game {
  Game(
    id: String,
    host: String,
    mode: GameMode,
    board_size: Int,
    cooldown_seconds: Int,
    phase: GamePhase,
  )
}
