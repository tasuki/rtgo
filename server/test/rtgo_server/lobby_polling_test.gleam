import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleeunit/should
import rtgo_server/game
import rtgo_server/lobby
import rtgo_server/players
import rtgo_server/test_support
import rtgo_shared/game as settings
import rtgo_shared/lobby_api

pub fn concurrent_lobby_requests_with_long_game_histories_test() {
  let rooms = lobby.start()
  let users = players.start(test_support.test_sign_key())
  let config = settings.Settings(19, settings.TwoPlayerGame, settings.DragDerby)
  let ids =
    list.map(list.range(1, 7), fn(index) {
      let host = "polling-host-" <> int.to_string(index)
      let assert Ok(id) = lobby.create_game(rooms, host, config)
      should.equal(lobby.join_game(rooms, id, "guest"), Ok(True))
      should.equal(lobby.start_game(rooms, id, host), Ok(True))
      let assert Ok(lobby.Running(subject:, ..)) = lobby.get_game(rooms, id)
      // Hundreds of positions per room used to be copied into the lobby actor on
      // every listing, causing overlapping browser polls to exceed its 100ms call.
      list.each(list.range(0, 299), fn(point) {
        should.equal(
          game.play(subject, host, #(point % 19, point / 19)),
          Ok(Nil),
        )
      })
      id
    })
  let replies = process.new_subject()
  list.each(list.range(1, 16), fn(_) {
    let _ =
      process.spawn_unlinked(fn() {
        let response =
          lobby_api.games_request("https://rtgo.test")
          |> test_support.send(users, rooms)
        let decoded =
          json.parse(response.body, lobby_api.list_games_response_decoder())
        process.send(replies, #(response.status, decoded))
      })
    Nil
  })
  list.each(list.range(1, 16), fn(_) {
    let assert Ok(#(status, Ok(lobby_api.ListGamesResponse(games)))) =
      process.receive(replies, 5000)
    should.equal(status, 200)
    should.equal(list.length(games), 7)
    should.equal(
      dict.size(dict.from_list(list.map(games, fn(room) { #(room.id, Nil) }))),
      7,
    )
    list.each(games, fn(room) {
      should.equal(list.contains(ids, room.id), True)
      should.equal(room.player_count, 2)
      should.equal(room.settings, config)
    })
  })
}
