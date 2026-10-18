import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import lustre/element
import rtgo_client as app
import rtgo_client/player_info
import rtgo_client/replay
import rtgo_shared/go

const source = "(;FF[4]SZ[9]RTFORMAT[1]RTPLAYER[p1:Alice:black:1000][p2:Bob:white:2000][p3:Carol:cyan:1000]RTEND[13000]RTSCORING[estimated]RTSCORE[p1:81][p2:0][p3:0]RTDEAD[cb];RTMOVE[p2:bb]RTTIME[0];RTMOVE[p1:ab]RTTIME[0];RTMOVE[p1:ba]RTTIME[1000];RTMOVE[p3:cb]RTTIME[1000];RTMOVE[p1:bc]RTTIME[2000])"

pub fn replay_starts_empty_and_navigation_reconstructs_captures_test() {
  let loaded = replay.load(replay.new(), source)
  should.equal(loaded.index, 0)
  should.equal(dict.size(replay.frame(loaded).board.stones), 0)
  let first = replay.update(loaded, replay.Step(1))
  should.equal(dict.has_key(replay.frame(first).board.stones, #(1, 1)), True)
  let last = replay.update(first, replay.Seek("999"))
  should.equal(last.index, 5)
  should.equal(dict.has_key(replay.frame(last).board.stones, #(1, 1)), False)
  let previous = replay.update(last, replay.Step(-1))
  should.equal(dict.has_key(replay.frame(previous).board.stones, #(1, 1)), True)
  should.equal(replay.update(previous, replay.Seek("-10")).index, 0)
}

pub fn replay_board_is_read_only_and_scoring_only_appears_at_end_test() {
  let loaded = replay.load(replay.new(), source)
  let start = replay.view(loaded, False) |> element.to_string
  should.equal(string.contains(start, "playable"), False)
  should.equal(string.contains(start, "territory-point"), False)
  should.equal(string.contains(start, "Bob"), True)
  should.equal(string.contains(start, "2s cooldown"), True)
  let last =
    replay.update(loaded, replay.Seek("5"))
    |> replay.view(False)
    |> element.to_string
  should.equal(string.contains(last, "dead-stone"), True)
  should.equal(string.contains(last, "territory-point"), True)
  should.equal(string.contains(last, "Alice: 81 points"), True)
  should.equal(string.contains(last, "Bob: 0 points"), True)
  should.equal(string.contains(last, "Alice · bc · 2.000s"), True)
}

pub fn malformed_import_reports_an_error_without_destroying_loaded_replay_test() {
  let loaded = replay.load(replay.new(), source)
  let invalid =
    loaded
    |> replay.update(replay.SourceChanged("not sgf"))
    |> replay.update(replay.Load)
  should.equal(invalid.replay, loaded.replay)
  should.not_equal(invalid.error, None)
  should.equal(
    string.contains(
      element.to_string(replay.view(invalid, False)),
      "role=\"alert\"",
    ),
    True,
  )
}

pub fn empty_recording_has_a_single_position_and_disabled_controls_test() {
  let loaded =
    replay.load(
      replay.new(),
      "(;SZ[9]RTFORMAT[1]RTPLAYER[p1:A:black:1000][p2:B:white:1000])",
    )
  let assert Some(r) = loaded.replay
  should.equal(list.length(r.frames), 1)
  should.equal(replay.update(loaded, replay.Step(1)).index, 0)
  should.equal(
    string.contains(
      element.to_string(replay.view(loaded, False)),
      "Unfinished recording",
    ),
    True,
  )
}

pub fn replay_is_accessible_without_login_and_old_requests_are_ignored_test() {
  let initial =
    app.initial_model(
      app.Replay(None),
      player_info.OtherError("No server"),
      "https://rtgo.test",
    )
  let #(loaded, _) =
    app.update(initial, app.ReplayMsg(replay.SourceChanged(source)))
  let #(loaded, _) = app.update(loaded, app.ReplayMsg(replay.Load))
  should.equal(
    string.contains(element.to_string(app.view(loaded)), "replay-page"),
    True,
  )
  let #(next, _) = app.update(loaded, app.RouteChanged(app.Replay(None)))
  let #(stale, _) =
    app.update(next, app.SgfLoaded(loaded.page_version, Ok(source)))
  should.equal(stale.replay.replay, None)
  let #(fresh, _) =
    app.update(next, app.SgfLoaded(next.page_version, Ok(source)))
  should.not_equal(fresh.replay.replay, None)
}

pub fn replay_sgf_does_not_change_the_live_board_test() {
  let initial =
    app.initial_model(
      app.Replay(None),
      player_info.LoggedIn("Alice", "jwt"),
      "https://rtgo.test",
    )
  let #(loaded, _) =
    app.update(initial, app.SgfLoaded(initial.page_version, Ok(source)))
  let #(last, _) = app.update(loaded, app.ReplayMsg(replay.Seek("5")))
  should.equal(last.game, go.new_game(19))
  let assert Some(r) = last.replay.replay
  let assert Ok(frame) = list.last(r.frames)
  should.equal(replay.frame(last.replay), frame)
}
