import gleam/dict
import gleeunit/should
import rtgo_shared/go
import rtgo_shared/player.{Black, Blue, Player, White}

pub fn play_test() {
  let black = Player("Black", Black)
  let white = Player("White", White)
  let game = go.new_game(19)

  // Valid move
  let assert Ok(game) = go.play(game, black, #(0, 0))
  game.stones
  |> dict.get(#(0, 0))
  |> should.equal(Ok(black))

  // Out of bounds
  go.play(game, white, #(19, 19))
  |> should.equal(Error(go.OutOfBounds))

  go.play(game, white, #(-1, 0))
  |> should.equal(Error(go.OutOfBounds))

  // Occupied
  go.play(game, white, #(0, 0))
  |> should.equal(Error(go.Occupied))
}

pub fn capture_test() {
  let black = Player("Black", Black)
  let white = Player("White", White)
  let game = go.new_game(19)

  // White stone at (1,1)
  let assert Ok(game) = go.play(game, white, #(1, 1))

  // Black surrounds it
  let assert Ok(game) = go.play(game, black, #(0, 1))
  let assert Ok(game) = go.play(game, white, #(10, 10))
  let assert Ok(game) = go.play(game, black, #(2, 1))
  let assert Ok(game) = go.play(game, white, #(10, 11))
  let assert Ok(game) = go.play(game, black, #(1, 0))
  let assert Ok(game) = go.play(game, white, #(10, 12))
  let assert Ok(game) = go.play(game, black, #(1, 2))

  // White stone should be captured
  game.stones
  |> dict.has_key(#(1, 1))
  |> should.be_false()
}

pub fn capture_group_test() {
  let black = Player("Black", Black)
  let white = Player("White", White)
  let game = go.new_game(19)

  // Two white stones
  let assert Ok(game) = go.play(game, white, #(1, 1))
  let assert Ok(game) = go.play(game, black, #(10, 10))
  let assert Ok(game) = go.play(game, white, #(1, 2))

  // Black surrounds them
  let assert Ok(game) = go.play(game, black, #(0, 1))
  let assert Ok(game) = go.play(game, white, #(10, 11))
  let assert Ok(game) = go.play(game, black, #(0, 2))
  let assert Ok(game) = go.play(game, white, #(10, 12))
  let assert Ok(game) = go.play(game, black, #(2, 1))
  let assert Ok(game) = go.play(game, white, #(10, 13))
  let assert Ok(game) = go.play(game, black, #(2, 2))
  let assert Ok(game) = go.play(game, white, #(10, 14))
  let assert Ok(game) = go.play(game, black, #(1, 0))
  let assert Ok(game) = go.play(game, white, #(10, 15))
  let assert Ok(game) = go.play(game, black, #(1, 3))

  // White stones should be captured
  game.stones
  |> dict.has_key(#(1, 1))
  |> should.be_false()
  game.stones
  |> dict.has_key(#(1, 2))
  |> should.be_false()
}

pub fn suicide_test() {
  let black = Player("Black", Black)
  let white = Player("White", White)
  let game = go.new_game(19)

  // Black surrounds (1,1)
  let assert Ok(game) = go.play(game, black, #(0, 1))
  let assert Ok(game) = go.play(game, white, #(10, 10))
  let assert Ok(game) = go.play(game, black, #(2, 1))
  let assert Ok(game) = go.play(game, white, #(10, 11))
  let assert Ok(game) = go.play(game, black, #(1, 0))
  let assert Ok(game) = go.play(game, white, #(10, 12))
  let assert Ok(game) = go.play(game, black, #(1, 2))

  // White tries to play at (1,1)
  go.play(game, white, #(1, 1))
  |> should.equal(Error(go.Suicide))
}

pub fn ko_test() {
  let black = Player("Black", Black)
  let white = Player("White", White)

  // Standard Ko:
  // B at (1,0), (0,1), (1,2)
  // W at (2,0), (3,1), (2,2), (1,1)
  // 1. B plays (2,1) -> captures W(1,1)
  // 2. W tries to play (1,1) -> Ko (repeats board state before B played (2,1))

  let game = go.new_game(19)
  let assert Ok(game) = go.play(game, black, #(1, 0))
  let assert Ok(game) = go.play(game, white, #(2, 0))
  let assert Ok(game) = go.play(game, black, #(0, 1))
  let assert Ok(game) = go.play(game, white, #(3, 1))
  let assert Ok(game) = go.play(game, black, #(1, 2))
  let assert Ok(game) = go.play(game, white, #(2, 2))
  let assert Ok(game) = go.play(game, black, #(10, 10))
  let assert Ok(game) = go.play(game, white, #(1, 1))

  // Board state now:
  //   B(1,0) W(2,0)
  // B(0,1) W(1,1) . (2,1) W(3,1)
  //   B(1,2) W(2,2)

  // B plays (2,1) -> captures W(1,1)
  let assert Ok(game) = go.play(game, black, #(2, 1))
  game.stones |> dict.has_key(#(1, 1)) |> should.be_false()

  // W tries to play (1,1) -> Ko
  go.play(game, white, #(1, 1))
  |> should.equal(Error(go.Ko))
}

pub fn multi_player_capture_test() {
  let black = Player("Black", Black)
  let white = Player("White", White)
  let blue = Player("Blue", Blue)
  let game = go.new_game(19)

  // Black stone at (1,1)
  let assert Ok(game) = go.play(game, black, #(1, 1))

  // Surrounded by white and blue
  let assert Ok(game) = go.play(game, white, #(0, 1))
  let assert Ok(game) = go.play(game, black, #(10, 10))
  let assert Ok(game) = go.play(game, white, #(2, 1))
  let assert Ok(game) = go.play(game, black, #(10, 11))
  let assert Ok(game) = go.play(game, blue, #(1, 0))
  let assert Ok(game) = go.play(game, black, #(10, 12))
  let assert Ok(game) = go.play(game, blue, #(1, 2))

  // Black stone should be captured
  game.stones
  |> dict.has_key(#(1, 1))
  |> should.be_false()
}
