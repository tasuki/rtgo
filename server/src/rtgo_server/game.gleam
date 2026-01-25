import rtgo_shared/go

pub type Message {
  Join(name: String)
  Start
  Play(player: String, move: go.Point)
  GetGame(id: Int)
}
