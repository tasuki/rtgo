import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/time/timestamp
import rtgo_server/bot
import rtgo_server/game
import rtgo_server/log
import rtgo_server/recorder
import rtgo_shared/bot as shared_bot
import rtgo_shared/game as shared_game
import rtgo_shared/player
import rtgo_shared/pronounceable

type State {
  State(games: Dict(String, Entry))
}

pub type Entry {
  Open(lobby: Lobby)
  Running(
    host: String,
    settings: shared_game.Settings,
    subject: Subject(game.Message),
  )
}

pub type Lobby {
  Lobby(
    host: String,
    players: Dict(String, player.Player),
    settings: shared_game.Settings,
    cooldowns: Dict(String, Int),
    kicked: Set(String),
  )
}

pub type Metadata {
  Metadata(
    phase: shared_game.GamePhase,
    player_count: Int,
    settings: shared_game.Settings,
    started_at: Option(timestamp.Timestamp),
  )
}

pub type Error {
  GameNotFound
  NotHost
  HostMustCancel
  AlreadyStarted
  InvalidSettings
  PlayerNotFound
  CannotKickHost
  InvalidPlayerCooldown
  Kicked
  ColorTaken
  InvalidColor
  RoomFull
}

pub type Message {
  CreateGame(
    host: String,
    settings: shared_game.Settings,
    preferred_color: player.Color,
    reply: Subject(Result(String, Error)),
  )
  AddBot(id: String, host: String, reply: Subject(Result(Nil, Error)))
  ListGames(reply: Subject(Dict(String, Entry)))
  GetGame(id: String, reply: Subject(Result(Entry, Error)))
  JoinGame(
    id: String,
    name: String,
    preferred_color: player.Color,
    reply: Subject(Result(Bool, Error)),
  )
  SetColor(
    id: String,
    name: String,
    color: player.Color,
    reply: Subject(Result(Nil, Error)),
  )
  StartGame(id: String, name: String, reply: Subject(Result(Bool, Error)))
  LeaveGame(id: String, name: String, reply: Subject(Result(Nil, Error)))
  CancelGame(id: String, name: String, reply: Subject(Result(Nil, Error)))
  KickPlayer(
    id: String,
    host: String,
    player: String,
    reply: Subject(Result(Nil, Error)),
  )
  SetPlayerCooldown(
    id: String,
    host: String,
    player: String,
    seconds: Int,
    reply: Subject(Result(Nil, Error)),
  )
}

fn generate_new_id(state: State) -> String {
  let id = pronounceable.generate(4)
  case dict.has_key(state.games, id) || recorder.exists(id) {
    True -> generate_new_id(state)
    False -> id
  }
}

fn next_color(
  players: Dict(String, player.Player),
  settings: shared_game.Settings,
  preferred: player.Color,
) -> Result(player.Color, Nil) {
  let used_colors =
    players
    |> dict.values
    |> list.map(fn(p) { p.color })

  let available_colors =
    list.filter(shared_game.colors(settings), fn(color) {
      !list.contains(used_colors, color)
    })

  case list.contains(available_colors, preferred) {
    True -> Ok(preferred)
    False -> random_color(available_colors)
  }
}

fn random_color(
  available_colors: List(player.Color),
) -> Result(player.Color, Nil) {
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
    Open(Lobby(players:, settings:, ..)) -> {
      Metadata(
        phase: shared_game.Negotiating,
        player_count: dict.size(players),
        settings: settings,
        started_at: None,
      )
    }
    Running(subject:, settings:, ..) -> {
      let game.Metadata(phase:, player_count:, started_at:) =
        game.get_metadata(subject)
      Metadata(
        phase: phase,
        player_count: player_count,
        settings: settings,
        started_at: Some(started_at),
      )
    }
  }
}

fn list_metadata(games: Dict(String, Entry)) -> Dict(String, Metadata) {
  dict.fold(games, dict.new(), fn(acc, id, entry) {
    dict.insert(acc, id, metadata(entry))
  })
}

fn add_player(
  players: Dict(String, player.Player),
  name: String,
  settings: shared_game.Settings,
  preferred: player.Color,
) -> Result(Dict(String, player.Player), Nil) {
  case dict.has_key(players, name) {
    True -> Error(Nil)
    False -> {
      case next_color(players, settings, preferred) {
        Ok(color) -> Ok(dict.insert(players, name, player.Player(name, color)))
        Error(_) -> Error(Nil)
      }
    }
  }
}

