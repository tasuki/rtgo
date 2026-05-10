import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import rtgo_shared/go
import rtgo_shared/player

type State {
  State(players: Dict(String, player.Player), board: go.Game)
}

pub type Snapshot {
  Snapshot(players: Dict(String, player.Player), board: go.Game)
}

pub type Error {
  UnknownPlayer
  InvalidMove(go.MoveError)
}

pub type Message {
  Play(player: String, move: go.Point, reply: Subject(Result(Nil, Error)))
  GetGame(reply: Subject(Snapshot))
}

fn snapshot(state: State) -> Snapshot {
  Snapshot(state.players, state.board)
}

fn handle_play(
  state: State,
  player_name: String,
  move: go.Point,
  reply: Subject(Result(Nil, Error)),
) -> actor.Next(State, Message) {
  case dict.get(state.players, player_name) {
    Ok(current_player) -> {
      case go.play(state.board, current_player, move) {
        Ok(board) -> {
          process.send(reply, Ok(Nil))
          actor.continue(State(..state, board: board))
        }
        Error(error) -> {
          process.send(reply, Error(InvalidMove(error)))
          actor.continue(state)
        }
      }
    }
    Error(_) -> {
      process.send(reply, Error(UnknownPlayer))
      actor.continue(state)
    }
  }
}

fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    Play(player, move, reply) -> handle_play(state, player, move, reply)
    GetGame(reply) -> {
      process.send(reply, snapshot(state))
      actor.continue(state)
    }
  }
}

pub fn start(players: Dict(String, player.Player)) -> Subject(Message) {
  let assert Ok(actor) =
    actor.new(State(players: players, board: go.new_game(19)))
    |> actor.on_message(handle_message)
    |> actor.start
  actor.data
}

pub fn play(
  subject: Subject(Message),
  player_name: String,
  move: go.Point,
) -> Result(Nil, Error) {
  process.call(subject, 100, fn(reply) { Play(player_name, move, reply) })
}

pub fn get_game(subject: Subject(Message)) -> Snapshot {
  process.call(subject, 100, fn(reply) { GetGame(reply) })
}
