import gleam/dict.{type Dict}
import rtgo_shared/player

pub type GameMode {
  // AlmostNormalGo
  SimulSlaughter
  // DragDerby // bad idea
}

pub type InitialSettings {
  InitialSettings(mode: GameMode, board_size: Int, cooldown_seconds: Int)
}

pub type Handicap {
  EvenGame
  // FixedPlacement(komi: Int, handicaps: Int)
  // FreePlacement(komi: Int, handicaps: Int)
}

pub type NegotiatedSettings {
  // AlmostNormalSettings(
  //   board_size: Int,
  //   cooldown_seconds: Int,
  //   black: String,
  //   white: String,
  //   handicap: Handicap,
  // )
  SimulSettings(
    board_size: Int,
    cooldown_seconds: Int,
    players: Dict(player.Color, String),
  )
}

pub type GamePhase {
  Lobby(InitialSettings)
  Negotiating(initial: InitialSettings, negotiated: NegotiatedSettings)
  Started(initial: InitialSettings, negotiated: NegotiatedSettings, start_time: Int)
  Finished()
}
