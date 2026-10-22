import gleam/dict
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import rtgo_server/game_listing
import rtgo_server/lobby
import rtgo_server/players
import rtgo_server/recorder
import rtgo_server/test_support
import rtgo_shared/game
import rtgo_shared/lobby_api
import rtgo_shared/player
import rtgo_shared/sgf
import simplifile

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn directory() -> String {
  let path =
    recorder.directory()
    <> "/listing-"
    <> int.to_string(int.absolute_value(unique_integer()))
  let assert Ok(_) = simplifile.create_directory_all(path)
  path
}

fn start() -> timestamp.Timestamp {
  let assert Ok(time) = timestamp.parse_rfc3339("2026-10-18T12:00:00Z")
  time
}

fn record() -> sgf.Record {
  sgf.Record(
    ..sgf.new(9, [
      sgf.Seat("p1", player.Player("Alice", player.Black), 2000),
      sgf.Seat("p2", player.Player("Bob", player.Cyan), 3000),
    ]),
    finished_at: Some(0),
    time_settings: Some(game.StoneSavings(2, 5, 500)),
  )
}

pub fn archives_are_paged_newest_first_with_active_rooms_on_every_page_test() {
  let directory = directory()
  list.each(list.range(1, 41), fn(index) {
    let assert Ok(_) =
      recorder.write_at(
        directory,
        "saved" <> int.to_string(index),
        timestamp.add(start(), duration.minutes(index)),
        record(),
      )
  })
  // These sort ahead of the valid games, but must not consume page slots.
  let later = timestamp.add(start(), duration.hours(2))
  let assert Ok(_) =
    recorder.write_at(
      directory,
      "unfinished",
      later,
      sgf.Record(..record(), finished_at: None),
    )
  let assert Ok(_) =
    simplifile.write(
      directory <> "/" <> recorder.filename("broken", later),
      "not sgf",
    )
  let assert Ok(_) =
    simplifile.write(
      directory <> "/" <> recorder.filename("temporary", later) <> ".tmp",
      sgf.encode(record()),
    )
  let assert Ok(_) =
    simplifile.write(
      directory <> "/2026-10-18-2500-invalid.sgf",
      sgf.encode(record()),
    )
  let assert Ok(_) =
    simplifile.write(
      directory <> "/2026-10-18-dateonly.sgf",
      sgf.encode(record()),
    )
  let memory =
    dict.from_list([
      #(
        "open",
        lobby.Metadata(game.Negotiating, 1, game.default_settings, None),
      ),
      #(
        "running",
        lobby.Metadata(game.Started, 2, game.default_settings, Some(start())),
      ),
    ])
  let pages =
    list.map(list.range(0, 2), fn(page) {
      let response = game_listing.list_at(directory, memory, page)
      should.equal(response.has_more, page < 2)
      let active =
        list.filter(response.games, fn(entry) { entry.phase != game.Finished })
      should.equal(list.map(active, fn(entry) { entry.id }), ["running", "open"])
      list.filter(response.games, fn(entry) { entry.phase == game.Finished })
    })
  should.equal(list.map(pages, list.length), [20, 20, 1])
  should.equal(
    pages |> list.flatten |> list.map(fn(entry) { entry.id }),
    list.range(1, 41)
      |> list.reverse
      |> list.map(fn(index) { "saved" <> int.to_string(index) }),
  )
  let assert Ok(first) = pages |> list.flatten |> list.first
  should.equal(first.started_at, Some("2026-10-18T12:41:00Z"))
  should.equal(
    first.settings,
    game.Settings(9, game.MultiplayerGame, game.StoneSavings(2, 5, 500)),
  )
  let empty = game_listing.list_at(directory, memory, 3)
  should.equal(empty.has_more, False)
  should.equal(list.length(empty.games), 2)
  let assert Ok(_) = simplifile.delete(directory)
}

