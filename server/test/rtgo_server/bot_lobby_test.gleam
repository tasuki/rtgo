import gleam/dict
import gleam/list
import gleeunit/should
import rtgo_server/lobby
import rtgo_server/players
import rtgo_server/test_support
import rtgo_shared/bot
import rtgo_shared/game
import rtgo_shared/player

pub fn only_host_can_add_bots_and_they_use_normal_seats_test() {
  let rooms = lobby.start()
  let assert Ok(id) = lobby.create_game(rooms, "host", game.default_settings)
  should.equal(lobby.add_bot(rooms, id, "outsider"), Error(lobby.NotHost))
  should.equal(
    lobby.add_bot(rooms, "missing", "host"),
    Error(lobby.GameNotFound),
  )
  should.equal(lobby.add_bot(rooms, id, "host"), Ok(Nil))
  should.equal(lobby.add_bot(rooms, id, "host"), Error(lobby.RoomFull))
  let assert Ok(lobby.Open(room)) = lobby.get_game(rooms, id)
  let assert Ok(name) = dict.keys(room.players) |> list.find(bot.is_bot)
  should.equal(
    dict.get(room.players, name),
    Ok(player.Player(name, player.White)),
  )
  should.equal(
    dict.get(lobby.player_cooldowns(room), name),
    Ok(game.base_cooldown(room.settings)),
  )
  should.equal(lobby.set_player_cooldown(rooms, id, "host", name, 60), Ok(Nil))
  should.equal(lobby.kick_player(rooms, id, "host", name), Ok(Nil))
  should.equal(lobby.add_bot(rooms, id, "host"), Ok(Nil))
  let assert Ok(lobby.Open(replaced)) = lobby.get_game(rooms, id)
  should.equal(dict.has_key(replaced.players, name), False)
  should.equal(dict.size(replaced.players), 2)
}

pub fn multiplayer_bots_fill_only_available_colors_test() {
  let rooms = lobby.start()
  let settings =
    game.Settings(..game.default_settings, game_type: game.MultiplayerGame)
  let assert Ok(id) = lobby.create_game(rooms, "host", settings)
  list.each(list.range(1, 7), fn(_) {
    should.equal(lobby.add_bot(rooms, id, "host"), Ok(Nil))
  })
  should.equal(lobby.add_bot(rooms, id, "host"), Error(lobby.RoomFull))
  let assert Ok(lobby.Open(room)) = lobby.get_game(rooms, id)
  let colors =
    dict.values(room.players) |> list.map(fn(p) { p.color }) |> list.unique
  should.equal(list.length(colors), 8)
  should.equal(lobby.cancel_game(rooms, id, "host"), Ok(Nil))
}

pub fn bots_cannot_be_added_after_start_test() {
  let rooms = lobby.start()
  let assert Ok(id) = lobby.create_game(rooms, "host", game.default_settings)
  let assert Ok(True) = lobby.join_game(rooms, id, "guest")
  let assert Ok(True) = lobby.start_game(rooms, id, "host")
  should.equal(lobby.add_bot(rooms, id, "host"), Error(lobby.AlreadyStarted))
}

pub fn bot_identity_prefix_cannot_be_registered_by_a_human_test() {
  let users = players.start(test_support.test_sign_key())
  players.try_register(users, bot.name_prefix <> "fake") |> should.be_error
  players.try_register(users, "human") |> should.be_ok
}
