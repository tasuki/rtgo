import gleam/dict
import gleam/list
import gleeunit/should
import rtgo_shared/go
import rtgo_shared/player.{Black, Blue, Player, White}

pub fn empty_and_mixed_regions_have_no_territory_test() {
  should.equal(go.territory(go.new_game(9)), dict.new())
  let black = Player("black", Black)
  let white = Player("white", White)
  let blue = Player("blue", Blue)
  let board =
    go.Game(
      ..go.new_game(9),
      stones: dict.from_list([
        #(#(1, 2), black),
        #(#(2, 1), black),
        #(#(3, 2), black),
        #(#(2, 3), black),
        #(#(0, 0), white),
        #(#(8, 8), blue),
      ]),
    )
  // Only the central empty point is exclusive; outside is shared/neutral.
  should.equal(go.territory(board), dict.from_list([#(#(2, 2), black)]))
}

pub fn territory_plus_stones_matches_area_score_on_all_board_sizes_test() {
  let owner = Player("blue", Blue)
  list.each([9, 13, 19], fn(size) {
    let assert Ok(board) = go.play(go.new_game(size), owner, #(0, 0))
    let territory = go.territory(board)
    should.equal(dict.size(territory), size * size - 1)
    should.equal(dict.has_key(territory, #(0, 0)), False)
    should.equal(dict.get(territory, #(size - 1, size - 1)), Ok(owner))
    let area = go.area(board)
    should.equal(dict.size(area), size * size)
    should.equal(dict.get(area, #(0, 0)), Ok(owner))
    should.equal(
      go.score(board),
      dict.from_list([#("blue", dict.size(territory) + 1)]),
    )
  })
}

pub fn excluded_dead_stones_become_territory_without_changing_the_original_test() {
  let black = Player("black", Black)
  let white = Player("white", White)
  let blue = Player("blue", Blue)
  let assert Ok(board) = go.play(go.new_game(9), white, #(2, 2))
  let assert Ok(board) = go.play(board, blue, #(8, 8))
  let ring =
    list.range(1, 4)
    |> list.flat_map(fn(x) {
      list.range(1, 4)
      |> list.filter_map(fn(y) {
        case x == 1 || x == 4 || y == 1 || y == 4 {
          True -> Ok(#(x, y))
          False -> Error(Nil)
        }
      })
    })
  let board =
    list.fold(ring, board, fn(board, point) {
      let assert Ok(board) = go.play(board, black, point)
      board
    })
  let scoring = go.remove_stones(board, [#(2, 2)])
  should.equal(scoring.history, board.history)
  should.equal(dict.get(board.stones, #(2, 2)), Ok(white))
  should.equal(dict.has_key(scoring.stones, #(2, 2)), False)
  should.equal(
    go.territory(scoring),
    dict.from_list([
      #(#(2, 2), black),
      #(#(2, 3), black),
      #(#(3, 2), black),
      #(#(3, 3), black),
    ]),
  )
  let area = go.area(scoring)
  should.equal(dict.size(area), 17)
  should.equal(dict.get(area, #(2, 2)), Ok(black))
  should.equal(dict.get(area, #(8, 8)), Ok(blue))
  should.equal(
    go.score(scoring),
    dict.from_list([#("black", 16), #("blue", 1)]),
  )
}
