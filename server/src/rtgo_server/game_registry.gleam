import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import rtgo_server/game
import rtgo_shared/pronounceable

type State {
  State(games: Dict(String, Subject(game.Message)))
}

pub type Message {
  CreateGame(reply: Subject(String))
  GetGame(id: String, reply: Subject(Result(Subject(game.Message), Nil)))
  DeleteGame(id: String)
}

fn generate_new_id(state: State) -> String {
  let id = pronounceable.generate(4)
  case dict.get(state.games, id) {
    Ok(_) -> generate_new_id(state)
    Error(_) -> id
  }
}

fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    CreateGame(reply) -> {
      let game_subject = game.start()
      let new_id = generate_new_id(state)
      let new_games = dict.insert(state.games, new_id, game_subject)
      process.send(reply, new_id)
      actor.continue(State(new_games))
    }
    GetGame(id, reply) -> {
      process.send(reply, dict.get(state.games, id))
      actor.continue(state)
    }
    DeleteGame(id) -> {
      let new_games = dict.delete(state.games, id)
      actor.continue(State(new_games))
    }
  }
}

pub fn start() -> Subject(Message) {
  let assert Ok(actor) =
    actor.new(State(games: dict.new()))
    |> actor.on_message(handle_message)
    |> actor.start
  actor.data
}

pub fn create_game(subject: Subject(Message)) {
  process.call(subject, 100, fn(client) { CreateGame(client) })
}

pub fn get_game(subject: Subject(Message), id: String) {
  process.call(subject, 100, fn(client) { GetGame(id, client) })
}

pub fn delete_game(subject: Subject(Message), id: String) {
  process.call(subject, 100, fn(_) { DeleteGame(id) })
}
