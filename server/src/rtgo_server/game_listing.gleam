/// Combine live metadata with saved recordings, preferring memory for duplicate IDs.
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import rtgo_server/lobby
import rtgo_server/recorder
import rtgo_shared/game
import rtgo_shared/lobby_api
import rtgo_shared/player
import rtgo_shared/sgf
import simplifile

pub const page_size = 20

type Candidate {
  Memory(id: String, metadata: lobby.Metadata)
  Saved(recorder.Archive)
}

fn identity(candidate: Candidate) -> #(String, Option(timestamp.Timestamp)) {
  case candidate {
    Memory(id, metadata) -> #(id, metadata.started_at)
    Saved(archive) -> #(archive.id, Some(archive.started_at))
  }
}

fn newest_first(a: Candidate, b: Candidate) -> order.Order {
  let #(a_id, a_start) = identity(a)
  let #(b_id, b_start) = identity(b)
  let by_date = case a_start, b_start {
    Some(a), Some(b) -> timestamp.compare(b, a)
    Some(_), None -> order.Lt
    None, Some(_) -> order.Gt
    None, None -> order.Eq
  }
  case by_date {
    order.Eq -> string.compare(a_id, b_id)
    order -> order
  }
}

fn metadata(id: String, entry: lobby.Metadata) -> lobby_api.GameMetadata {
  lobby_api.GameMetadata(
    id,
    entry.phase,
    entry.player_count,
    entry.settings,
    option.map(entry.started_at, timestamp.to_rfc3339(_, calendar.utc_offset)),
  )
}

fn load(
  directory: String,
  candidate: Candidate,
) -> Result(lobby_api.GameMetadata, Nil) {
  case candidate {
    Memory(id, entry) -> Ok(metadata(id, entry))
    Saved(archive) -> {
      use source <- result.try(
        simplifile.read(directory <> "/" <> archive.filename)
        |> result.replace_error(Nil),
      )
      use record <- result.try(
        sgf.decode_metadata(source) |> result.replace_error(Nil),
      )
      case record.finished_at {
        None -> Error(Nil)
        Some(_) -> {
          let conventional =
            list.all(record.seats, fn(seat) {
              seat.player.color == player.Black
              || seat.player.color == player.White
            })
          let game_type = case conventional {
            True -> game.TwoPlayerGame
            False -> game.MultiplayerGame
          }
          let base_seconds =
            record.seats
            |> list.map(fn(seat) { seat.cooldown_ms / 1000 })
            |> list.reduce(int.min)
            |> result.unwrap(1)
            |> int.max(1)
          Ok(lobby_api.GameMetadata(
            archive.id,
            game.Finished,
            list.length(record.seats),
            game.Settings(
              record.size,
              game_type,
              option.unwrap(record.time_settings, game.Cooldown(base_seconds)),
            ),
            Some(timestamp.to_rfc3339(archive.started_at, calendar.utc_offset)),
          ))
        }
      }
    }
  }
}

/// Read only enough valid finished recordings to fill the requested page plus
/// one lookahead. Invalid, interrupted, and temporary recordings are not games.
fn finished_page(
  directory: String,
  candidates: List(Candidate),
  skip: Int,
  remaining: Int,
  seen: set.Set(String),
) -> List(lobby_api.GameMetadata) {
  case candidates, remaining {
    [], _ | _, 0 -> []
    [candidate, ..rest], _ -> {
      let id = identity(candidate).0
      case set.contains(seen, id) {
        True -> finished_page(directory, rest, skip, remaining, seen)
        False ->
          case load(directory, candidate) {
            Error(_) -> finished_page(directory, rest, skip, remaining, seen)
            Ok(game) -> {
              let seen = set.insert(seen, id)
              case skip > 0 {
                True ->
                  finished_page(directory, rest, skip - 1, remaining, seen)
                False -> [
                  game,
                  ..finished_page(directory, rest, 0, remaining - 1, seen)
                ]
              }
            }
          }
      }
    }
  }
}

pub fn list_at(
  directory: String,
  memory: Dict(String, lobby.Metadata),
  page: Int,
) -> lobby_api.ListGamesResponse {
  let entries = dict.to_list(memory)
  let active =
    entries
    |> list.filter(fn(entry) { { entry.1 }.phase != game.Finished })
    |> list.sort(fn(a, b) { newest_first(Memory(a.0, a.1), Memory(b.0, b.1)) })
    |> list.map(fn(entry) { metadata(entry.0, entry.1) })
  let finished =
    entries
    |> list.filter(fn(entry) { { entry.1 }.phase == game.Finished })
    |> list.map(fn(entry) { Memory(entry.0, entry.1) })
  let saved =
    recorder.archives(directory)
    |> list.filter(fn(archive) { !dict.has_key(memory, archive.id) })
    |> list.map(Saved)
  let page_games =
    list.append(finished, saved)
    |> list.sort(newest_first)
    |> finished_page(
      directory,
      _,
      int.max(page, 0) * page_size,
      page_size + 1,
      set.new(),
    )
  lobby_api.ListGamesResponse(
    list.append(active, list.take(page_games, page_size)),
    list.length(page_games) > page_size,
  )
}
