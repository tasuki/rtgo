import gleam/dict
import gleeunit/should
import rtgo_server/game
import rtgo_server/test_support
import rtgo_shared/game as shared_game
import rtgo_shared/go
import rtgo_shared/player

fn players() {
  dict.from_list([
    #("alice", player.Player("alice", player.Black)),
    #("bob", player.Player("bob", player.White)),
  ])
}

fn start_game() {
  let settings =
    shared_game.Settings(
      ..shared_game.default_settings,
      time_settings: shared_game.Cooldown(1),
    )
  game.start(
    players(),
    settings,
    shared_game.default_cooldowns(["alice", "bob"], settings),
  )
}

pub fn started_game_rejects_moves_until_the_opening_cooldown_expires_test() {
  let actor = start_game()
  should.equal(game.play(actor, "alice", #(3, 3)), Error(game.CoolingDown))
  should.equal(dict.is_empty(game.get_game(actor).board.stones), True)
  test_support.wait_until_ready(actor, "alice")
  should.equal(game.play(actor, "alice", #(3, 3)), Ok(Nil))

  let game.Snapshot(board:, ..) = game.get_game(actor)
  let go.Game(stones:, ..) = board
  should.equal(
    dict.get(stones, #(3, 3)),
    Ok(player.Player("alice", player.Black)),
  )
}

pub fn unknown_player_cannot_move_test() {
  let actor = start_game()

  should.equal(game.play(actor, "charlie", #(3, 3)), Error(game.UnknownPlayer))
}
