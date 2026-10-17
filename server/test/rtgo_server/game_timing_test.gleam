import gleam/dict
import gleeunit/should
import rtgo_server/game
import rtgo_shared/game as settings
import rtgo_shared/go
import rtgo_shared/player

fn initial() {
  let players =
    dict.from_list([
      #("alice", player.Player("alice", player.Black)),
      #("bob", player.Player("bob", player.White)),
    ])
  game.new_state(
    players,
    settings.default_settings,
    dict.from_list([#("alice", 5), #("bob", 30)]),
    -100_000,
  )
}

pub fn everyone_starts_ready_and_opening_inactivity_ends_game_test() {
  let state = initial()
  let live = game.snapshot_at(state, -100_000).live
  should.equal(live.end_in_ms, 10_000)
  should.equal(game.advance(state, -90_001).phase, settings.Started)
  let ended = game.advance(state, -90_000)
  should.equal(ended.phase, settings.Finished)
  should.equal(ended.revision, 1)
  should.equal(game.advance(ended, 100_000), ended)
  should.equal(
    game.play_at(state, "alice", #(0, 0), -90_000),
    Error(game.GameFinished),
  )
}

pub fn cooldown_boundaries_and_handicaps_are_server_enforced_test() {
  let state = initial()
  let assert Ok(state) = game.play_at(state, "alice", #(0, 0), -100_000)
  let assert Ok(state) = game.play_at(state, "bob", #(8, 8), -100_000)
  should.equal(
    game.play_at(state, "alice", #(0, 1), -95_001),
    Error(game.CoolingDown),
  )
  let assert Ok(state) = game.play_at(state, "alice", #(0, 1), -95_000)
  should.equal(
    game.play_at(state, "bob", #(8, 7), -70_001),
    Error(game.CoolingDown),
  )
  // Even when every player is cooling down, the game must not finish.
  should.equal(game.advance(state, -94_000).phase, settings.Started)
  let assert Ok(state) = game.play_at(state, "bob", #(8, 7), -70_000)
  should.equal(dict.get(state.ready_at, "bob"), Ok(-40_000))
}

pub fn passing_is_reversible_until_everyone_passes_test() {
  let assert Ok(state) = game.play_at(initial(), "bob", #(8, 8), -100_000)
  let live = game.snapshot_at(state, -89_000).live
  let assert [alice, bob] = live.players
  should.equal(alice.pass_in_ms, 0)
  should.equal(bob.pass_in_ms, 29_000)
  should.equal(live.finished, False)
  let assert Ok(resumed) = game.play_at(state, "alice", #(0, 0), -89_000)
  let assert [alice, ..] = game.snapshot_at(resumed, -89_000).live.players
  should.equal(alice.pass_in_ms, 15_000)
  should.equal(game.advance(resumed, -60_001).phase, settings.Started)
  should.equal(game.advance(resumed, -60_000).phase, settings.Finished)
}

pub fn invalid_moves_do_not_extend_cooldown_or_prevent_auto_pass_test() {
  let assert Ok(state) = game.play_at(initial(), "alice", #(0, 0), -100_000)
  should.equal(
    game.play_at(state, "bob", #(0, 0), -99_000),
    Error(game.InvalidMove(go.Occupied)),
  )
  should.equal(
    game.play_at(state, "bob", #(-1, 0), -99_000),
    Error(game.InvalidMove(go.OutOfBounds)),
  )
  should.equal(
    game.play_at(state, "outsider", #(1, 0), -99_000),
    Error(game.UnknownPlayer),
  )
  let ended = game.snapshot_at(state, -85_000)
  should.equal(ended.phase, settings.Finished)
  should.equal(ended.live.finished, True)
  should.equal(ended.live.end_in_ms, 0)
  // Scoring is asynchronous; never publish a provisional winner here.
  should.equal(dict.size(ended.live.scores), 0)
  should.equal(
    game.play_at(state, "bob", #(1, 0), -85_000),
    Error(game.GameFinished),
  )
}
