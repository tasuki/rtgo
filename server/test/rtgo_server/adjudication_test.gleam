import gleam/dict
import gleam/list
import gleam/set
import gleam/string
import gleeunit/should
import rtgo_server/adjudication
import rtgo_server/game
import rtgo_server/katago
import rtgo_shared/game as settings
import rtgo_shared/go
import rtgo_shared/play_api
import rtgo_shared/player

fn ownership(values: List(#(go.Point, Float))) -> dict.Dict(go.Point, Float) {
  dict.from_list(values)
}

pub fn uses_real_multiplayer_groups_and_each_groups_own_perspective_test() {
  let board =
    go.Game(
      ..go.new_game(9),
      stones: dict.from_list([
        #(#(2, 2), player.Player("green", player.Green)),
        #(#(2, 3), player.Player("green", player.Green)),
        // Touching blue must not merge with green as it does in a projection.
        #(#(3, 2), player.Player("blue", player.Blue)),
        #(#(7, 7), player.Player("green", player.Green)),
      ]),
    )
  let estimates =
    dict.from_list([
      #(
        "green",
        ownership([#(#(2, 2), -0.99), #(#(2, 3), -0.99), #(#(7, 7), 0.99)]),
      ),
      #("blue", ownership([#(#(3, 2), 0.99), #(#(2, 2), 0.99)])),
    ])
  should.equal(
    adjudication.dead_stones(board, estimates) |> set.from_list,
    set.from_list([#(2, 2), #(2, 3)]),
  )
}

pub fn ambiguous_seki_or_positive_ownership_groups_are_not_removed_test() {
  let a = #(2, 2)
  let b = #(2, 3)
  let board =
    go.Game(
      ..go.new_game(9),
      stones: dict.from_list([
        #(a, player.Player("white", player.White)),
        #(b, player.Player("white", player.White)),
      ]),
    )
  list.each(
    [
      // One doubtful stone keeps the entire group.
      ownership([#(a, -0.99), #(b, -0.59)]),
      ownership([#(a, 0.0), #(b, 0.0)]),
      ownership([#(a, 0.99), #(b, 0.99)]),
      // Missing data is never a death verdict.
      ownership([#(a, -0.99)]),
    ],
    fn(estimate) {
      should.equal(
        adjudication.dead_stones(board, dict.from_list([#("white", estimate)])),
        [],
      )
    },
  )
  should.equal(adjudication.dead_stones(board, dict.new()), [])
}

pub fn relaxed_cutoff_is_inclusive_and_still_applies_to_every_stone_test() {
  let a = #(2, 2)
  let b = #(2, 3)
  let white = player.Player("white", player.White)
  let board =
    go.Game(
      ..go.new_game(9),
      stones: dict.from_list([#(a, white), #(b, white)]),
    )
  list.each(
    [
      #(-0.6, -0.6, True),
      #(-0.8, -0.7, True),
      #(-0.99, -0.599, False),
    ],
    fn(values) {
      let estimates =
        dict.from_list([
          #("white", ownership([#(a, values.0), #(b, values.1)])),
        ])
      let expected = case values.2 {
        True -> set.from_list([a, b])
        False -> set.new()
      }
      should.equal(
        adjudication.dead_stones(board, estimates) |> set.from_list,
        expected,
      )
    },
  )
}

pub fn relaxed_cutoff_still_requires_complete_and_negative_data_test() {
  let a = #(2, 2)
  let b = #(2, 3)
  let white = player.Player("white", player.White)
  let board =
    go.Game(
      ..go.new_game(9),
      stones: dict.from_list([#(a, white), #(b, white)]),
    )
  let uncertain = dict.from_list([#(a, -0.8), #(b, -0.59)])
  let missing = dict.from_list([#(a, -0.8)])
  list.each([uncertain, missing], fn(estimate) {
    should.equal(
      adjudication.dead_stones(board, dict.from_list([#("white", estimate)])),
      [],
    )
  })
}

// Exact final board from hury / Screenshot From 2026-10-17 23-18-29.png.
// B black, W white, O orange, V purple, P pink, G green, U blue, C cyan.
pub fn screenshot_position() -> go.Game {
  let rows = [
    "OBBBB.O.BBBBBBBBBO.",
    "OOBOBBBBB.BVBBBOOOO",
    ".OOOOBB.BBVVVCBO.OO",
    "O.OOOB.B.BBVVCCOOOC",
    ".OPOBBBBBVVVVCCOCCC",
    "O..OOOVVVVV.VCCCC.C",
    "OOO.OPPPPV.VVCCCCCC",
    "BBO.OPP.PVVVVC.CCUC",
    "B.BOOPO.PVPPPCCCUUU",
    ".BBBOOPPPPP.PCCCUU.",
    "BBBOOOP.PPPPPPCUU.U",
    "OBOOOP.P.PP.PCCU.U.",
    "OO.OP.P.PPPPUCUUU.U",
    "WOOOPPPPPUUPUUUUUUG",
    "WWWWWPPPUUUUUGGGGUG",
    ".WWWGGPGUUUGUUGGGGG",
    "WWWGGGGGGUGGGGG..GG",
    "W.WGGWWG.GG....GGGB",
    ".WWWWWGGG.GGGGGG.G.",
  ]
  let colors =
    dict.from_list([
      #("B", player.Black),
      #("W", player.White),
      #("O", player.Orange),
      #("V", player.Purple),
      #("P", player.Pink),
      #("G", player.Green),
      #("U", player.Blue),
      #("C", player.Cyan),
    ])
  let stones =
    rows
    |> list.index_map(fn(row, y) {
      row
      |> string.to_graphemes
      |> list.index_map(fn(symbol, x) { #(#(x, y), symbol) })
      |> list.filter_map(fn(entry) {
        case dict.get(colors, entry.1) {
          Ok(color) -> Ok(#(entry.0, player.Player(entry.1, color)))
          Error(_) -> Error(Nil)
        }
      })
    })
    |> list.flatten
    |> dict.from_list
  go.Game(..go.new_game(19), stones: stones)
}

fn assert_screenshot_scoring(
  board: go.Game,
  estimate: dict.Dict(go.Point, Float),
) {
  let dead = adjudication.dead_stones(board, dict.from_list([#("O", estimate)]))
  should.equal(list.contains(dead, #(6, 8)), True)
  should.equal(
    list.all(dead, fn(point) { list.contains([#(6, 8), #(6, 0)], point) }),
    True,
  )
  // Keep the three stones already adjudicated dead in the screenshot excluded.
  let scoring = go.remove_stones(board, [#(2, 4), #(18, 17), #(6, 0), ..dead])
  // G11 and the two newly unblocked empty points belong to pink, not orange.
  should.equal(
    dict.get(go.area(scoring), #(6, 8)),
    Ok(player.Player("P", player.Pink)),
  )
  should.equal(dict.get(go.score(scoring), "O"), Ok(64))
  should.equal(dict.get(go.score(scoring), "P"), Ok(56))
  should.equal(
    dict.get(board.stones, #(6, 8)),
    Ok(player.Player("O", player.Orange)),
  )
}

pub fn screenshot_enclosed_orange_stone_regression_test() {
  let board = screenshot_position()
  let point = #(6, 8)
  // G11: isolated orange stone inside pink territory. Recorded single-visit
  // own-turn outputs all identify it as dead without a second-turn veto.
  list.each(
    [
      -0.988517, -0.991575, -0.988132, -0.993168, -0.988132, -0.988132,
      -0.988517, -0.988202,
    ],
    fn(value) {
      assert_screenshot_scoring(board, dict.from_list([#(point, value)]))
    },
  )
}

pub fn screenshot_enclosed_orange_stone_with_engine_when_installed_test() {
  // Unit coverage above also runs on hosts without the production engine.
  case katago.available() {
    False -> Nil
    True -> {
      let board = screenshot_position()
      let assert Ok(ownership) = katago.ownership(board, "O")
      assert_screenshot_scoring(board, ownership)
    }
  }
}

pub fn final_position() -> game.State {
  let black = player.Player("black", player.Black)
  let white = player.Player("white", player.White)
  let ring =
    list.range(1, 4)
    |> list.flat_map(fn(x) {
      list.range(1, 4)
      |> list.filter_map(fn(y) {
        case x == 1 || x == 4 || y == 1 || y == 4 {
          True -> Ok(#(#(x, y), black))
          False -> Error(Nil)
        }
      })
    })
  let assert Ok(board) = go.play(go.new_game(9), white, #(2, 2))
  let board =
    list.fold(ring, board, fn(board, entry) {
      let assert Ok(board) = go.play(board, entry.1, entry.0)
      board
    })
  let state =
    game.new_state(
      dict.from_list([#("black", black), #("white", white)]),
      settings.Settings(9, settings.TwoPlayerGame, settings.Cooldown(1)),
      dict.new(),
      0,
    )
  game.advance(game.State(..state, board: board), 10_000)
}

pub fn adjudication_scores_a_copy_and_leaves_final_board_and_history_intact_test() {
  let pending = final_position()
  let live = game.snapshot_at(pending, 10_000).live
  should.equal(live.finished, True)
  should.equal(live.scoring, play_api.Scoring)
  should.equal(live.scores, dict.new())
  let scored = game.finish_scoring(pending, Ok([#(2, 2)]))
  should.equal(scored.scoring, play_api.Estimated)
  should.equal(scored.dead_stones, [#(2, 2)])
  should.equal(scored.board, pending.board)
  should.equal(set.size(scored.board.history), 14)
  should.equal(dict.get(scored.scores, "black"), Ok(81))
  should.equal(dict.get(scored.scores, "white"), Error(Nil))
  should.equal(scored.revision, pending.revision + 1)
  should.equal(
    game.play_at(scored, "white", #(0, 0), 10_001),
    Error(game.GameFinished),
  )
  // Duplicate replies or the deadline firing after success cannot change it.
  should.equal(game.finish_scoring(scored, Error(Nil)), scored)
  should.equal(game.finish_scoring(scored, Ok([])), scored)
}

pub fn removal_keeps_real_multiplayer_area_and_shared_borders_neutral_test() {
  let pending = final_position()
  let blue = player.Player("blue", player.Blue)
  let pending =
    game.State(
      ..pending,
      board: go.Game(
        ..pending.board,
        stones: dict.insert(pending.board.stones, #(8, 8), blue),
      ),
      players: dict.insert(pending.players, "blue", blue),
      ready_at: dict.insert(pending.ready_at, "blue", 0),
    )
  let scored = game.finish_scoring(pending, Ok([#(2, 2)]))
  should.equal(scored.scores, dict.from_list([#("black", 16), #("blue", 1)]))
  should.equal(scored.board, pending.board)
}

pub fn engine_failure_is_explicit_and_never_removes_partial_results_test() {
  let pending = final_position()
  let fallback = game.finish_scoring(pending, Error(Nil))
  should.equal(fallback.scoring, play_api.Unavailable)
  should.equal(fallback.scores, go.score(pending.board))
  should.equal(fallback.dead_stones, [])
  should.equal(fallback.board, pending.board)
  // A worker that finishes after its deadline cannot overwrite the fallback.
  should.equal(game.finish_scoring(fallback, Ok([#(2, 2)])), fallback)
  let playing =
    game.State(..pending, phase: settings.Started, scoring: play_api.NotScored)
  should.equal(game.finish_scoring(playing, Ok([#(2, 2)])), playing)
}

pub fn empty_board_needs_no_engine_and_has_no_dead_stones_test() {
  should.equal(adjudication.estimate(go.new_game(9)), Ok([]))
}
