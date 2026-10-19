import gleam/dict
import gleam/list
import gleam/set
import gleeunit/should
import rtgo_server/game
import rtgo_shared/game as settings
import rtgo_shared/go
import rtgo_shared/player

fn players() {
  dict.from_list([
    #("alice", player.Player("alice", player.Black)),
    #("bob", player.Player("bob", player.White)),
  ])
}

fn config() {
  settings.Settings(19, settings.TwoPlayerGame, settings.DragDerby)
}

pub fn large_histories_are_not_in_either_snapshot_board_test() {
  let initial = game.new_state(players(), config(), dict.new(), 0)
  let state =
    list.fold(list.range(0, 299), initial, fn(state, index) {
      let assert Ok(state) =
        game.play_at(state, "alice", #(index % 19, index / 19), 0)
      state
    })
  should.equal(set.size(state.board.history), 301)
  let snapshot = game.snapshot_at(state, 0)
  should.equal(set.size(snapshot.board.history), 0)
  should.equal(set.size(snapshot.live.board.history), 0)
  should.equal(snapshot.board.stones, state.board.stones)
  should.equal(snapshot.live.board.stones, state.board.stones)
  should.equal(snapshot.board.board_size, 19)
  // Building a read-only view must not prune the authoritative history/record.
  should.equal(set.size(state.board.history), 301)
  should.equal(list.length(state.record.moves), 300)
}

pub fn polling_does_not_remove_authoritative_superko_history_test() {
  let subject = game.start(players(), config(), dict.new())
  list.each(
    [
      #("alice", #(1, 0)),
      #("bob", #(2, 0)),
      #("alice", #(0, 1)),
      #("bob", #(3, 1)),
      #("alice", #(1, 2)),
      #("bob", #(2, 2)),
      #("bob", #(1, 1)),
      #("alice", #(2, 1)),
    ],
    fn(move) { should.equal(game.play(subject, move.0, move.1), Ok(Nil)) },
  )
  let snapshot = game.get_game(subject)
  should.equal(set.size(snapshot.board.history), 0)
  should.equal(set.size(snapshot.live.board.history), 0)
  let metadata = game.get_metadata(subject)
  should.equal(metadata.phase, settings.Started)
  should.equal(metadata.player_count, 2)
  should.equal(
    game.play(subject, "bob", #(1, 1)),
    Error(game.InvalidMove(go.Ko)),
  )
  should.equal(list.length(game.get_record(subject).moves), 8)
}

pub fn metadata_reports_phase_changes_without_a_board_snapshot_test() {
  let subject = game.start(players(), config(), dict.new())
  let metadata = game.get_metadata(subject)
  should.equal(metadata.phase, settings.Started)
  should.equal(metadata.player_count, 2)
  should.equal(game.pass(subject, "alice"), Ok(Nil))
  should.equal(game.get_metadata(subject), metadata)
  should.equal(game.pass(subject, "bob"), Ok(Nil))
  should.equal(
    game.get_metadata(subject),
    game.Metadata(..metadata, phase: settings.Finished),
  )
}
