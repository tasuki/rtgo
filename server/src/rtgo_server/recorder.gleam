/// A per-game sidecar serializes atomic SGF snapshots without doing disk I/O
/// in the game actor. Failed writes leave the previous complete file intact.
import envoy
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import rtgo_server/log
import rtgo_shared/sgf
import simplifile

pub type Message {
  Save(sgf.Record)
  Flush(Subject(Nil))
}

pub fn directory() -> String {
  envoy.get("SGF_DIR") |> result.unwrap("data/sgf")
}

pub fn prepare() -> Result(Nil, simplifile.FileError) {
  let directory = directory()
  use _ <- result.try(simplifile.create_directory_all(directory))
  // Fail at startup rather than silently running with an unwritable mount.
  let probe = directory <> "/.write-check"
  use _ <- result.try(simplifile.write(probe, ""))
  simplifile.delete(probe)
}

pub fn safe_id(id: String) -> Bool {
  id != ""
  && string.byte_size(id) <= 100
  && list.all(string.to_graphemes(id), fn(c) {
    string.contains("abcdefghijklmnopqrstuvwxyz0123456789-", c)
  })
}

fn valid_start_minute(prefix: String) -> Bool {
  let date = string.slice(prefix, 0, 10)
  let hour = string.slice(prefix, 11, 2)
  let minute = string.slice(prefix, 13, 2)
  string.byte_size(prefix) == 15
  && string.slice(prefix, 10, 1) == "-"
  && result.is_ok(timestamp.parse_rfc3339(
    date <> "T" <> hour <> ":" <> minute <> ":00Z",
  ))
}

/// Use the fixed UTC start minute for both saves and downloads.
pub fn filename(id: String, started_at: timestamp.Timestamp) -> String {
  let assert True = safe_id(id)
  let utc = timestamp.to_rfc3339(started_at, calendar.utc_offset)
  string.slice(utc, 0, 10)
  <> "-"
  <> string.slice(utc, 11, 2)
  <> string.slice(utc, 14, 2)
  <> "-"
  <> id
  <> ".sgf"
}

pub type Archive {
  Archive(id: String, filename: String, started_at: timestamp.Timestamp)
}

/// Enumerate only canonical recording filenames, without loading move histories.
pub fn archives(directory: String) -> List(Archive) {
  directory
  |> simplifile.read_directory
  |> result.unwrap([])
  |> list.filter_map(fn(file) {
    let prefix = string.slice(file, 0, 15)
    let id = string.slice(file, 16, string.length(file) - 20)
    case
      valid_start_minute(prefix)
      && string.slice(file, 15, 1) == "-"
      && string.ends_with(file, ".sgf")
      && safe_id(id)
      && simplifile.is_file(directory <> "/" <> file) == Ok(True)
    {
      False -> Error(Nil)
      True -> {
        use started_at <- result.try(
          timestamp.parse_rfc3339(
            string.slice(prefix, 0, 10)
            <> "T"
            <> string.slice(prefix, 11, 2)
            <> ":"
            <> string.slice(prefix, 13, 2)
            <> ":00Z",
          )
          |> result.replace_error(Nil),
        )
        Ok(Archive(id, file, started_at))
      }
    }
  })
}

fn find_filename(directory: String, id: String) -> Result(String, Nil) {
  case safe_id(id) {
    False -> Error(Nil)
    True -> {
      use files <- result.try(
        simplifile.read_directory(directory) |> result.replace_error(Nil),
      )
      files
      |> list.sort(string.compare)
      |> list.find(fn(file) {
        string.byte_size(file) == 16 + string.byte_size(id) + 4
        && string.ends_with(file, "-" <> id <> ".sgf")
        && valid_start_minute(string.slice(file, 0, 15))
        && simplifile.is_file(directory <> "/" <> file) == Ok(True)
      })
    }
  }
}

pub fn exists(id: String) -> Bool {
  result.is_ok(find_filename(directory(), id))
}

pub fn read_named(id: String) -> Result(#(String, String), Nil) {
  let directory = directory()
  use filename <- result.try(find_filename(directory, id))
  use text <- result.try(
    simplifile.read(directory <> "/" <> filename) |> result.replace_error(Nil),
  )
  Ok(#(filename, text))
}

pub fn read(id: String) -> Result(String, Nil) {
  read_named(id) |> result.map(fn(recording) { recording.1 })
}

pub fn write_at(
  directory: String,
  id: String,
  started_at: timestamp.Timestamp,
  record: sgf.Record,
) -> Result(Nil, simplifile.FileError) {
  write_file(directory, filename(id, started_at), record)
}

fn write_file(
  directory: String,
  filename: String,
  record: sgf.Record,
) -> Result(Nil, simplifile.FileError) {
  let path = directory <> "/" <> filename
  use _ <- result.try(simplifile.write(path <> ".tmp", sgf.encode(record)))
  simplifile.rename(path <> ".tmp", path)
}

pub fn start(
  id: String,
  started_at: timestamp.Timestamp,
  record: sgf.Record,
) -> Subject(Message) {
  let directory = directory()
  let filename = filename(id, started_at)
  case simplifile.create_directory_all(directory) {
    Ok(_) -> Nil
    Error(error) ->
      log.err("Cannot create SGF directory: " <> string.inspect(error))
  }
  let assert Ok(actor) =
    actor.new(Nil)
    |> actor.on_message(fn(state, message) {
      case message {
        Save(record) ->
          case write_file(directory, filename, record) {
            Ok(_) -> Nil
            Error(error) ->
              log.err(
                "Could not save SGF " <> id <> ": " <> string.inspect(error),
              )
          }
        Flush(reply) -> process.send(reply, Nil)
      }
      actor.continue(state)
    })
    |> actor.start
  process.send(actor.data, Save(record))
  actor.data
}

pub fn save(subject: Subject(Message), record: sgf.Record) -> Nil {
  process.send(subject, Save(record))
}

/// A barrier for tests/administrative callers; not needed in the gameplay path.
pub fn flush(subject: Subject(Message)) -> Nil {
  process.call(subject, 5000, Flush)
}
