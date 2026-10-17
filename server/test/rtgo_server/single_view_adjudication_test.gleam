// Regression coverage for production's one-evaluation-per-player scoring.
// With KataGo installed, the position suite runs as part of the normal tests.
// This module's main also repeats it 20 times with a fresh engine each time
// so randomized orientations are exercised rather than reusing one prediction.
import gleam/dict
import gleam/erlang/atom
import gleam/io
import gleam/list
import gleam/set
import gleeunit/should
import rtgo_server/adjudication
import rtgo_server/adjudication_test as fixtures
import rtgo_server/katago
import rtgo_shared/go
import rtgo_shared/player

@external(erlang, "gen_server", "stop")
fn stop_engine(name: atom.Atom) -> atom.Atom

pub fn whole_groups_cutoff_missing_data_and_multiplayer_identity_test() {
  let a = #(2, 2)
  let b = #(2, 3)
  let c = #(3, 2)
  let isolated = #(7, 7)
  let green = player.Player("green", player.Green)
  let blue = player.Player("blue", player.Blue)
  let board =
    go.Game(
      ..go.new_game(9),
      stones: dict.from_list([
        #(a, green),
        #(b, green),
        #(c, blue),
        #(isolated, green),
      ]),
    )
  list.each(
    [
      #(-0.6, -0.6, True),
      #(-0.8, -0.7, True),
      #(-0.99, -0.599, False),
      #(0.0, 0.0, False),
    ],
    fn(values) {
      let estimates =
        dict.from_list([
          #(
            "green",
            dict.from_list([#(a, values.0), #(b, values.1), #(isolated, 0.99)]),
          ),
          // A different player's opinion of green must not affect green's verdict.
          #("blue", dict.from_list([#(a, 0.99), #(b, 0.99), #(c, 0.99)])),
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
  should.equal(adjudication.dead_stones(board, dict.new()), [])
  should.equal(
    adjudication.dead_stones(
      board,
      dict.from_list([
        #("green", dict.from_list([#(a, -0.99)])),
      ]),
    ),
    [],
  )
}

pub fn owners_single_view_is_sufficient_without_opponent_estimates_test() {
  let a = #(2, 2)
  let b = #(2, 3)
  let white = player.Player("white", player.White)
  let board =
    go.Game(
      ..go.new_game(9),
      stones: dict.from_list([
        #(a, white),
        #(b, white),
        #(#(7, 7), player.Player("black", player.Black)),
      ]),
    )
  let dead = dict.from_list([#(a, -0.8), #(b, -0.7)])
  should.equal(
    adjudication.dead_stones(board, dict.from_list([#("white", dead)]))
      |> set.from_list,
    set.from_list([a, b]),
  )
  // With no black estimate, black stays; no opponent or other-turn query is
  // required to adjudicate white. Uncertain white ownership still stays.
  let uncertain = dict.from_list([#(a, -0.8), #(b, -0.59)])
  should.equal(
    adjudication.dead_stones(board, dict.from_list([#("white", uncertain)])),
    [],
  )
}

// Two opposing connected groups, no eyes, and exactly two shared liberties.
// Whoever fills either liberty first loses their entire group on the next move.
fn seki_position() -> go.Game {
  let stones =
    list.range(0, 8)
    |> list.flat_map(fn(y) {
      list.range(0, 8)
      |> list.filter_map(fn(x) {
        case #(x, y) == #(2, 4) || #(x, y) == #(6, 4) {
          True -> Error(Nil)
          False -> {
            let p = case y < 4 || y == 4 && x < 4 {
              True -> player.Player("black", player.Black)
              False -> player.Player("white", player.White)
            }
            Ok(#(#(x, y), p))
          }
        }
      })
    })
    |> dict.from_list
  go.Game(..go.new_game(9), stones: stones)
}

// Black at (1,1) has one liberty at (1,2). Extending there connects it to a
// solid black group with two eyes at (1,4) and (3,4), so it can certainly escape.
fn escapable_atari_position() -> go.Game {
  let black = player.Player("black", player.Black)
  let white = player.Player("white", player.White)
  let base =
    list.range(0, 4)
    |> list.flat_map(fn(x) {
      list.range(3, 5)
      |> list.filter_map(fn(y) {
        case #(x, y) == #(1, 4) || #(x, y) == #(3, 4) {
          True -> Error(Nil)
          False -> Ok(#(#(x, y), black))
        }
      })
    })
  go.Game(
    ..go.new_game(9),
    stones: dict.from_list([
      #(#(1, 1), black),
      #(#(0, 1), white),
      #(#(1, 0), white),
      #(#(2, 1), white),
      ..base
    ]),
  )
}

pub fn seki_fixture_has_two_shared_liberties_and_neither_side_can_fill_safely_test() {
  let board = seki_position()
  let black = player.Player("black", player.Black)
  let white = player.Player("white", player.White)
  list.each([#(black, white), #(white, black)], fn(players) {
    list.each([#(#(2, 4), #(6, 4)), #(#(6, 4), #(2, 4))], fn(moves) {
      let assert Ok(first) = go.play(board, players.0, moves.0)
      let assert Ok(captured) = go.play(first, players.1, moves.1)
      should.equal(
        list.contains(dict.values(captured.stones), players.0),
        False,
      )
    })
  })
}

pub fn atari_fixture_has_a_legal_escape_to_two_eyes_test() {
  let board = escapable_atari_position()
  let black = player.Player("black", player.Black)
  let assert Ok(escaped) = go.play(board, black, #(1, 2))
  let assert Ok(group) =
    go.groups(escaped) |> list.find(fn(entry) { entry.0 == black })
  should.equal(set.contains(group.1, #(1, 1)), True)
  should.equal(set.contains(group.1, #(1, 3)), True)
  list.each([#(1, 4), #(3, 4)], fn(eye) {
    should.equal(dict.has_key(escaped.stones, eye), False)
    list.each(
      [
        #(eye.0 - 1, eye.1),
        #(eye.0 + 1, eye.1),
        #(eye.0, eye.1 - 1),
        #(eye.0, eye.1 + 1),
      ],
      fn(point) { should.equal(dict.get(escaped.stones, point), Ok(black)) },
    )
  })
}

fn engine_cases() -> List(#(String, go.Game, List(go.Point))) {
  let enclosed = fixtures.final_position().board
  let multiplayer =
    go.Game(
      ..enclosed,
      stones: dict.insert(
        enclosed.stones,
        #(8, 8),
        player.Player("blue", player.Blue),
      ),
    )
  [
    #("empty", go.new_game(9), []),
    #("enclosed two-player", enclosed, [#(2, 2)]),
    #("enclosed multiplayer", multiplayer, [#(2, 2)]),
    #("hury screenshot", fixtures.screenshot_position(), [
      #(2, 4),
      #(6, 0),
      #(6, 8),
      #(18, 17),
    ]),
    #("seki", seki_position(), []),
    #("escapable atari", escapable_atari_position(), []),
  ]
}

fn check_engine_cases() {
  list.each(engine_cases(), fn(entry) {
    let #(name, board, expected) = entry
    let assert Ok(dead) = adjudication.estimate(board)
    should.equal(#(name, set.from_list(dead)), #(name, set.from_list(expected)))
    // Even dead stones are only excluded from a scoring copy.
    let scoring = go.remove_stones(board, dead)
    should.equal(scoring.history, board.history)
    case name == "hury screenshot" {
      False -> Nil
      True -> {
        should.equal(dict.get(go.score(scoring), "O"), Ok(64))
        should.equal(dict.get(go.score(scoring), "P"), Ok(56))
        should.equal(
          dict.get(go.area(scoring), #(6, 8)),
          Ok(player.Player("P", player.Pink)),
        )
        should.equal(
          dict.get(board.stones, #(6, 8)),
          Ok(player.Player("O", player.Orange)),
        )
      }
    }
  })
}

pub fn empty_board_does_not_need_an_engine_test() {
  should.equal(adjudication.estimate(go.new_game(9)), Ok([]))
}

pub fn all_known_positions_with_engine_when_installed_test() {
  case katago.available() {
    False -> Nil
    True -> check_engine_cases()
  }
}

/// Run explicitly on an engine-equipped host for repeated real NN coverage.
pub fn main() {
  let assert True = katago.available()
  list.each(list.range(1, 20), fn(_) {
    check_engine_cases()
    // Stop only this test VM's private engine, never the running game server.
    // Fresh processes also avoid the installed engine's clear_cache crash.
    let _ = stop_engine(atom.create("rtgo_katago_ffi"))
  })
  io.println(
    "Production single-view scoring: all 6 position cases passed 20 fresh-engine trials (120 checks).",
  )
}
