import gleam/dict
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
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
    record: sgf.Record(..state.record, date: Some("2026-10-18")),
  )
}

pub fn game_records_only_accepted_moves_with_elapsed_times_and_handicaps_test() {
  let initial = state()
  let assert Ok(a) = game.play_at(initial, "Alice", #(0, 0), 600)
  should.equal(game.play_at(a, "Alice", #(1, 0), 601), Error(game.CoolingDown))
  let assert Error(_) = game.play_at(a, "Bob", #(0, 0), 700)
  let assert Ok(b) = game.play_at(a, "Bob", #(1, 0), 800)
  should.equal(list.length(b.record.moves), 2)
  should.equal(list.map(b.record.moves, fn(m) { m.at_ms }), [300, 100])
  let assert Ok(bob) =
    list.find(b.record.seats, fn(s) { s.player.username == "Bob" })
  should.equal(bob.cooldown_ms, 2000)
  let ended = game.advance(b, 30_000)
  // Bob is ready at 2800; the last pass occurs at 12800, not the poll time.
  should.equal(ended.record.finished_at, Some(12_300))
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
  let writer = recorder.start(id, initial.record)
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
  let filename = "2026-10-18-" <> id <> ".sgf"
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
  let path = recorder.directory() <> "/2026-10-18-" <> id <> ".sgf"
  let r = state().record
  let assert Ok(_) = recorder.write_at(recorder.directory(), id, r)
  // Force the temporary-file write to fail, regardless of the test user's UID.
  let assert Ok(_) = simplifile.create_directory(path <> ".tmp")
  should.equal(
    result.is_error(recorder.write_at(recorder.directory(), id, r)),
    True,
  )
  should.equal(recorder.read(id), Ok(sgf.encode(r)))
  let assert Ok(_) = simplifile.delete(path <> ".tmp")
  let assert Ok(_) = simplifile.delete(path)
}

pub fn filenames_use_the_fixed_start_date_even_for_later_updates_test() {
  let record = state().record
  should.equal(recorder.filename("four", record), "2026-10-18-four.sgf")
  let finished = sgf.Record(..record, finished_at: Some(86_400_000))
  should.equal(recorder.filename("four", finished), "2026-10-18-four.sgf")
}

pub fn archive_lookup_only_accepts_date_prefixed_recordings_test() {
  let assert Ok(_) = recorder.prepare()
  let id = unique_id()
  let files = [
    id <> ".sgf",
    "2026-10-18-" <> id <> ".sgf.tmp",
    "not-a-date-" <> id <> ".sgf",
    "2026-10-18-extra-" <> id <> ".sgf",
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
    lobby.create_game(rooms, "Alice", settings.default_settings)
  let assert Ok(_) = lobby.join_game(rooms, id, "Bob")
  let assert Ok(_) = lobby.start_game(rooms, id, "Alice")
  let assert Ok(lobby.Running(subject:, ..)) = lobby.get_game(rooms, id)
  let assert Ok(_) = game.play(subject, "Alice", #(3, 3))
  let assert Ok(req) = request.to("https://rtgo.test/games/" <> id <> "/sgf")
  let download = test_support.send(req, users, rooms)
  should.equal(download.status, 200)
  let record = game.get_record(subject)
  should.equal(record.date, Some(recorder.today()))
  should.equal(
    response.get_header(download, "content-disposition"),
    Ok("attachment; filename=\"" <> recorder.filename(id, record) <> "\""),
  )
  let assert Ok(replay) = sgf.decode(download.body)
  should.equal(list.length(replay.record.moves), 1)
  should.equal(list.length(replay.frames), 2)
}
