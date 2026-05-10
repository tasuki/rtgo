import gleam/dict
import gleam/list
import gleeunit/should
import rtgo_server/game
import rtgo_server/lobby
import rtgo_shared/game as shared_game
import rtgo_shared/player

pub fn create_game_is_listed_test() {
  let actor = lobby.start()

  let id = lobby.create_game(actor)
  let games = lobby.list_games(actor)

  should.not_equal(id, "")
  should.equal(
    dict.get(games, id),
    Ok(lobby.Metadata(shared_game.Negotiating, 0)),
  )
}

pub fn join_assigns_distinct_colors_test() {
  let actor = lobby.start()
  let id = lobby.create_game(actor)

  should.equal(lobby.join_game(actor, id, "alice"), Ok(True))
  should.equal(lobby.join_game(actor, id, "bob"), Ok(True))

  let assert Ok(lobby.Open(lobby.Lobby(players))) = lobby.get_game(actor, id)
  let assert Ok(player.Player(_, alice_color)) = dict.get(players, "alice")
  let assert Ok(player.Player(_, bob_color)) = dict.get(players, "bob")
  should.not_equal(alice_color, bob_color)
  should.equal(list.contains(player.all_colors, alice_color), True)
  should.equal(list.contains(player.all_colors, bob_color), True)
}

pub fn start_requires_two_players_test() {
  let actor = lobby.start()
  let id = lobby.create_game(actor)

  should.equal(lobby.start_game(actor, id), Ok(False))
  should.equal(lobby.join_game(actor, id, "alice"), Ok(True))
  should.equal(lobby.start_game(actor, id), Ok(False))
  should.equal(lobby.join_game(actor, id, "bob"), Ok(True))
  should.equal(lobby.start_game(actor, id), Ok(True))

  let assert Ok(lobby.Running(subject)) = lobby.get_game(actor, id)
  let game.Snapshot(players:, ..) = game.get_game(subject)
  should.equal(dict.size(players), 2)
  should.equal(
    dict.get(lobby.list_games(actor), id),
    Ok(lobby.Metadata(shared_game.Started, 2)),
  )
}

pub fn cannot_join_when_colors_are_exhausted_test() {
  let actor = lobby.start()
  let id = lobby.create_game(actor)

  should.equal(lobby.join_game(actor, id, "p1"), Ok(True))
  should.equal(lobby.join_game(actor, id, "p2"), Ok(True))
  should.equal(lobby.join_game(actor, id, "p3"), Ok(True))
  should.equal(lobby.join_game(actor, id, "p4"), Ok(True))
  should.equal(lobby.join_game(actor, id, "p5"), Ok(True))
  should.equal(lobby.join_game(actor, id, "p6"), Ok(True))
  should.equal(lobby.join_game(actor, id, "p7"), Ok(True))
  should.equal(lobby.join_game(actor, id, "p8"), Ok(True))
  should.equal(lobby.join_game(actor, id, "p9"), Ok(False))
}