fn handle_create_game(
  state: State,
  host: String,
  settings: shared_game.Settings,
  preferred: player.Color,
  reply: Subject(Result(String, Error)),
) -> actor.Next(State, Message) {
  case shared_game.valid_settings(settings) {
    False -> {
      process.send(reply, Error(InvalidSettings))
      actor.continue(state)
    }
    True -> {
      let new_id = generate_new_id(state)
      let assert Ok(players) = add_player(dict.new(), host, settings, preferred)
      let new_games =
        dict.insert(
          state.games,
          new_id,
          Open(Lobby(
            host,
            players,
            settings,
            shared_game.default_cooldowns([host], settings),
            set.new(),
          )),
        )
      log.info("Created new game: " <> new_id)
      process.send(reply, Ok(new_id))
      actor.continue(State(new_games))
    }
  }
}

fn handle_join_game(
  state: State,
  id: String,
  name: String,
  preferred: player.Color,
  reply: Subject(Result(Bool, Error)),
) -> actor.Next(State, Message) {
  case dict.get(state.games, id) {
    Ok(Open(lobby)) -> {
      let Lobby(players:, settings:, ..) = lobby
      case set.contains(lobby.kicked, name), dict.has_key(players, name) {
        True, _ -> {
          process.send(reply, Error(Kicked))
          actor.continue(state)
        }
        _, True -> {
          process.send(reply, Ok(True))
          actor.continue(state)
        }
        _, False -> {
          case add_player(players, name, settings, preferred) {
            Ok(new_players) -> {
              let new_games =
                dict.insert(
                  state.games,
                  id,
                  Open(
                    Lobby(
                      ..lobby,
                      players: new_players,
                      cooldowns: dict.insert(
                        lobby.cooldowns,
                        name,
                        dict.get(lobby.cooldowns, name)
                          |> result.unwrap(shared_game.base_cooldown(settings)),
                      ),
                    ),
                  ),
                )
              log.info("Player " <> name <> " joined game " <> id)
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
    Ok(Running(..)) -> {
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
  name: String,
  reply: Subject(Result(Bool, Error)),
) -> actor.Next(State, Message) {
  case dict.get(state.games, id) {
    Ok(Open(lobby)) -> {
      let Lobby(host:, players:, settings:, ..) = lobby
      case name != host {
        True -> {
          process.send(reply, Error(NotHost))
          actor.continue(state)
        }
        False -> {
          case dict.size(players) >= 2 {
            True -> {
              let subject =
                game.start_recorded(
                  id,
                  players,
                  settings,
                  player_cooldowns(lobby),
                )
              players
              |> dict.keys
              |> list.filter(shared_bot.is_bot)
              |> list.each(fn(name) { bot.start(subject, name) })
              let new_games =
                dict.insert(
                  state.games,
                  id,
                  Running(host: host, settings: settings, subject: subject),
                )
              log.info("Started game: " <> id)
              process.send(reply, Ok(True))
              actor.continue(State(new_games))
            }
            False -> {
              process.send(reply, Ok(False))
              actor.continue(state)
            }
          }
        }
      }
    }
    Ok(Running(..)) -> {
      process.send(reply, Ok(False))
      actor.continue(state)
    }
    Error(_) -> {
      process.send(reply, Error(GameNotFound))
      actor.continue(state)
    }
  }
}

fn leave(state: State, id: String, name: String) -> Result(State, Error) {
  use entry <- result.try(
    dict.get(state.games, id) |> result.replace_error(GameNotFound),
  )
  case entry {
    Running(..) -> Error(AlreadyStarted)
    Open(lobby) if lobby.host == name -> Error(HostMustCancel)
    Open(lobby) -> {
      let lobby = Lobby(..lobby, players: dict.delete(lobby.players, name))
      Ok(State(dict.insert(state.games, id, Open(lobby))))
    }
  }
}

fn cancel(state: State, id: String, name: String) -> Result(State, Error) {
  use entry <- result.try(
    dict.get(state.games, id) |> result.replace_error(GameNotFound),
  )
  case entry {
    Open(lobby) if lobby.host != name -> Error(NotHost)
    Running(host:, ..) if host != name -> Error(NotHost)
    Running(..) -> Error(AlreadyStarted)
    Open(_) -> Ok(State(dict.delete(state.games, id)))
  }
}

/// Only active players are exposed or passed to the running game. Remember
/// departed players' settings so leaving/rejoining cannot shed a handicap.
pub fn player_cooldowns(lobby: Lobby) -> Dict(String, Int) {
  dict.filter(lobby.cooldowns, fn(name, _) { dict.has_key(lobby.players, name) })
}

fn hosted_lobby(state: State, id: String, name: String) -> Result(Lobby, Error) {
  use entry <- result.try(
    dict.get(state.games, id) |> result.replace_error(GameNotFound),
  )
  case entry {
    Open(lobby) if lobby.host == name -> Ok(lobby)
    Open(_) -> Error(NotHost)
    Running(host:, ..) if host != name -> Error(NotHost)
    Running(..) -> Error(AlreadyStarted)
  }
}

fn bot_name(room: Lobby) -> String {
  let name = shared_bot.name_prefix <> pronounceable.generate(4)
  case dict.has_key(room.players, name) || set.contains(room.kicked, name) {
    True -> bot_name(room)
    False -> name
  }
}

fn add_bot_to_room(
  state: State,
  id: String,
  host: String,
) -> Result(State, Error) {
  use room <- result.try(hosted_lobby(state, id, host))
  let name = bot_name(room)
  use players <- result.try(
    add_player(room.players, name, room.settings, player.White)
    |> result.replace_error(RoomFull),
  )
  let room =
    Lobby(
      ..room,
      players: players,
      cooldowns: dict.insert(
        room.cooldowns,
        name,
        shared_game.base_cooldown(room.settings),
      ),
    )
  Ok(State(dict.insert(state.games, id, Open(room))))
}

fn kick(
  state: State,
  id: String,
  host: String,
  target: String,
) -> Result(State, Error) {
  use lobby <- result.try(hosted_lobby(state, id, host))
  case target == lobby.host {
    True -> Error(CannotKickHost)
    False -> {
      use _ <- result.try(
        dict.get(lobby.players, target) |> result.replace_error(PlayerNotFound),
      )
      let lobby =
        Lobby(
          ..lobby,
          players: dict.delete(lobby.players, target),
          cooldowns: dict.delete(lobby.cooldowns, target),
          kicked: set.insert(lobby.kicked, target),
        )
      Ok(State(dict.insert(state.games, id, Open(lobby))))
    }
  }
}

fn set_cooldown(
  state: State,
  id: String,
  host: String,
  target: String,
  seconds: Int,
) -> Result(State, Error) {
  use lobby <- result.try(hosted_lobby(state, id, host))
  use _ <- result.try(
    dict.get(lobby.players, target) |> result.replace_error(PlayerNotFound),
  )
  case shared_game.valid_player_cooldown(lobby.settings, seconds) {
    False -> Error(InvalidPlayerCooldown)
    True -> {
      let lobby =
        Lobby(..lobby, cooldowns: dict.insert(lobby.cooldowns, target, seconds))
      Ok(State(dict.insert(state.games, id, Open(lobby))))
    }
  }
}

fn set_color(
  state: State,
  id: String,
  name: String,
  color: player.Color,
) -> Result(State, Error) {
  use entry <- result.try(
    dict.get(state.games, id) |> result.replace_error(GameNotFound),
  )
  case entry {
    Running(..) -> Error(AlreadyStarted)
    Open(room) -> {
      use p <- result.try(
        dict.get(room.players, name) |> result.replace_error(PlayerNotFound),
      )
      case list.contains(shared_game.colors(room.settings), color) {
        False -> Error(InvalidColor)
        True ->
          case
            list.any(dict.values(room.players), fn(other) {
              other.username != name && other.color == color
            })
          {
            True -> Error(ColorTaken)
            False -> {
              let updated =
                Lobby(
                  ..room,
                  players: dict.insert(
                    room.players,
                    name,
                    player.Player(..p, color: color),
                  ),
                )
              Ok(State(dict.insert(state.games, id, Open(updated))))
            }
          }
      }
    }
  }
}

fn finish_change(
  state: State,
  reply: Subject(Result(Nil, Error)),
  changed: Result(State, Error),
) -> actor.Next(State, Message) {
  case changed {
    Ok(new_state) -> {
      process.send(reply, Ok(Nil))
      actor.continue(new_state)
    }
    Error(error) -> {
      process.send(reply, Error(error))
      actor.continue(state)
    }
  }
}

fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    CreateGame(host, settings, preferred, reply) ->
      handle_create_game(state, host, settings, preferred, reply)
    GetGame(id, reply) -> {
      process.send(
        reply,
        dict.get(state.games, id) |> result.replace_error(GameNotFound),
      )
      actor.continue(state)
    }
    AddBot(id, host, reply) ->
      finish_change(state, reply, add_bot_to_room(state, id, host))
    ListGames(reply) -> {
      // Return only room entries here. Game queries run in the caller so a busy
      // game cannot block joins, room lookups, or other lobby-list requests.
      process.send(reply, state.games)
      actor.continue(state)
    }
    JoinGame(id, name, preferred, reply) ->
      handle_join_game(state, id, name, preferred, reply)
    SetColor(id, name, color, reply) ->
      finish_change(state, reply, set_color(state, id, name, color))
    StartGame(id, name, reply) -> handle_start_game(state, id, name, reply)
    LeaveGame(id, name, reply) ->
      finish_change(state, reply, leave(state, id, name))
    CancelGame(id, name, reply) ->
      finish_change(state, reply, cancel(state, id, name))
    KickPlayer(id, host, target, reply) ->
      finish_change(state, reply, kick(state, id, host, target))
    SetPlayerCooldown(id, host, target, seconds, reply) ->
      finish_change(
        state,
        reply,
        set_cooldown(state, id, host, target, seconds),
      )
  }
}

pub fn start() -> Subject(Message) {
  let assert Ok(actor) =
    actor.new(State(games: dict.new()))
    |> actor.on_message(handle_message)
    |> actor.start
  actor.data
}

pub fn create_game(
  subject: Subject(Message),
  host: String,
  settings: shared_game.Settings,
) -> Result(String, Error) {
  create_game_with_preference(subject, host, settings, player.Black)
}

pub fn create_game_with_preference(
  subject: Subject(Message),
  host: String,
  settings: shared_game.Settings,
  preferred: player.Color,
) -> Result(String, Error) {
  process.call(subject, 100, fn(client) {
    CreateGame(host, settings, preferred, client)
  })
}

pub fn add_bot(
  subject: Subject(Message),
  id: String,
  host: String,
) -> Result(Nil, Error) {
  process.call(subject, 100, fn(reply) { AddBot(id, host, reply) })
}

pub fn get_game(subject: Subject(Message), id: String) -> Result(Entry, Error) {
  process.call(subject, 100, fn(client) { GetGame(id, client) })
}

pub fn list_games(subject: Subject(Message)) -> Dict(String, Metadata) {
  process.call(subject, 100, ListGames)
  |> list_metadata
}

pub fn join_game(
  subject: Subject(Message),
  id: String,
  name: String,
) -> Result(Bool, Error) {
  join_game_with_preference(subject, id, name, player.Black)
}

pub fn join_game_with_preference(
  subject: Subject(Message),
  id: String,
  name: String,
  preferred: player.Color,
) -> Result(Bool, Error) {
  process.call(subject, 100, fn(client) {
    JoinGame(id, name, preferred, client)
  })
}

pub fn choose_color(
  subject: Subject(Message),
  id: String,
  name: String,
  color: player.Color,
) -> Result(Nil, Error) {
  process.call(subject, 100, fn(reply) { SetColor(id, name, color, reply) })
}

pub fn start_game(
  subject: Subject(Message),
  id: String,
  name: String,
) -> Result(Bool, Error) {
  process.call(subject, 100, fn(client) { StartGame(id, name, client) })
}

pub fn leave_game(
  subject: Subject(Message),
  id: String,
  name: String,
) -> Result(Nil, Error) {
  process.call(subject, 100, fn(reply) { LeaveGame(id, name, reply) })
}

pub fn kick_player(
  subject: Subject(Message),
  id: String,
  host: String,
  target: String,
) -> Result(Nil, Error) {
  process.call(subject, 100, fn(reply) { KickPlayer(id, host, target, reply) })
}

pub fn set_player_cooldown(
  subject: Subject(Message),
  id: String,
  host: String,
  target: String,
  seconds: Int,
) -> Result(Nil, Error) {
  process.call(subject, 100, fn(reply) {
    SetPlayerCooldown(id, host, target, seconds, reply)
  })
}

pub fn cancel_game(
  subject: Subject(Message),
  id: String,
  name: String,
) -> Result(Nil, Error) {
  process.call(subject, 100, fn(reply) { CancelGame(id, name, reply) })
}
