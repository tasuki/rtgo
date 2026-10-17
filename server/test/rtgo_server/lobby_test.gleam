import gleam/dict
import gleam/int
import gleam/list
import gleeunit/should
import rtgo_server/game
import rtgo_server/lobby
import rtgo_shared/game as shared_game
import rtgo_shared/player

const multiplayer = shared_game.Settings(
  19,
  shared_game.MultiplayerGame,
  shared_game.Cooldown(5),
)

pub fn create_game_is_listed_test() {
  let actor = lobby.start()
  let assert Ok(id) =
    lobby.create_game(actor, "host", shared_game.default_settings)
  should.not_equal(id, "")
  should.equal(
    dict.get(lobby.list_games(actor), id),
    Ok(lobby.Metadata(shared_game.Negotiating, 1, shared_game.default_settings)),
  )
}

pub fn join_assigns_distinct_colors_test() {
  let actor = lobby.start()
  let assert Ok(id) = lobby.create_game(actor, "host", multiplayer)
  should.equal(lobby.join_game(actor, id, "alice"), Ok(True))
  should.equal(lobby.join_game(actor, id, "bob"), Ok(True))
  let assert Ok(lobby.Open(lobby.Lobby(players:, ..))) =
    lobby.get_game(actor, id)
  let assert Ok(player.Player(_, host_color)) = dict.get(players, "host")
  let assert Ok(player.Player(_, alice_color)) = dict.get(players, "alice")
  let assert Ok(player.Player(_, bob_color)) = dict.get(players, "bob")
  should.not_equal(host_color, alice_color)
  should.not_equal(host_color, bob_color)
  should.not_equal(alice_color, bob_color)
  list.each([host_color, alice_color, bob_color], fn(color) {
    should.equal(list.contains(player.all_colors, color), True)
  })
}

pub fn two_player_game_requires_two_and_retains_settings_when_started_test() {
  let actor = lobby.start()
  let settings =
    shared_game.Settings(9, shared_game.TwoPlayerGame, shared_game.Cooldown(3))
  let assert Ok(id) = lobby.create_game(actor, "host", settings)
  should.equal(lobby.start_game(actor, id, "host"), Ok(False))
  should.equal(lobby.join_game(actor, id, "alice"), Ok(True))
  should.equal(lobby.join_game(actor, id, "bob"), Ok(False))
  should.equal(lobby.start_game(actor, id, "alice"), Error(lobby.NotHost))
  should.equal(lobby.start_game(actor, id, "host"), Ok(True))
  let assert Ok(lobby.Running(host: "host", subject:, ..)) =
    lobby.get_game(actor, id)
  let snapshot = game.get_game(subject)
  should.equal(snapshot.settings, settings)
  should.equal(snapshot.board.board_size, 9)
  should.equal(dict.size(snapshot.players), 2)
  list.each(dict.values(snapshot.players), fn(p) {
    should.equal(list.contains(player.two_player_colors, p.color), True)
  })
  should.equal(
    dict.get(lobby.list_games(actor), id),
    Ok(lobby.Metadata(shared_game.Started, 2, settings)),
  )
}

pub fn leaving_a_full_multiplayer_game_frees_its_color_test() {
  let actor = lobby.start()
  let assert Ok(id) = lobby.create_game(actor, "host", multiplayer)
  list.each(list.range(1, 7), fn(i) {
    should.equal(lobby.join_game(actor, id, "p" <> int.to_string(i)), Ok(True))
  })
  should.equal(lobby.join_game(actor, id, "p8"), Ok(False))
  should.equal(lobby.join_game(actor, id, "host"), Ok(True))
  let assert Ok(lobby.Open(before)) = lobby.get_game(actor, id)
  let assert Ok(departing) = dict.get(before.players, "p3")
  should.equal(lobby.leave_game(actor, id, "p3"), Ok(Nil))
  should.equal(lobby.join_game(actor, id, "p8"), Ok(True))
  let assert Ok(lobby.Open(after)) = lobby.get_game(actor, id)
  let assert Ok(replacement) = dict.get(after.players, "p8")
  should.equal(replacement.color, departing.color)
  should.equal(dict.has_key(after.players, "p3"), False)
  should.equal(lobby.kick_player(actor, id, "host", "p8"), Ok(Nil))
  should.equal(lobby.join_game(actor, id, "p8"), Error(lobby.Kicked))
  should.equal(lobby.join_game(actor, id, "p9"), Ok(True))
  let assert Ok(lobby.Open(kicked)) = lobby.get_game(actor, id)
  let assert Ok(new_player) = dict.get(kicked.players, "p9")
  should.equal(new_player.color, departing.color)
}

pub fn invalid_settings_do_not_create_a_room_test() {
  let actor = lobby.start()
  let invalid =
    shared_game.Settings(..shared_game.default_settings, board_size: 0)
  should.equal(
    lobby.create_game(actor, "host", invalid),
    Error(lobby.InvalidSettings),
  )
  should.equal(dict.size(lobby.list_games(actor)), 0)
}
