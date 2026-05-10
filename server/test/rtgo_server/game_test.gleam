import gleam/dict
import gleeunit/should
import rtgo_server/game
import rtgo_shared/go
import rtgo_shared/player

fn players() {
  dict.from_list([
    #("alice", player.Player("alice", player.Black)),
    #("bob", player.Player("bob", player.White)),
  ])
}

pub fn started_game_accepts_moves_test() {
  let actor = game.start(players())

  should.equal(game.play(actor, "alice", #(3, 3)), Ok(Nil))

  let game.Snapshot(board:, ..) = game.get_game(actor)
  let go.Game(stones:, ..) = board
  should.equal(
    dict.get(stones, #(3, 3)),
    Ok(player.Player("alice", player.Black)),
  )
}

pub fn unknown_player_cannot_move_test() {
  let actor = game.start(players())

  should.equal(game.play(actor, "charlie", #(3, 3)), Error(game.UnknownPlayer))
}
