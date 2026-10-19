import gleam/dict
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import lustre/dev/query
import lustre/dev/simulate
import lustre/effect
import lustre/element
import rsvp
import rtgo_client as app
import rtgo_client/board
import rtgo_client/player_info
import rtgo_client/replay
import rtgo_shared/go

const source = "(;FF[4]SZ[9]RTFORMAT[1]RTPLAYER[p1:Alice:black:1000][p2:Bob:white:2000][p3:Carol:cyan:1000]RTEND[13000]RTSCORING[estimated]RTSCORE[p1:81][p2:0][p3:0]RTDEAD[cb];RTMOVE[p2:bb]RTTIME[0];RTMOVE[p1:ab]RTTIME[0];RTMOVE[p1:ba]RTTIME[1000];RTMOVE[p3:cb]RTTIME[1000];RTMOVE[p1:bc]RTTIME[2000])"

fn board_view(model: replay.Model) {
  board.fullscreen(replay.board_view(model), [replay.controls(model)])
}

fn keyboard_model() -> app.Model {
  app.Model(
    ..app.initial_model(
      app.Play("room"),
      player_info.LoggedIn("Alice", "jwt"),
      "https://rtgo.test",
    ),
    replay: replay.load(replay.new(), source),
  )
}

pub fn replay_shortcuts_navigate_and_toggle_playback_test() {
  let initial = keyboard_model()
  let root = query.element(query.attribute("id", "container"))
  let simulation =
    simulate.application(
      fn(_) { #(initial, effect.none()) },
      app.update,
      app.view,
    )
    |> simulate.start(Nil)
  let next =
    simulation
    |> simulate.event(root, "keydown", [#("key", json.string("ArrowRight"))])
  should.equal(simulate.model(next).replay.index, 1)
  let previous =
    next
    |> simulate.event(root, "keydown", [#("key", json.string("ArrowLeft"))])
  should.equal(simulate.model(previous).replay.index, 0)
  let playing =
    previous |> simulate.event(root, "keydown", [#("key", json.string(" "))])
  should.equal(simulate.model(playing).replay.playing, True)
  let stopped =
    playing |> simulate.event(root, "keydown", [#("key", json.string(" "))])
  should.equal(simulate.model(stopped).replay.playing, False)
  let stepped =
    playing
    |> simulate.event(root, "keydown", [
      #("key", json.string("ArrowRight")),
      #("repeat", json.bool(True)),
    ])
  should.equal(simulate.model(stepped).replay.index, 1)
  should.equal(simulate.model(stepped).replay.playing, False)
  let slider_target = #(
    "target",
    json.object([
      #("tagName", json.string("INPUT")),
      #("id", json.string("replay-seek")),
    ]),
  )
  let slider_next =
    simulation
    |> simulate.event(root, "keydown", [
      #("key", json.string("ArrowRight")),
      slider_target,
    ])
  should.equal(simulate.model(slider_next).replay.index, 1)
  let slider_playing =
    slider_next
    |> simulate.event(root, "keydown", [
      #("key", json.string(" ")),
      slider_target,
    ])
  should.equal(simulate.model(slider_playing).replay.playing, True)
  let held_space =
    slider_playing
    |> simulate.event(root, "keydown", [
      #("key", json.string(" ")),
      #("repeat", json.bool(True)),
      slider_target,
    ])
  should.equal(simulate.model(held_space).replay.playing, True)
  let html = element.to_string(app.view(initial))
  should.equal(string.contains(html, "tabindex=\"-1\""), True)
  should.equal(string.contains(html, "autofocus"), True)
}

pub fn replay_shortcuts_leave_editing_modifiers_and_native_activation_alone_test() {
  let initial = keyboard_model()
  let root = query.element(query.attribute("id", "container"))
  let simulation =
    simulate.application(
      fn(_) { #(initial, effect.none()) },
      app.update,
      app.view,
    )
    |> simulate.start(Nil)
  let ignored = [
    [#("key", json.string("ArrowDown"))],
    [#("key", json.string("ArrowRight")), #("ctrlKey", json.bool(True))],
    [#("key", json.string("ArrowRight")), #("altKey", json.bool(True))],
    [#("key", json.string("ArrowRight")), #("metaKey", json.bool(True))],
    [#("key", json.string("ArrowRight")), #("shiftKey", json.bool(True))],
    [#("key", json.string("ArrowRight")), #("isComposing", json.bool(True))],
    [
      #("key", json.string("ArrowRight")),
      #("defaultPrevented", json.bool(True)),
    ],
    [#("key", json.string(" ")), #("repeat", json.bool(True))],
  ]
  list.each(ignored, fn(fields) {
    should.equal(
      simulation |> simulate.event(root, "keydown", fields) |> simulate.model,
      initial,
    )
  })
  list.each(["INPUT", "TEXTAREA", "SELECT"], fn(tag) {
    list.each(["ArrowLeft", "ArrowRight", " "], fn(key) {
      should.equal(
        simulation
          |> simulate.event(root, "keydown", [
            #("key", json.string(key)),
            #("target", json.object([#("tagName", json.string(tag))])),
          ])
          |> simulate.model,
        initial,
      )
    })
  })
  list.each(["BUTTON", "A", "SUMMARY"], fn(tag) {
    should.equal(
      simulation
        |> simulate.event(root, "keydown", [
          #("key", json.string(" ")),
          #("target", json.object([#("tagName", json.string(tag))])),
        ])
        |> simulate.model,
      initial,
    )
  })
  should.equal(
    simulation
      |> simulate.event(root, "keydown", [
        #("key", json.string("ArrowRight")),
        #(
          "target",
          json.object([
            #("tagName", json.string("SPAN")),
            #("isContentEditable", json.bool(True)),
          ]),
        ),
      ])
      |> simulate.model,
    initial,
  )
  let #(live, _) = app.update(initial, app.RouteChanged(app.Play("live")))
  let live_simulation =
    simulate.application(fn(_) { #(live, effect.none()) }, app.update, app.view)
    |> simulate.start(Nil)
  should.equal(
    live_simulation
      |> simulate.event(root, "keydown", [#("key", json.string(" "))])
      |> simulate.model,
    live,
  )
}

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
  let start = board_view(loaded) |> element.to_string
  should.equal(string.contains(start, "playable"), False)
  should.equal(string.contains(start, "territory-point"), False)
  let info = replay.information(loaded) |> element.to_string
  should.equal(string.contains(info, "Bob"), True)
  should.equal(string.contains(info, "2s cooldown"), True)
  should.equal(string.contains(start, "id=\"play-page\""), True)
  should.equal(string.contains(start, "id=\"board\""), True)
  should.equal(string.contains(start, "replay-controls"), True)
  should.equal(string.contains(start, "2s cooldown"), False)
  let last =
    replay.update(loaded, replay.Seek("5"))
    |> board_view
    |> element.to_string
  should.equal(string.contains(last, "dead-stone"), True)
  should.equal(string.contains(last, "territory-point"), True)
  should.equal(string.contains(info, "81 points"), True)
  should.equal(string.contains(info, "0 points"), True)
  should.equal(string.contains(last, "Alice · bc · 2.000s"), True)
}

pub fn imported_and_archived_game_info_lists_each_player_once_by_points_test() {
  let source =
    source
    |> string.replace(
      "RTPLAYER[p1:Alice:black:1000][p2:Bob:white:2000][p3:Carol:cyan:1000]",
      "RTPLAYER[p3:Carol:cyan:1000][p2:Bob:white:2000][p1:Alice:black:1000]",
    )
    |> string.replace("RTSCORE[p1:81][p2:0][p3:0]", "RTSCORE[p1:0][p2:5][p3:5]")
  list.each([app.CreateJoinGame, app.Play("archive")], fn(route) {
    let initial =
      app.initial_model(
        route,
        player_info.OtherError("Offline"),
        "https://rtgo.test",
      )
    let loaded = app.Model(..initial, replay: replay.load(replay.new(), source))
    let assert Ok(popup) =
      query.find(app.view(loaded), query.element(query.id("menu-panel-game")))
    let lists = query.find_all(popup, query.element(query.tag("ul")))
    should.equal(list.length(lists), 1)
    let assert Ok(players) =
      query.find(popup, query.element(query.class("live-players")))
    let names =
      query.find_all(players, query.element(query.tag("strong")))
      |> list.map(element.to_string)
    should.equal(names, [
      "<strong>Bob</strong>",
      "<strong>Carol</strong>",
      "<strong>Alice</strong>",
    ])
    let scores =
      query.find_all(players, query.element(query.class("player-score")))
      |> list.map(element.to_string)
    should.equal(scores, [
      "<span class=\"player-score\">5 points</span>",
      "<span class=\"player-score\">5 points</span>",
      "<span class=\"player-score\">0 points</span>",
    ])
    let rows = query.find_all(players, query.element(query.tag("li")))
    should.equal(list.length(rows), 3)
  })
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
      element.to_string(replay.information(invalid)),
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
      element.to_string(replay.information(loaded)),
      "Unfinished recording",
    ),
    True,
  )
}

pub fn replay_is_accessible_without_login_and_old_requests_are_ignored_test() {
  let initial =
    app.initial_model(
      app.CreateJoinGame,
      player_info.OtherError("No server"),
      "https://rtgo.test",
    )
  let lobby = element.to_string(app.view(initial))
  should.equal(string.contains(lobby, "Import an SGF recording"), True)
  should.equal(string.contains(lobby, "id=\"sgf-source\""), True)
  should.equal(string.contains(lobby, "href=\"/replay"), False)
  let #(loaded, _) =
    app.update(initial, app.ReplayMsg(replay.SourceChanged(source)))
  let #(loaded, _) = app.update(loaded, app.ReplayMsg(replay.Load))
  should.equal(
    string.contains(element.to_string(app.view(loaded)), "id=\"play-page\""),
    True,
  )
  should.equal(loaded.route, app.CreateJoinGame)
  should.equal(loaded.page_version, initial.page_version + 1)
  let #(no_poll, _) = app.update(loaded, app.Refresh(loaded.page_version))
  should.equal(no_poll, loaded)
  let #(back, _) = app.update(loaded, app.BackToLobby)
  should.equal(back.route, app.CreateJoinGame)
  should.equal(back.replay.replay, None)
  should.equal(
    string.contains(element.to_string(app.view(back)), "id=\"sgf-source\""),
    True,
  )
  let #(next, _) = app.update(loaded, app.RouteChanged(app.Play("other")))
  let #(stale, _) =
    app.update(next, app.SgfLoaded(loaded.page_version, Ok(source)))
  should.equal(stale.replay.replay, None)
  let #(fresh, _) =
    app.update(next, app.SgfLoaded(next.page_version, Ok(source)))
  should.not_equal(fresh.replay.replay, None)
}

pub fn lobby_import_errors_remain_inline_without_opening_a_board_test() {
  let initial =
    app.initial_model(
      app.CreateJoinGame,
      player_info.LoggedIn("Alice", "jwt"),
      "https://rtgo.test",
    )
  let lobby = element.to_string(app.view(initial))
  should.equal(string.contains(lobby, "Import an SGF recording"), True)
  should.equal(string.contains(lobby, "href=\"/replay"), False)
  let #(draft, _) =
    app.update(initial, app.ReplayMsg(replay.SourceChanged("bad sgf")))
  let #(failed, _) = app.update(draft, app.ReplayMsg(replay.Load))
  should.equal(failed.replay.replay, None)
  should.equal(failed.page_version, initial.page_version)
  let html = element.to_string(app.view(failed))
  should.equal(string.contains(html, "role=\"alert\""), True)
  should.equal(string.contains(html, "id=\"play-page\""), False)
  should.equal(string.contains(html, "id=\"sgf-source\""), True)
}

pub fn replay_sgf_does_not_change_the_live_board_test() {
  let initial =
    app.initial_model(
      app.Play("room"),
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

fn tick_after(model: replay.Model, milliseconds: Int) -> replay.Model {
  let assert Some(previous) = model.last_tick
  replay.update(
    model,
    replay.Tick(
      model.generation,
      timestamp.add(previous, duration.milliseconds(milliseconds)),
    ),
  )
}

pub fn realtime_playback_preserves_timestamps_and_catches_up_test() {
  let playing =
    replay.load(replay.new(), source) |> replay.update(replay.TogglePlayback)
  should.equal(playing.playing, True)
  let initial_moves = tick_after(playing, 0)
  should.equal(initial_moves.index, 2)
  should.equal(tick_after(initial_moves, 999).index, 2)
  let same_time_moves = tick_after(initial_moves, 1000)
  should.equal(same_time_moves.index, 4)
  let finished = tick_after(same_time_moves, 1000)
  should.equal(finished.index, 5)
  should.equal(finished.playing, False)
  let catch_up = tick_after(playing, 10_000)
  should.equal(catch_up.index, 5)
  should.equal(catch_up.playing, False)
}

pub fn stop_resume_seek_and_restart_invalidate_old_ticks_test() {
  let playing =
    replay.load(replay.new(), source) |> replay.update(replay.TogglePlayback)
  let halfway = tick_after(playing, 500)
  let stopped = replay.update(halfway, replay.TogglePlayback)
  should.equal(stopped.playing, False)
  should.equal(stopped.clock_ms, 500)
  let resumed = replay.update(stopped, replay.TogglePlayback)
  should.equal(resumed.clock_ms, 500)
  should.equal(tick_after(resumed, 499).index, 2)
  should.equal(tick_after(resumed, 500).index, 4)
  let assert Some(now) = resumed.last_tick
  should.equal(
    replay.update(resumed, replay.Tick(playing.generation, now)),
    resumed,
  )
  let sought = replay.update(resumed, replay.Seek("3"))
  should.equal(sought.index, 3)
  should.equal(sought.clock_ms, 1000)
  should.equal(sought.playing, False)
  should.equal(
    replay.update(sought, replay.Tick(resumed.generation, now)),
    sought,
  )
  let at_end = replay.update(sought, replay.End)
  let restarted = replay.update(at_end, replay.TogglePlayback)
  should.equal(restarted.index, 0)
  should.equal(restarted.clock_ms, 0)
  should.equal(restarted.playing, True)
}

pub fn controls_have_five_accessible_buttons_and_a_move_slider_test() {
  let loaded = replay.load(replay.new(), source)
  let view = board_view(loaded)
  let buttons = query.find_all(view, query.element(query.tag("button")))
  should.equal(list.length(buttons), 5)
  list.each(["Start", "Previous", "Play", "Next", "End"], fn(label) {
    let assert Ok(_) =
      query.find(view, query.element(query.attribute("aria-label", label)))
  })
  let assert Ok(slider) =
    query.find(view, query.element(query.attribute("id", "replay-seek")))
  should.equal(string.contains(element.to_string(slider), "max=\"5\""), True)
  let playing = replay.update(loaded, replay.TogglePlayback) |> board_view
  let assert Ok(_) =
    query.find(playing, query.element(query.attribute("aria-label", "Stop")))
  let empty =
    replay.load(
      replay.new(),
      "(;SZ[9]RTFORMAT[1]RTPLAYER[p1:A:black:1000][p2:B:white:1000])",
    )
  should.equal(replay.update(empty, replay.TogglePlayback).playing, False)
}

pub fn archived_game_opens_at_the_final_position_at_its_original_url_test() {
  let initial =
    app.initial_model(
      app.Play("archived"),
      player_info.OtherError("Offline"),
      "https://rtgo.test",
    )
  let #(fallback, _) =
    app.update(
      initial,
      app.GameLoaded(
        initial.page_version,
        Error(rsvp.HttpError(response.new(404) |> response.set_body(""))),
      ),
    )
  should.equal(fallback.loading_game, True)
  let #(loaded, _) =
    app.update(fallback, app.SgfLoaded(fallback.page_version, Ok(source)))
  should.equal(loaded.route, app.Play("archived"))
  should.equal(loaded.replay.index, 5)
  let view = app.view(loaded) |> element.to_string
  should.equal(string.contains(view, "replay-controls"), True)
  should.equal(string.contains(view, "id=\"play-page\""), True)
  should.equal(string.contains(view, "Download SGF"), True)
  let #(playing, _) = app.update(loaded, app.ReplayMsg(replay.TogglePlayback))
  let #(navigated, _) =
    app.update(playing, app.RouteChanged(app.CreateJoinGame))
  let #(stale, _) =
    app.update(
      navigated,
      app.ReplayTick(
        playing.page_version,
        playing.replay.generation,
        timestamp.system_time(),
      ),
    )
  should.equal(stale, navigated)
}
