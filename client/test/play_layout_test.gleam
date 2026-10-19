import gleam/dict
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
import rtgo_client/player_info
import rtgo_client/replay
import rtgo_shared/game
import rtgo_shared/go
import rtgo_shared/lobby_api
import rtgo_shared/play_api
import rtgo_shared/player

fn model() -> app.Model {
  let board = go.new_game(19)
  let settings = game.default_settings
  let details =
    lobby_api.GameDetails(
      "room",
      game.Started,
      "alice",
      ["alice", "bob"],
      2,
      settings,
      game.default_cooldowns(["alice", "bob"], settings),
      dict.from_list([#("alice", player.Black), #("bob", player.White)]),
    )
  let live =
    play_api.State(
      board,
      [
        play_api.PlayerStatus(
          player.Player("alice", player.Black),
          2500,
          12_500,
        ),
        play_api.PlayerStatus(player.Player("bob", player.White), 0, 2500),
      ],
      False,
      0,
      12_500,
      dict.new(),
      play_api.NotScored,
      [],
      dict.new(),
    )
  app.Model(
    ..app.initial_model(
      app.Play("room"),
      player_info.LoggedIn("alice", "jwt"),
      "https://rtgo.test",
    ),
    game: board,
    current_game: Some(details),
    live: Some(live),
  )
}

pub fn gameplay_chrome_is_in_the_circle_menu_not_in_board_layout_test() {
  let view = app.view(model())
  let assert Ok(board_page) =
    query.find(view, query.element(query.attribute("id", "play-page")))
  let html = element.to_string(board_page)
  should.equal(string.contains(html, "play-header"), False)
  should.equal(string.contains(html, "play-status"), False)
  should.equal(string.contains(html, "Back to lobby"), False)
  should.equal(string.contains(html, "countdown-bars"), True)
  let assert Ok(menu) =
    query.find(view, query.element(query.attribute("id", "menu")))
  let html = element.to_string(menu)
  should.equal(string.contains(html, "Back to lobby"), True)
  should.equal(string.contains(html, "Ready in 3s"), True)
  should.equal(string.contains(html, "alice (you)"), True)
  should.equal(
    string.contains(html, "Everyone passing ends the game in 13s"),
    True,
  )
}

pub fn only_your_timer_is_mirrored_on_both_board_edges_test() {
  let assert Ok(bars) =
    query.find(
      app.view(model()),
      query.element(query.attribute("id", "countdown-bars")),
    )
  let html = element.to_string(bars)
  should.equal(list.length(string.split(html, "class=\"countdown-bar ")), 3)
  should.equal(string.contains(html, "countdown-first"), True)
  should.equal(string.contains(html, "countdown-last"), True)
  should.equal(string.contains(html, "alice: Ready in 3s"), True)
  should.equal(string.contains(html, "aria-valuemax=\"5000\""), True)
  should.equal(string.contains(html, "aria-valuenow=\"2500\""), True)
  should.equal(string.contains(html, "--remaining:50%"), True)
  should.equal(string.contains(html, "bob"), False)
  should.equal(string.contains(html, "end-countdown"), False)
  should.equal(string.contains(html, "countdown-label"), False)
  // The mirror is decorative: announce the same timer only once.
  should.equal(list.length(string.split(html, "role=\"meter\"")), 2)
  should.equal(string.contains(html, "aria-hidden=\"true\""), True)
}

pub fn timer_follows_the_logged_in_player_and_their_handicap_test() {
  let initial = model()
  let bob = app.Model(..initial, player: player_info.LoggedIn("bob", "jwt"))
  // Bob is already ready: Alice's cooldown must not appear for him.
  should.equal(
    bob
      |> app.view
      |> element.to_string
      |> string.contains("id=\"countdown-bars\""),
    False,
  )

  let assert Some(details) = initial.current_game
  let handicapped =
    app.Model(
      ..initial,
      current_game: Some(
        lobby_api.GameDetails(
          ..details,
          cooldowns: dict.insert(details.cooldowns, "alice", 10),
        ),
      ),
    )
  let assert Ok(bars) =
    query.find(
      app.view(handicapped),
      query.element(query.attribute("id", "countdown-bars")),
    )
  let html = element.to_string(bars)
  should.equal(string.contains(html, "aria-valuemax=\"10000\""), True)
  should.equal(string.contains(html, "--remaining:25%"), True)
}

pub fn cooldown_bars_disappear_when_ready_regardless_of_pass_countdown_test() {
  let initial = model()
  let assert Some(live) = initial.live
  list.each([10_000, 2500, 0], fn(pass_in_ms) {
    let ready_state =
      play_api.State(
        ..live,
        players: list.map(live.players, fn(status) {
          play_api.PlayerStatus(
            ..status,
            cooldown_ms: 0,
            pass_in_ms: pass_in_ms,
          )
        }),
      )
    let #(ready, _) =
      app.update(
        initial,
        app.BoardLoaded(initial.page_version, Ok(ready_state)),
      )
    should.equal(
      ready
        |> app.view
        |> element.to_string
        |> string.contains("id=\"countdown-bars\""),
      False,
    )
  })
}

pub fn spectators_and_missing_live_state_have_no_timer_bars_test() {
  let initial = model()
  let spectator =
    app.Model(..initial, player: player_info.LoggedIn("spectator", "jwt"))
  should.equal(
    spectator
      |> app.view
      |> element.to_string
      |> string.contains("id=\"countdown-bars\""),
    False,
  )
  let loading = app.Model(..initial, live: None)
  should.equal(
    loading
      |> app.view
      |> element.to_string
      |> string.contains("id=\"countdown-bars\""),
    False,
  )
}

pub fn circle_popovers_toggle_for_touch_and_keyboard_and_reset_on_navigation_test() {
  let initial = model()
  let simulation =
    simulate.application(
      fn(_) { #(initial, effect.none()) },
      app.update,
      app.view,
    )
    |> simulate.start(Nil)
  let info = query.element(query.attribute("aria-label", "Game info: room"))
  let expanded =
    simulation |> simulate.event(info, "click", []) |> simulate.model
  should.equal(expanded.expanded_menu, Some("game"))
  should.equal(expanded.game, initial.game)
  let #(closed, _) = app.update(expanded, app.ToggleMenu("game"))
  should.equal(closed.expanded_menu, None)
  let #(player, _) = app.update(expanded, app.ToggleMenu("player-bob"))
  should.equal(player.expanded_menu, Some("player-bob"))
  let #(navigated, _) = app.update(player, app.RouteChanged(app.CreateJoinGame))
  should.equal(navigated.expanded_menu, None)
}

fn ranking_model(scoring: play_api.ScoringStatus, finished: Bool) -> app.Model {
  let initial = model()
  let assert Some(live) = initial.live
  app.Model(
    ..initial,
    live: Some(
      play_api.State(
        ..live,
        players: [
          play_api.PlayerStatus(player.Player("alice", player.Black), 0, 0),
          play_api.PlayerStatus(player.Player("charlie", player.Blue), 0, 0),
          play_api.PlayerStatus(player.Player("zeta", player.Green), 0, 0),
          play_api.PlayerStatus(player.Player("bob", player.White), 0, 0),
        ],
        scores: dict.from_list([#("zeta", 100), #("bob", 90), #("charlie", 90)]),
        scoring: scoring,
        finished: finished,
      ),
    ),
  )
}

pub fn final_results_and_player_circles_sort_by_points_then_name_test() {
  list.each([play_api.Estimated, play_api.Unavailable], fn(scoring) {
    let view = app.view(ranking_model(scoring, True))
    let assert Ok(results) =
      query.find(view, query.element(query.class("live-players")))
    let names =
      query.find_all(results, query.element(query.tag("strong")))
      |> list.map(element.to_string)
    should.equal(names, [
      "<strong>zeta</strong>",
      "<strong>bob</strong>",
      "<strong>charlie</strong>",
      "<strong>alice</strong>",
    ])
    let circles =
      query.find_all(view, query.element(query.class("player-icon")))
    should.equal(list.length(circles), 4)
    list.zip(circles, ["zeta", "bob", "charlie", "alice"])
    |> list.each(fn(entry) {
      should.equal(
        entry.0
          |> element.to_string
          |> string.contains("aria-label=\"" <> entry.1),
        True,
      )
    })
  })
}

pub fn player_order_stays_stable_during_play_and_pending_scoring_test() {
  list.each(
    [#(play_api.NotScored, False), #(play_api.Scoring, True)],
    fn(status) {
      let view = app.view(ranking_model(status.0, status.1))
      let assert Ok(results) =
        query.find(view, query.element(query.class("live-players")))
      let names =
        query.find_all(results, query.element(query.tag("strong")))
        |> list.map(element.to_string)
      should.equal(names, [
        "<strong>alice</strong>",
        "<strong>charlie</strong>",
        "<strong>zeta</strong>",
        "<strong>bob</strong>",
      ])
    },
  )
}

pub fn finished_game_keeps_full_board_and_puts_scores_in_menu_test() {
  let initial = model()
  let assert Some(live) = initial.live
  let finished =
    app.Model(
      ..initial,
      live: Some(
        play_api.State(
          ..live,
          finished: True,
          scores: dict.from_list([#("alice", 200), #("bob", 161)]),
          scoring: play_api.Estimated,
        ),
      ),
    )
  let view = app.view(finished)
  let assert Ok(page) =
    query.find(view, query.element(query.attribute("id", "play-page")))
  let page = element.to_string(page)
  should.equal(string.contains(page, "countdown-bars"), False)
  should.equal(string.contains(page, "id=\"board\""), True)
  let assert Ok(menu) =
    query.find(view, query.element(query.attribute("id", "menu")))
  should.equal(
    menu |> element.to_string |> string.contains("alice wins with 200 points."),
    True,
  )
  let menu = element.to_string(menu)
  should.equal(string.contains(menu, "href=\"/replay/room\""), False)
  should.equal(string.contains(menu, "Replay game"), False)
  should.equal(string.contains(menu, "https://rtgo.test/games/room/sgf"), True)
  should.equal(string.contains(menu, "Download SGF"), True)
}

const recording = "(;SZ[9]RTFORMAT[1]RTPLAYER[p1:alice:black:1000][p2:bob:white:1000]RTEND[3000]RTSCORING[unassisted]RTSCORE[p1:81][p2:0];RTMOVE[p1:aa]RTTIME[1000];RTMOVE[p2:cc]RTTIME[2000])"

pub fn finished_game_info_does_not_duplicate_replay_players_or_settings_test() {
  let initial = model()
  let assert Some(live) = initial.live
  let finished =
    play_api.State(
      ..live,
      finished: True,
      scoring: play_api.Unavailable,
      scores: dict.from_list([#("alice", 0), #("bob", 81)]),
    )
  let #(fetching, _) =
    app.update(initial, app.BoardLoaded(initial.page_version, Ok(finished)))
  let source =
    string.replace(recording, "RTSCORE[p1:81][p2:0]", "RTSCORE[p1:0][p2:81]")
  let #(loaded, _) =
    app.update(fetching, app.SgfLoaded(fetching.page_version, Ok(source)))
  let assert Ok(popup) =
    query.find(app.view(loaded), query.element(query.id("menu-panel-game")))
  let lists = query.find_all(popup, query.element(query.class("live-players")))
  should.equal(list.length(lists), 1)
  let assert Ok(players) = list.first(lists)
  let names =
    query.find_all(players, query.element(query.tag("strong")))
    |> list.map(element.to_string)
  should.equal(names, ["<strong>bob</strong>", "<strong>alice</strong>"])
  let html = element.to_string(popup)
  should.equal(string.contains(html, "bob wins with 81 points."), True)
  should.equal(string.contains(html, "Space: play / pause"), True)
  should.equal(string.contains(html, "bob · cc · 2.000s"), True)
  should.equal(string.contains(html, "<h2>Replay</h2>"), False)
  should.equal(string.contains(html, "1s cooldown"), False)
}

pub fn finished_game_automatically_loads_replay_without_navigation_test() {
  let initial = model()
  let assert Some(live) = initial.live
  let finished =
    play_api.State(..live, finished: True, scoring: play_api.Unavailable)
  let #(fetching, _) =
    app.update(initial, app.BoardLoaded(initial.page_version, Ok(finished)))
  should.equal(fetching.loading_game, True)
  let #(loaded, _) =
    app.update(fetching, app.SgfLoaded(fetching.page_version, Ok(recording)))
  should.equal(loaded.route, app.Play("room"))
  should.equal(loaded.replay.index, 2)
  should.equal(loaded.replay.playing, False)
  let assert Ok(page) =
    query.find(
      app.view(loaded),
      query.element(query.attribute("id", "play-page")),
    )
  let html = element.to_string(page)
  should.equal(string.contains(html, "replay-controls"), True)
  should.equal(string.contains(html, "playable"), False)
  should.equal(string.contains(html, "territory-point"), True)
  let #(first, _) = app.update(loaded, app.ReplayMsg(replay.Start))
  should.equal(dict.size(replay.frame(first.replay).board.stones), 0)
  should.equal(first.game, finished.board)
  should.equal(
    string.contains(element.to_string(app.view(first)), "territory-point"),
    False,
  )
  let #(unchanged, _) = app.update(first, app.BoardRefresh(first.page_version))
  should.equal(unchanged.loading_board, False)
}

pub fn replay_is_available_during_scoring_and_final_score_keeps_playback_position_test() {
  let initial = model()
  let assert Some(live) = initial.live
  let pending =
    play_api.State(..live, finished: True, scoring: play_api.Scoring)
  let #(fetching, _) =
    app.update(initial, app.BoardLoaded(initial.page_version, Ok(pending)))
  should.equal(fetching.loading_game, True)
  let pending_recording =
    recording
    |> string.replace("RTSCORING[unassisted]", "RTSCORING[pending]")
    |> string.replace("RTSCORE[p1:81][p2:0]", "")
  let #(loaded, _) =
    app.update(
      fetching,
      app.SgfLoaded(fetching.page_version, Ok(pending_recording)),
    )
  should.equal(
    string.contains(element.to_string(app.view(loaded)), "replay-controls"),
    True,
  )
  let #(playing, _) = app.update(loaded, app.ReplayMsg(replay.TogglePlayback))
  let assert Some(now) = playing.replay.last_tick
  let #(playing, _) =
    app.update(
      playing,
      app.ReplayTick(
        playing.page_version,
        playing.replay.generation,
        timestamp.add(now, duration.milliseconds(1500)),
      ),
    )
  should.equal(playing.replay.index, 1)
  let scored = play_api.State(..pending, scoring: play_api.Unavailable)
  let #(fetching, _) =
    app.update(playing, app.BoardLoaded(playing.page_version, Ok(scored)))
  should.equal(fetching.loading_game, True)
  let #(updated, _) =
    app.update(fetching, app.SgfLoaded(fetching.page_version, Ok(recording)))
  should.equal(updated.replay.index, 1)
  should.equal(updated.replay.playing, True)
  should.equal(updated.replay.clock_ms, 1500)
  should.equal(updated.replay.generation, playing.replay.generation)
  let assert Some(replay) = updated.replay.replay
  should.equal(replay.record.scoring, "unassisted")
}

pub fn failed_recording_load_keeps_the_finished_board_visible_test() {
  let initial = model()
  let assert Some(live) = initial.live
  let finished =
    play_api.State(..live, finished: True, scoring: play_api.Unavailable)
  let #(fetching, _) =
    app.update(initial, app.BoardLoaded(initial.page_version, Ok(finished)))
  let #(failed, _) =
    app.update(
      fetching,
      app.SgfLoaded(fetching.page_version, Error(rsvp.NetworkError)),
    )
  should.equal(failed.loading_game, False)
  should.not_equal(failed.replay.error, None)
  should.equal(failed.live, Some(finished))
  should.equal(
    string.contains(element.to_string(app.view(failed)), "id=\"board\""),
    True,
  )
}
