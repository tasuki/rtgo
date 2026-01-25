import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import rtgo_shared/go
import rtgo_shared/player

type State {
  State(
    players: Dict(String, player.Player),
    game: Dict(String, Subject(Message)),
  )
}

pub type Message {
  Join(name: String)
  Start
  Play(player: String, move: go.Point)
  GetGame(id: Int)
}

pub fn start() -> Subject(Message) {
  todo
}
