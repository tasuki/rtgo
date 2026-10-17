import gleam/dict
import gleam/json
import gleam/list
import gleeunit/should
import rtgo_shared/go
import rtgo_shared/play_api
import rtgo_shared/player.{Black, Blue, Player, White}

pub fn corners_and_edges_are_not_liberties_test() {
  let black = Player("black", Black)
  let white = Player("white", White)
  let assert Ok(game) = go.play(go.new_game(9), white, #(0, 0))
  let assert Ok(game) = go.play(game, black, #(1, 0))
  let assert Ok(game) = go.play(game, black, #(0, 1))
  should.equal(dict.has_key(game.stones, #(0, 0)), False)
  should.equal(go.play(game, white, #(0, 0)), Error(go.Suicide))

  let assert Ok(game) = go.play(go.new_game(9), white, #(0, 4))
  let assert Ok(game) = go.play(game, black, #(0, 3))
  let assert Ok(game) = go.play(game, black, #(0, 5))
  let assert Ok(game) = go.play(game, black, #(1, 4))
  should.equal(dict.has_key(game.stones, #(0, 4)), False)
}

pub fn empty_board_is_neutral_and_single_owner_claims_area_test() {
  should.equal(go.score(go.new_game(9)), dict.new())
  let assert Ok(game) = go.play(go.new_game(9), Player("black", Black), #(4, 4))
  should.equal(go.score(game), dict.from_list([#("black", 81)]))
}

pub fn enclosed_regions_and_contested_space_score_correctly_test() {
  let black = Player("black", Black)
  let white = Player("white", White)
  let blue = Player("blue", Blue)
  // A black ring claims the central empty point. The surrounding region is
  // contested by white and blue, and contributes to nobody's score.
  let board =
    go.Game(
      ..go.new_game(5),
      stones: dict.from_list([
        #(#(1, 2), black),
        #(#(2, 1), black),
        #(#(3, 2), black),
        #(#(2, 3), black),
        #(#(0, 0), white),
        #(#(4, 4), blue),
      ]),
    )
  should.equal(
    go.score(board),
    dict.from_list([#("black", 5), #("white", 1), #("blue", 1)]),
  )
}

pub fn scoring_statuses_round_trip_test() {
  list.each(
    [
      play_api.NotScored,
      play_api.Scoring,
      play_api.Estimated,
      play_api.Unavailable,
    ],
    fn(status) {
      let state =
        play_api.State(
          go.new_game(9),
          [],
          status != play_api.NotScored,
          2,
          0,
          dict.new(),
          status,
          [],
        )
      let assert Ok(decoded) =
        state
        |> play_api.state_to_json
        |> json.to_string
        |> json.parse(play_api.state_decoder())
      should.equal(decoded.scoring, status)
      should.equal(decoded.dead_stones, [])
    },
  )
}

pub fn live_state_json_round_trip_test() {
  let black = Player("alice", Black)
  let assert Ok(board) = go.play(go.new_game(9), black, #(0, 0))
  let state =
    play_api.State(
      board,
      [play_api.PlayerStatus(black, 1234, 11_234)],
      False,
      1,
      11_234,
      dict.new(),
      play_api.NotScored,
      [],
    )
  let assert Ok(decoded) =
    state
    |> play_api.state_to_json
    |> json.to_string
    |> json.parse(play_api.state_decoder())
  should.equal(decoded.board.stones, board.stones)
  should.equal(decoded.board.board_size, 9)
  should.equal(decoded.players, state.players)
  should.equal(decoded.revision, 1)
  should.equal(decoded.end_in_ms, 11_234)
  should.equal(decoded.finished, False)
  let finished =
    play_api.State(
      ..state,
      finished: True,
      scores: go.score(board),
      scoring: play_api.Estimated,
      dead_stones: [#(0, 0)],
    )
  let assert Ok(decoded) =
    finished
    |> play_api.state_to_json
    |> json.to_string
    |> json.parse(play_api.state_decoder())
  should.equal(decoded.scores, finished.scores)
  should.equal(decoded.finished, True)
  should.equal(decoded.scoring, play_api.Estimated)
  should.equal(decoded.dead_stones, [#(0, 0)])
}
