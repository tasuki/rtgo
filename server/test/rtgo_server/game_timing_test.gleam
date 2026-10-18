import gleam/dict
import gleam/option.{Some}
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

pub fn everyone_starts_cooling_and_passes_only_after_their_opening_window_test() {
  let state = initial()
  let live = game.snapshot_at(state, -100_000).live
  let assert [alice, bob] = live.players
  should.equal(alice.cooldown_ms, 5000)
  should.equal(alice.pass_in_ms, 15_000)
  should.equal(bob.cooldown_ms, 30_000)
  should.equal(bob.pass_in_ms, 40_000)
  should.equal(live.end_in_ms, 40_000)
  should.equal(live.revision, 0)
  should.equal(dict.is_empty(live.board.stones), True)
  should.equal(state.record.moves, [])
  should.equal(
    game.play_at(state, "alice", #(0, 0), -100_000),
    Error(game.CoolingDown),
  )
  should.equal(
    game.play_at(state, "bob", #(8, 8), -100_000),
    Error(game.CoolingDown),
  )
  // Alice can already be passing while Bob is still in his opening cooldown.
  let assert [alice, bob] = game.snapshot_at(state, -80_000).live.players
  should.equal(alice.pass_in_ms, 0)
  should.equal(bob.cooldown_ms, 10_000)
  should.equal(game.advance(state, -60_001).phase, settings.Started)
  let ended = game.advance(state, -60_000)
  should.equal(ended.phase, settings.Finished)
  should.equal(ended.revision, 1)
  should.equal(ended.record.finished_at, Some(40_000))
  should.equal(game.advance(ended, 100_000), ended)
  should.equal(
    game.play_at(state, "alice", #(0, 0), -60_000),
    Error(game.GameFinished),
  )
}

pub fn opening_and_later_cooldown_boundaries_and_handicaps_are_enforced_test() {
  let state = initial()
  should.equal(
    game.play_at(state, "alice", #(0, 0), -95_001),
    Error(game.CoolingDown),
  )
  let assert Ok(state) = game.play_at(state, "alice", #(0, 0), -95_000)
  should.equal(dict.get(state.ready_at, "alice"), Ok(-90_000))
  should.equal(
    game.play_at(state, "alice", #(0, 1), -90_001),
    Error(game.CoolingDown),
  )
  let assert Ok(state) = game.play_at(state, "alice", #(0, 1), -90_000)
  // A long opening handicap must not end the game before that player is ready.
  should.equal(game.advance(state, -80_000).phase, settings.Started)
  should.equal(
    game.play_at(state, "bob", #(8, 8), -70_001),
    Error(game.CoolingDown),
  )
  let assert Ok(state) = game.play_at(state, "bob", #(8, 8), -70_000)
  should.equal(dict.get(state.ready_at, "bob"), Ok(-40_000))
}

pub fn missing_player_cooldowns_use_the_base_for_opening_and_later_moves_test() {
  let state =
    game.new_state(
      initial().players,
      settings.default_settings,
      dict.from_list([#("alice", 7)]),
      1234,
    )
  should.equal(dict.get(state.ready_at, "alice"), Ok(8234))
  should.equal(dict.get(state.ready_at, "bob"), Ok(6234))
  should.equal(
    game.play_at(state, "bob", #(0, 0), 6233),
    Error(game.CoolingDown),
  )
  let assert Ok(moved) = game.play_at(state, "bob", #(0, 0), 6234)
  should.equal(dict.get(moved.ready_at, "bob"), Ok(11_234))
  let assert [move] = moved.record.moves
  should.equal(move.at_ms, 5000)
}

pub fn passing_is_reversible_until_everyone_passes_test() {
  let assert Ok(state) = game.play_at(initial(), "bob", #(8, 8), -70_000)
  let live = game.snapshot_at(state, -59_000).live
  let assert [alice, bob] = live.players
  should.equal(alice.pass_in_ms, 0)
  should.equal(bob.pass_in_ms, 29_000)
  should.equal(live.finished, False)
  let assert Ok(resumed) = game.play_at(state, "alice", #(0, 0), -59_000)
  let assert [alice, ..] = game.snapshot_at(resumed, -59_000).live.players
  should.equal(alice.pass_in_ms, 15_000)
  should.equal(game.advance(resumed, -30_001).phase, settings.Started)
  should.equal(game.advance(resumed, -30_000).phase, settings.Finished)
}

pub fn invalid_moves_do_not_extend_cooldown_or_prevent_auto_pass_test() {
  let assert Ok(state) = game.play_at(initial(), "alice", #(0, 0), -95_000)
  should.equal(
    game.play_at(state, "bob", #(0, 0), -69_000),
    Error(game.InvalidMove(go.Occupied)),
  )
  should.equal(
    game.play_at(state, "bob", #(-1, 0), -69_000),
    Error(game.InvalidMove(go.OutOfBounds)),
  )
  should.equal(
    game.play_at(state, "outsider", #(1, 0), -69_000),
    Error(game.UnknownPlayer),
  )
  should.equal(dict.get(state.ready_at, "bob"), Ok(-70_000))
  let ended = game.snapshot_at(state, -60_000)
  should.equal(ended.phase, settings.Finished)
  should.equal(ended.live.finished, True)
  should.equal(ended.live.end_in_ms, 0)
  // Scoring is asynchronous; never publish a provisional winner here.
  should.equal(dict.size(ended.live.scores), 0)
  should.equal(
    game.play_at(state, "bob", #(1, 0), -60_000),
    Error(game.GameFinished),
  )
}