pub fn memory_wins_over_saved_metadata_without_duplicate_rows_test() {
  let directory = directory()
  let assert Ok(_) =
    recorder.write_at(directory, "duplicate", start(), record())
  let assert Ok(_) =
    recorder.write_at(directory, "stillrunning", start(), record())
  let latest = timestamp.add(start(), duration.seconds(30))
  let settings = game.Settings(19, game.TwoPlayerGame, game.DragDerby)
  let memory =
    dict.from_list([
      #("duplicate", lobby.Metadata(game.Finished, 2, settings, Some(latest))),
      #("stillrunning", lobby.Metadata(game.Started, 2, settings, Some(latest))),
    ])
  let response = game_listing.list_at(directory, memory, 0)
  should.equal(list.length(response.games), 2)
  let assert Ok(finished) =
    list.find(response.games, fn(entry) { entry.id == "duplicate" })
  should.equal(finished.settings, settings)
  should.equal(finished.started_at, Some("2026-10-18T12:00:30Z"))
  let assert Ok(running) =
    list.find(response.games, fn(entry) { entry.id == "stillrunning" })
  should.equal(running.phase, game.Started)
  should.equal(response.has_more, False)
  let assert Ok(_) = simplifile.delete(directory)
}

pub fn missing_archive_directory_keeps_memory_games_test() {
  let directory = directory()
  let assert Ok(_) = simplifile.delete(directory)
  let response =
    game_listing.list_at(
      directory,
      dict.from_list([
        #(
          "memory",
          lobby.Metadata(game.Finished, 2, game.default_settings, Some(start())),
        ),
      ]),
      0,
    )
  should.equal(list.map(response.games, fn(entry) { entry.id }), ["memory"])
  should.equal(response.has_more, False)
}

pub fn archived_games_are_listed_and_downloaded_after_restart_test() {
  let assert Ok(_) = recorder.prepare()
  let id = "archivetest" <> int.to_string(int.absolute_value(unique_integer()))
  let assert Ok(started_at) = timestamp.parse_rfc3339("2099-01-02T03:04:00Z")
  let assert Ok(_) =
    recorder.write_at(recorder.directory(), id, started_at, record())
  let users = players.start(test_support.test_sign_key())
  let rooms = lobby.start()
  let response =
    lobby_api.games_request("https://rtgo.test")
    |> test_support.send(users, rooms)
    |> test_support.read_json(lobby_api.list_games_response_decoder)
  let assert Ok(archived) =
    list.find(response.games, fn(entry) { entry.id == id })
  should.equal(archived.phase, game.Finished)
  should.equal(archived.started_at, Some("2099-01-02T03:04:00Z"))
  should.equal(lobby.get_game(rooms, id), Error(lobby.GameNotFound))
  let assert Ok(req) = request.to("https://rtgo.test/games/" <> id <> "/sgf")
  let download = test_support.send(req, users, rooms)
  should.equal(download.status, 200)
  should.equal(download.body, sgf.encode(record()))
  let assert Ok(_) =
    simplifile.delete(
      recorder.directory() <> "/" <> recorder.filename(id, started_at),
    )
}

pub fn page_query_is_validated_and_applied_by_the_http_route_test() {
  let users = players.start(test_support.test_sign_key())
  let rooms = lobby.start()
  let assert Ok(id) = lobby.create_game(rooms, "host", game.default_settings)
  let response =
    lobby_api.games_page_request("https://rtgo.test", 1_000_000)
    |> test_support.send(users, rooms)
    |> test_support.read_json(lobby_api.list_games_response_decoder)
  should.equal(list.map(response.games, fn(entry) { entry.id }), [id])
  should.equal(response.has_more, False)
  list.each(["-1", "not-a-number", "1000001", ""], fn(page) {
    let assert Ok(req) = request.to("https://rtgo.test/games?page=" <> page)
    should.equal(test_support.send(req, users, rooms).status, 400)
  })
}
