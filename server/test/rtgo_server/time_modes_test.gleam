import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleeunit/should
import rtgo_server/game
import rtgo_shared/game as settings
import rtgo_shared/go
import rtgo_shared/play_api
import rtgo_shared/player
import rtgo_shared/sgf

fn initial(timing: settings.TimeSettings) -> game.State {
  let players =
    dict.from_list([
      #("alice", player.Player("alice", player.Black)),
      #("bob", player.Player("bob", player.White)),
    ])
  let config = settings.Settings(9, settings.TwoPlayerGame, timing)
  game.new_state(
    players,
    config,
    settings.default_cooldowns(dict.keys(players), config),
    0,
  )
}

pub fn cushy_credit_is_capped_and_never_earned_during_opening_cooldown_test() {
  let state = initial(settings.CushyCooldown(4))
  should.equal(
    game.play_at(state, "alice", #(0, 0), 3999),
    Error(game.CoolingDown),
  )
  let assert Ok(prompt) = game.play_at(state, "alice", #(0, 0), 4000)
  should.equal(dict.get(prompt.ready_at, "alice"), Ok(8000))
  let assert Ok(late) = game.play_at(state, "alice", #(0, 0), 4500)
  should.equal(dict.get(late.ready_at, "alice"), Ok(8000))
  let assert Ok(capped) = game.play_at(state, "alice", #(0, 0), 6500)
  should.equal(dict.get(capped.ready_at, "alice"), Ok(9500))
  should.equal(
    game.play_at(capped, "alice", #(1, 0), 9499),
    Error(game.CoolingDown),
  )
  let assert Ok(next) = game.play_at(capped, "alice", #(1, 0), 9500)
  should.equal(dict.get(next.ready_at, "alice"), Ok(13_500))
}

pub fn cushy_rejections_do_not_grant_credit_or_extend_deadlines_test() {
  let assert Ok(state) =
    game.play_at(initial(settings.CushyCooldown(4)), "bob", #(0, 0), 4000)
  should.equal(
    game.play_at(state, "alice", #(0, 0), 4500),
    Error(game.InvalidMove(go.Occupied)),
  )
  let assert Ok(moved) = game.play_at(state, "alice", #(1, 0), 4500)
  should.equal(dict.get(moved.ready_at, "alice"), Ok(8000))
  should.equal(game.advance(state, 17_999).phase, settings.Started)
  should.equal(game.advance(state, 18_000).phase, settings.Finished)
}

pub fn explicit_pass_cannot_bypass_opening_or_subsequent_cooldowns_test() {
  list.each(
    [
      settings.Cooldown(4),
      settings.CushyCooldown(4),
      settings.StoneSavings(4, 3, 1000),
    ],
    fn(mode) {
      let state = initial(mode)
      should.equal(game.pass_at(state, "alice", 3999), Error(game.CoolingDown))
      let assert Ok(passed) = game.pass_at(state, "alice", 4000)
      should.equal(passed.ready_at, state.ready_at)
      should.equal(passed.board, state.board)
      should.equal(passed.record.moves, [])
      let assert Ok(resumed) = game.play_at(passed, "alice", #(0, 0), 4000)
      should.equal(dict.has_key(resumed.passed_at, "alice"), False)
      should.equal(
        game.pass_at(resumed, "alice", 4001),
        Error(game.CoolingDown),
      )
      should.equal(
        game.play_at(resumed, "alice", #(1, 0), 4001),
        Error(game.CoolingDown),
      )
    },
  )
}

pub fn passes_are_idempotent_and_finish_when_everyone_passes_test() {
  list.each(
    [
      settings.Cooldown(4),
      settings.CushyCooldown(4),
      settings.StoneSavings(4, 3, 1000),
      settings.DragDerby,
    ],
    fn(mode) {
      let assert Ok(alice_passed) = game.pass_at(initial(mode), "alice", 4000)
      let assert Ok(repeated) = game.pass_at(alice_passed, "alice", 4000)
      should.equal(repeated, alice_passed)
      should.equal(
        game.pass_at(alice_passed, "outsider", 4000),
        Error(game.UnknownPlayer),
      )
      let assert Ok(ended) = game.pass_at(alice_passed, "bob", 4001)
      should.equal(ended.phase, settings.Finished)
      should.equal(ended.record.finished_at, Some(4001))
      should.equal(
        game.play_at(ended, "alice", #(0, 0), 4001),
        Error(game.GameFinished),
      )
      should.equal(game.pass_at(ended, "alice", 4001), Error(game.GameFinished))
    },
  )
}

pub fn explicit_and_automatic_passes_share_the_same_end_condition_test() {
  let assert Ok(state) =
    game.pass_at(initial(settings.Cooldown(4)), "alice", 4000)
  should.equal(game.advance(state, 13_999).phase, settings.Started)
  let ended = game.advance(state, 14_001)
  should.equal(ended.phase, settings.Finished)
  should.equal(ended.record.finished_at, Some(14_000))
  let assert Ok(resumed) = game.play_at(state, "alice", #(0, 0), 13_999)
  should.equal(game.advance(resumed, 14_001).phase, settings.Started)
}

pub fn per_player_handicaps_apply_to_credit_caps_and_recharge_test() {
  let cushy = initial(settings.CushyCooldown(4))
  let cushy =
    game.new_state(
      cushy.players,
      cushy.settings,
      dict.from_list([#("alice", 4), #("bob", 30)]),
      0,
    )
  let assert Ok(moved) = game.play_at(cushy, "bob", #(0, 0), 39_000)
  // Bob's cap is 25% of his own 30s, not the game's 4s base.
  should.equal(dict.get(moved.ready_at, "bob"), Ok(61_500))
  let bank = initial(settings.StoneSavings(5, 3, 1000))
  let bank =
    game.new_state(
      bank.players,
      bank.settings,
      dict.from_list([#("alice", 5), #("bob", 10)]),
      0,
    )
  let live = game.snapshot_at(bank, 15_000).live
  let assert Ok(alice) = dict.get(live.savings, "alice")
  let assert Ok(bob) = dict.get(live.savings, "bob")
  should.equal(alice.credits, 2)
  should.equal(bob.credits, 1)
  should.equal(bob.recharge_ms, 15_000)
}

pub fn rejected_resuming_moves_do_not_clear_explicit_passes_test() {
  list.each(
    [
      settings.Cooldown(4),
      settings.CushyCooldown(4),
      settings.StoneSavings(4, 3, 0),
      settings.DragDerby,
    ],
    fn(mode) {
      let assert Ok(state) = game.play_at(initial(mode), "bob", #(0, 0), 4000)
      let assert Ok(state) = game.pass_at(state, "alice", 4000)
      should.equal(
        game.play_at(state, "alice", #(0, 0), 4000),
        Error(game.InvalidMove(go.Occupied)),
      )
      let assert [alice, ..] = game.snapshot_at(state, 4000).live.players
      should.equal(alice.pass_in_ms, 0)
      let assert Ok(resumed) = game.play_at(state, "alice", #(1, 0), 4000)
      should.equal(dict.has_key(resumed.passed_at, "alice"), False)
    },
  )
}

pub fn savings_start_empty_recharge_with_diminishing_returns_and_cap_test() {
  let state = initial(settings.StoneSavings(5, 3, 1000))
  list.each(
    [
      #(0, 0),
      #(4999, 0),
      #(5000, 1),
      #(14_999, 1),
      #(15_000, 2),
      #(29_999, 2),
      #(30_000, 3),
      #(200_000, 3),
    ],
    fn(example) {
      let live = game.snapshot_at(state, example.0).live
      let assert Ok(bank) = dict.get(live.savings, "alice")
      should.equal(bank.credits, example.1)
      should.equal(bank.capacity, 3)
      should.equal(live.finished, False)
      should.equal(live.end_in_ms, -1)
    },
  )
  should.equal(
    game.play_at(state, "alice", #(0, 0), 4999),
    Error(game.CoolingDown),
  )
  let assert Ok(moved) = game.play_at(state, "alice", #(0, 0), 30_000)
  let assert Ok(bank) =
    dict.get(game.snapshot_at(moved, 30_000).live.savings, "alice")
  should.equal(bank.credits, 2)
  should.equal(bank.recharge_ms, 15_000)
  should.equal(
    game.play_at(moved, "alice", #(1, 0), 30_999),
    Error(game.CoolingDown),
  )
  should.equal(game.pass_at(moved, "alice", 30_999), Error(game.CoolingDown))
  let assert Ok(moved) = game.play_at(moved, "alice", #(1, 0), 31_000)
  let assert Ok(bank) =
    dict.get(game.snapshot_at(moved, 31_000).live.savings, "alice")
  should.equal(bank.credits, 1)
}

pub fn savings_passes_preserve_credits_and_partial_recharge_test() {
  let state = game.advance(initial(settings.StoneSavings(4, 3, 0)), 6000)
  let assert Ok(passed) = game.pass_at(state, "alice", 6000)
  should.equal(passed.banks, state.banks)
  let assert Ok(moved) = game.play_at(passed, "alice", #(0, 0), 6000)
  let assert Ok(bank) =
    dict.get(game.snapshot_at(moved, 6000).live.savings, "alice")
  // 25% of the second credit's interval remains 25% after spending the first.
  should.equal(bank.credits, 0)
  should.equal(bank.recharge_ms, 3000)
  should.equal(
    game.play_at(moved, "alice", #(1, 0), 8999),
    Error(game.CoolingDown),
  )
  let assert Ok(_) = game.play_at(moved, "alice", #(1, 0), 9000)
}

pub fn savings_can_burst_only_when_the_host_allows_zero_gap_test() {
  let state = initial(settings.StoneSavings(1, 3, 0))
  let assert Ok(state) = game.play_at(state, "alice", #(0, 0), 6000)
  let assert Ok(state) = game.play_at(state, "alice", #(1, 0), 6000)
  let assert Ok(state) = game.play_at(state, "alice", #(2, 0), 6000)
  should.equal(
    game.play_at(state, "alice", #(3, 0), 6000),
    Error(game.CoolingDown),
  )
}

pub fn drag_derby_has_no_opening_wait_or_gap_but_keeps_legality_and_timeout_test() {
  let state = initial(settings.DragDerby)
  let assert Ok(state) = game.play_at(state, "alice", #(0, 0), 0)
  let assert Ok(state) = game.play_at(state, "alice", #(1, 0), 0)
  let assert Ok(state) = game.play_at(state, "alice", #(2, 0), 0)
  should.equal(
    game.play_at(state, "bob", #(0, 0), 0),
    Error(game.InvalidMove(go.Occupied)),
  )
  should.equal(
    game.play_at(state, "bob", #(-1, 0), 0),
    Error(game.InvalidMove(go.OutOfBounds)),
  )
  let assert [alice, bob] = game.snapshot_at(state, 0).live.players
  should.equal(alice.cooldown_ms, 0)
  should.equal(bob.cooldown_ms, 0)
  should.equal(alice.pass_in_ms, 10_000)
  should.equal(game.advance(state, 10_000).phase, settings.Finished)
}

pub fn timing_and_bank_balances_survive_recording_and_wire_round_trips_test() {
  list.each(
    [
      settings.Cooldown(4),
      settings.CushyCooldown(4),
      settings.StoneSavings(4, 3, 1000),
      settings.DragDerby,
    ],
    fn(mode) {
      let assert Ok(state) = game.play_at(initial(mode), "alice", #(0, 0), 4000)
      let live = game.snapshot_at(state, 6000).live
      let assert Ok(decoded) =
        live
        |> play_api.state_to_json
        |> json.to_string
        |> json.parse(play_api.state_decoder())
      should.equal(decoded.savings, live.savings)
      should.equal(decoded.players, live.players)
      let assert Ok(replay) = state.record |> sgf.encode |> sgf.decode
      should.equal(replay.record, state.record)
      let assert Ok(last) = list.last(replay.frames)
      should.equal(last.board.stones, state.board.stones)
    },
  )
}
