import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
import rtgo_server/game
import rtgo_shared/game as shared_game
import rtgo_shared/player
import rtgo_shared/pronounceable

type State {
  State(games: Dict(String, Entry))
}

pub type Entry {
  Open(lobby: Lobby)
  Running(subject: Subject(game.Message))
}

pub type Lobby {
  Lobby(players: Dict(String, player.Player))
}

pub type Metadata {
  Metadata(phase: shared_game.GamePhase, player_count: Int)
}

pub type Error {
  GameNotFound
}

pub type Message {
  CreateGame(reply: Subject(String))
  ListGames(reply: Subject(Dict(String, Metadata)))
  GetGame(id: String, reply: Subject(Result(Entry, Error)))
  JoinGame(id: String, name: String, reply: Subject(Result(Bool, Error)))
  StartGame(id: String, reply: Subject(Result(Bool, Error)))
  DeleteGame(id: String)
}

fn generate_new_id(state: State) -> String {
  let id = pronounceable.generate(4)
  case dict.get(state.games, id) {
    Ok(_) -> generate_new_id(state)
    Error(_) -> id
  }
}

fn next_color(players: Dict(String, player.Player)) -> Result(player.Color, Nil) {
  let used_colors =
    players
    |> dict.values
    |> list.map(fn(p) { p.color })

  let available_colors =
    list.filter(player.all_colors, fn(color) {
      !list.contains(used_colors, color)
    })

  case list.length(available_colors) {
    0 -> Error(Nil)
    length -> {
      let index = int.random(length)
      available_colors |> list.drop(index) |> list.first
    }
  }
}

fn metadata(entry: Entry) -> Metadata {
  case entry {
    Open(Lobby(players)) -> {
      Metadata(phase: shared_game.Negotiating, player_count: dict.size(players))
    }
    Running(subject) -> {
      let game.Snapshot(players:, ..) = game.get_game(subject)
      Metadata(phase: shared_game.Started, player_count: dict.size(players))
    }
  }
}

fn list_metadata(games: Dict(String, Entry)) -> Dict(String, Metadata) {
  dict.fold(games, dict.new(), fn(acc, id, entry) {
    dict.insert(acc, id, metadata(entry))
  })
}

fn handle_create_game(
  state: State,
  reply: Subject(String),
) -> actor.Next(State, Message) {
  let new_id = generate_new_id(state)
  let new_games = dict.insert(state.games, new_id, Open(Lobby(dict.new())))
  process.send(reply, new_id)
  actor.continue(State(new_games))
}

fn handle_join_game(
  state: State,
  id: String,
  name: String,
  reply: Subject(Result(Bool, Error)),
) -> actor.Next(State, Message) {
  case dict.get(state.games, id) {
    Ok(Open(Lobby(players))) -> {
      case dict.has_key(players, name) {
        True -> {
          process.send(reply, Ok(False))
          actor.continue(state)
        }
        False -> {
          case next_color(players) {
            Ok(color) -> {
              let new_player = player.Player(name, color)
              let new_players = dict.insert(players, name, new_player)
              let new_games =
                dict.insert(state.games, id, Open(Lobby(new_players)))
              process.send(reply, Ok(True))
              actor.continue(State(new_games))
            }
            Error(_) -> {
              process.send(reply, Ok(False))
              actor.continue(state)
            }
          }
        }
      }
    }
    Ok(Running(_)) -> {
      process.send(reply, Ok(False))
      actor.continue(state)
    }
    Error(_) -> {
      process.send(reply, Error(GameNotFound))
      actor.continue(state)
    }
  }
}

fn handle_start_game(
  state: State,
  id: String,
  reply: Subject(Result(Bool, Error)),
) -> actor.Next(State, Message) {
  case dict.get(state.games, id) {
    Ok(Open(Lobby(players))) -> {
      case dict.size(players) >= 2 {
        True -> {
          let subject = game.start(players)
          let new_games = dict.insert(state.games, id, Running(subject))
          process.send(reply, Ok(True))
          actor.continue(State(new_games))
        }
        False -> {
          process.send(reply, Ok(False))
          actor.continue(state)
        }
      }
    }
    Ok(Running(_)) -> {
      process.send(reply, Ok(False))
      actor.continue(state)
    }
    Error(_) -> {
      process.send(reply, Error(GameNotFound))
      actor.continue(state)
    }
  }
}

fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    CreateGame(reply) -> handle_create_game(state, reply)
    GetGame(id, reply) -> {
      process.send(
        reply,
        dict.get(state.games, id) |> result.replace_error(GameNotFound),
      )
      actor.continue(state)
    }
    ListGames(reply) -> {
      process.send(reply, list_metadata(state.games))
      actor.continue(state)
    }
    JoinGame(id, name, reply) -> handle_join_game(state, id, name, reply)
    StartGame(id, reply) -> handle_start_game(state, id, reply)
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

pub fn create_game(subject: Subject(Message)) -> String {
  process.call(subject, 100, fn(client) { CreateGame(client) })
}

pub fn get_game(subject: Subject(Message), id: String) -> Result(Entry, Error) {
  process.call(subject, 100, fn(client) { GetGame(id, client) })
}

pub fn list_games(subject: Subject(Message)) -> Dict(String, Metadata) {
  process.call(subject, 100, fn(client) { ListGames(client) })
}

pub fn join_game(
  subject: Subject(Message),
  id: String,
  name: String,
) -> Result(Bool, Error) {
  process.call(subject, 100, fn(client) { JoinGame(id, name, client) })
}

pub fn start_game(subject: Subject(Message), id: String) -> Result(Bool, Error) {
  process.call(subject, 100, fn(client) { StartGame(id, client) })
}

pub fn delete_game(subject: Subject(Message), id: String) {
  process.send(subject, DeleteGame(id))
}
