import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import rtgo_server/adjudication
import rtgo_shared/game as shared_game
import rtgo_shared/go
import rtgo_shared/play_api
import rtgo_shared/player

/// Times are server-monotonic milliseconds. A player automatically passes ten
/// seconds after becoming ready, and may resume until everyone has passed.
pub const pass_grace_ms = 10_000

pub type State {
  State(
    players: Dict(String, player.Player),
    board: go.Game,
    settings: shared_game.Settings,
    cooldowns: Dict(String, Int),
    ready_at: Dict(String, Int),
    phase: shared_game.GamePhase,
    revision: Int,
    scoring: play_api.ScoringStatus,
    scoring_started: Bool,
    scores: Dict(String, Int),
    dead_stones: List(go.Point),
  )
}

pub type Snapshot {
  Snapshot(
    players: Dict(String, player.Player),
    board: go.Game,
    settings: shared_game.Settings,
    cooldowns: Dict(String, Int),
    phase: shared_game.GamePhase,
    live: play_api.State,
  )
}

pub type Error {
  UnknownPlayer
  InvalidMove(go.MoveError)
  CoolingDown
  GameFinished
}

pub type Message {
  Play(player: String, move: go.Point, reply: Subject(Result(Nil, Error)))
  GetGame(reply: Subject(Snapshot))
  Tick(Subject(Message))
  Scored(Result(List(go.Point), Nil))
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom.Atom) -> Int

fn now_ms() -> Int {
  monotonic_time(atom.create("millisecond"))
}

pub fn new_state(
  players: Dict(String, player.Player),
  settings: shared_game.Settings,
  cooldowns: Dict(String, Int),
  now: Int,
) -> State {
  State(
    players,
    go.new_game(settings.board_size),
    settings,
    cooldowns,
    dict.map_values(players, fn(_, _) { now }),
    shared_game.Started,
    0,
    play_api.NotScored,
    False,
    dict.new(),
    [],
  )
}

pub fn advance(state: State, now: Int) -> State {
  case
    state.phase == shared_game.Started
    && list.all(dict.values(state.ready_at), fn(ready) {
      now >= ready + pass_grace_ms
    })
  {
    True ->
      State(
        ..state,
        phase: shared_game.Finished,
        scoring: play_api.Scoring,
        revision: state.revision + 1,
      )
    False -> state
  }
}

/// Pure transition, also used to test exact clock boundaries without sleeping.
pub fn play_at(
  state: State,
  name: String,
  point: go.Point,
  now: Int,
) -> Result(State, Error) {
  let state = advance(state, now)
  use p <- result.try(
    dict.get(state.players, name) |> result.replace_error(UnknownPlayer),
  )
  case state.phase {
    shared_game.Finished -> Error(GameFinished)
    _ -> {
      let assert Ok(ready) = dict.get(state.ready_at, name)
      case now < ready {
        True -> Error(CoolingDown)
        False -> {
          use board <- result.try(
            go.play(state.board, p, point) |> result.map_error(InvalidMove),
          )
          let seconds =
            dict.get(state.cooldowns, name)
            |> result.unwrap(shared_game.base_cooldown(state.settings))
          Ok(
            State(
              ..state,
              board: board,
              ready_at: dict.insert(state.ready_at, name, now + seconds * 1000),
              revision: state.revision + 1,
            ),
          )
        }
      }
    }
  }
}

pub fn snapshot_at(state: State, now: Int) -> Snapshot {
  let state = advance(state, now)
  let statuses =
    state.players
    |> dict.values
    |> list.sort(fn(a, b) { string.compare(a.username, b.username) })
    |> list.map(fn(p) {
      let assert Ok(ready) = dict.get(state.ready_at, p.username)
      play_api.PlayerStatus(
        p,
        int.max(0, ready - now),
        int.max(0, ready + pass_grace_ms - now),
      )
    })
  let end_in =
    list.fold(statuses, 0, fn(acc, status) { int.max(acc, status.pass_in_ms) })
  let finished = state.phase == shared_game.Finished
  Snapshot(
    state.players,
    state.board,
    state.settings,
    state.cooldowns,
    state.phase,
    play_api.State(
      state.board,
      statuses,
      finished,
      state.revision,
      end_in,
      state.scores,
      state.scoring,
      state.dead_stones,
    ),
  )
}

/// Keep the actual final position/history intact. Only the scoring copy loses
/// estimated dead stones, so clients can show exactly what was adjudicated.
pub fn finish_scoring(
  state: State,
  result: Result(List(go.Point), Nil),
) -> State {
  case
    state.phase == shared_game.Finished && state.scoring == play_api.Scoring
  {
    False -> state
    True -> {
      let #(scoring, dead_stones) = case result {
        Ok(dead) -> #(play_api.Estimated, dead)
        Error(_) -> #(play_api.Unavailable, [])
      }
      State(
        ..state,
        scoring: scoring,
        dead_stones: dead_stones,
        scores: go.score(go.remove_stones(state.board, dead_stones)),
        revision: state.revision + 1,
      )
    }
  }
}

fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  let now = now_ms()
  let state = advance(state, now)
  case msg {
    Play(name, point, reply) ->
      case play_at(state, name, point, now) {
        Ok(updated) -> {
          process.send(reply, Ok(Nil))
          actor.continue(updated)
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    GetGame(reply) -> {
      process.send(reply, snapshot_at(state, now))
      actor.continue(state)
    }
    Scored(result) -> actor.continue(finish_scoring(state, result))
    Tick(subject) -> {
      case state.phase, state.scoring, state.scoring_started {
        shared_game.Started, _, _ -> {
          let _ = process.send_after(subject, 100, Tick(subject))
          actor.continue(state)
        }
        shared_game.Finished, play_api.Scoring, False -> {
          // Inference needs only the position, not a copy of the superko history.
          let board =
            go.Game(
              ..go.new_game(state.board.board_size),
              stones: state.board.stones,
            )
          let _ =
            process.spawn_unlinked(fn() {
              process.send(subject, Scored(adjudication.estimate(board)))
            })
          // A failed/stalled engine must not leave the final result pending
          // forever. Late worker replies are ignored after this fallback.
          let _ = process.send_after(subject, 30_000, Scored(Error(Nil)))
          actor.continue(State(..state, scoring_started: True))
        }
        _, _, _ -> actor.continue(state)
      }
    }
  }
}

pub fn start(
  players: Dict(String, player.Player),
  settings: shared_game.Settings,
  cooldowns: Dict(String, Int),
) -> Subject(Message) {
  let assert Ok(actor) =
    actor.new(new_state(players, settings, cooldowns, now_ms()))
    |> actor.on_message(handle_message)
    |> actor.start
  process.send(actor.data, Tick(actor.data))
  actor.data
}

pub fn play(
  subject: Subject(Message),
  player_name: String,
  move: go.Point,
) -> Result(Nil, Error) {
  process.call(subject, 1000, fn(reply) { Play(player_name, move, reply) })
}

pub fn get_game(subject: Subject(Message)) -> Snapshot {
  process.call(subject, 1000, fn(reply) { GetGame(reply) })
}
