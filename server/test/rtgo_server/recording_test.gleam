import envoy
import gleam/dict
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import rtgo_server/game
import rtgo_server/lobby
import rtgo_server/players
import rtgo_server/recorder
import rtgo_server/test_support
import rtgo_shared/game as settings
import rtgo_shared/player
import rtgo_shared/sgf
import simplifile

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn unique_id() -> String {
  "recordingtest" <> int.to_string(int.absolute_value(unique_integer()))
}

fn start_time() -> timestamp.Timestamp {
  let assert Ok(time) = timestamp.parse_rfc3339("2026-10-18T12:34:56Z")
  time
}

fn state() -> game.State {
  let players =
    dict.from_list([
      #("Alice", player.Player("Alice", player.Black)),
      #("Bob", player.Player("Bob", player.White)),
      #("Carol", player.Player("Carol", player.Cyan)),
    ])
  let state =
    game.new_state(
      players,
      settings.Settings(9, settings.MultiplayerGame, settings.Cooldown(1)),
      dict.from_list([#("Alice", 1), #("Bob", 2), #("Carol", 1)]),
      500,
    )
  game.State(
    ..state,
    started_utc: start_time(),
    record: sgf.Record(..state.record, date: Some("2026-10-18")),
  )
}

pub fn server_tests_use_the_isolated_recording_directory_test() {
  let assert Ok(directory) = envoy.get("RTGO_TEST_SGF_DIR")
  should.equal(recorder.directory(), directory)
  should.equal(directory == "data/sgf", False)
  should.equal(simplifile.is_directory(directory), Ok(True))
}

pub fn game_records_only_accepted_moves_with_elapsed_times_and_handicaps_test() {
  let initial = state()
  should.equal(
    game.play_at(initial, "Alice", #(0, 0), 600),
    Error(game.CoolingDown),
  )
  should.equal(initial.record.moves, [])
  let assert Ok(a) = game.play_at(initial, "Alice", #(0, 0), 1600)
  should.equal(game.play_at(a, "Alice", #(1, 0), 1601), Error(game.CoolingDown))
  let assert Error(_) = game.play_at(a, "Bob", #(0, 0), 2600)
  let assert Ok(b) = game.play_at(a, "Bob", #(1, 0), 2700)
  should.equal(list.length(b.record.moves), 2)
  should.equal(list.map(b.record.moves, fn(m) { m.at_ms }), [2200, 1100])
  let assert Ok(bob) =
    list.find(b.record.seats, fn(s) { s.player.username == "Bob" })
  should.equal(bob.cooldown_ms, 2000)
  let ended = game.advance(b, 30_000)
  // Bob is ready at 4700; the last pass occurs at 14700, not the poll time.
  should.equal(ended.record.finished_at, Some(14_200))
  let scored = game.finish_scoring(ended, Error(Nil))
  should.equal(scored.record.scoring, "unassisted")
  should.equal(dict.get(scored.record.scores, "Carol"), Ok(0))
  let assert Ok(replay) = scored.record |> sgf.encode |> sgf.decode
  let assert Ok(last) = list.last(replay.frames)
  should.equal(last.board.stones, b.board.stones)
}

pub fn sidecar_serializes_snapshots_and_old_recordings_download_without_a_room_test() {
  let assert Ok(_) = recorder.prepare()
  let id = unique_id()
  let initial = state()
  let assert Ok(played) = game.play_at(initial, "Carol", #(2, 2), 1500)
  let ended = played |> game.advance(30_000) |> game.finish_scoring(Error(Nil))
  let writer = recorder.start(id, initial.started_utc, initial.record)
  recorder.save(writer, played.record)
  recorder.save(writer, ended.record)
  recorder.flush(writer)
  should.equal(recorder.read(id), Ok(sgf.encode(ended.record)))
  // A fresh lobby simulates restart: no room/identity state is necessary.
  let users = players.start(test_support.test_sign_key())
  let rooms = lobby.start()
  let assert Ok(req) = request.to("https://rtgo.test/games/" <> id <> "/sgf")
  let download = test_support.send(req, users, rooms)
  should.equal(download.status, 200)
  should.equal(download.body, sgf.encode(ended.record))
  should.equal(
    response.get_header(download, "content-type"),
    Ok("application/x-go-sgf; charset=utf-8"),
  )
  let filename = "2026-10-18-1234-" <> id <> ".sgf"
  should.equal(
    response.get_header(download, "content-disposition"),
    Ok("attachment; filename=\"" <> filename <> "\""),
  )
  should.equal(recorder.exists(id), True)
  let assert Ok(_) = simplifile.delete(recorder.directory() <> "/" <> filename)
}

pub fn failed_snapshot_does_not_destroy_the_previous_recording_test() {
  let assert Ok(_) = recorder.prepare()
  let id = unique_id()
  let path = recorder.directory() <> "/2026-10-18-1234-" <> id <> ".sgf"
  let r = state().record
  let assert Ok(_) =
    recorder.write_at(recorder.directory(), id, start_time(), r)
  // Force the temporary-file write to fail, regardless of the test user's UID.
  let assert Ok(_) = simplifile.create_directory(path <> ".tmp")
  should.equal(
    result.is_error(recorder.write_at(recorder.directory(), id, start_time(), r)),
    True,
  )
  should.equal(recorder.read(id), Ok(sgf.encode(r)))
  let assert Ok(_) = simplifile.delete(path <> ".tmp")
  let assert Ok(_) = simplifile.delete(path)
}

pub fn filenames_use_the_fixed_utc_start_minute_test() {
  should.equal(
    recorder.filename("four", start_time()),
    "2026-10-18-1234-four.sgf",
  )
  let assert Ok(offset_start) =
    timestamp.parse_rfc3339("2026-10-19T01:05:59+02:00")
  should.equal(
    recorder.filename("four", offset_start),
    "2026-10-18-2305-four.sgf",
  )
  let assert Ok(midnight) = timestamp.parse_rfc3339("2026-10-18T00:01:59Z")
  should.equal(recorder.filename("four", midnight), "2026-10-18-0001-four.sgf")
}

pub fn later_updates_keep_the_same_filename_across_midnight_test() {
  let assert Ok(_) = recorder.prepare()
  let id = unique_id()
  let initial = state()
  let writer = recorder.start(id, initial.started_utc, initial.record)
  let finished = sgf.Record(..initial.record, finished_at: Some(86_400_000))
  recorder.save(writer, finished)
  recorder.flush(writer)
  let filename = recorder.filename(id, initial.started_utc)
  should.equal(recorder.read_named(id), Ok(#(filename, sgf.encode(finished))))
  let later = timestamp.add(initial.started_utc, duration.hours(24))
  should.not_equal(recorder.filename(id, later), filename)
  let assert Ok(_) = simplifile.delete(recorder.directory() <> "/" <> filename)
}

pub fn archive_lookup_only_accepts_start_minute_prefixed_recordings_test() {
  let assert Ok(_) = recorder.prepare()
  let id = unique_id()
  let files = [
    id <> ".sgf",
    "2026-10-18-" <> id <> ".sgf",
    "2026-10-18-1234-" <> id <> ".sgf.tmp",
    "not-a-date-1234-" <> id <> ".sgf",
    "2026-10-18-extra-" <> id <> ".sgf",
    "2026-10-18-2400-" <> id <> ".sgf",
    "2026-10-18-1260-" <> id <> ".sgf",
    "2026-10-18-12ab-" <> id <> ".sgf",
    "2026-13-18-1234-" <> id <> ".sgf",
    "2026-10-18x1234-" <> id <> ".sgf",
    "2026-10-18-1234-extra-" <> id <> ".sgf",
  ]
  list.each(files, fn(file) {
    let assert Ok(_) = simplifile.write(recorder.directory() <> "/" <> file, "")
  })
  should.equal(recorder.exists(id), False)
  should.equal(recorder.read_named(id), Error(Nil))
  list.each(files, fn(file) {
    let assert Ok(_) = simplifile.delete(recorder.directory() <> "/" <> file)
  })
}

pub fn recording_paths_cannot_escape_the_directory_test() {
  ["../secret", "a/b", "a\\b", "%2e%2e", "", "a\"\r\nheader"]
  |> list.each(fn(id) {
    should.equal(recorder.safe_id(id), False)
    should.equal(recorder.read(id), Error(Nil))
  })
  should.equal(recorder.safe_id("room-123"), True)
}

pub fn live_download_has_the_latest_move_without_waiting_for_disk_test() {
  let users = players.start(test_support.test_sign_key())
  let rooms = lobby.start()
  let assert Ok(id) =
    lobby.create_game(
      rooms,
      "Alice",
      settings.Settings(
        ..settings.default_settings,
        time_settings: settings.Cooldown(1),
      ),
    )
  let assert Ok(_) = lobby.join_game(rooms, id, "Bob")
  let assert Ok(_) = lobby.start_game(rooms, id, "Alice")
  let assert Ok(lobby.Running(subject:, ..)) = lobby.get_game(rooms, id)
  test_support.wait_until_ready(subject, "Alice")
  let assert Ok(_) = game.play(subject, "Alice", #(3, 3))
  let assert Ok(req) = request.to("https://rtgo.test/games/" <> id <> "/sgf")
  let download = test_support.send(req, users, rooms)
  should.equal(download.status, 200)
  let #(started_at, record) = game.get_recording(subject)
  should.equal(
    record.date,
    Some(
      timestamp.to_rfc3339(started_at, calendar.utc_offset)
      |> string.slice(0, 10),
    ),
  )
  should.equal(
    response.get_header(download, "content-disposition"),
    Ok("attachment; filename=\"" <> recorder.filename(id, started_at) <> "\""),
  )
  let assert Ok(replay) = sgf.decode(download.body)
  should.equal(list.length(replay.record.moves), 1)
  should.equal(list.length(replay.frames), 2)
}
