import gleam/dict
import gleam/json
import gleam/list
import gleeunit/should
import rtgo_shared/auth
import rtgo_shared/game
import rtgo_shared/lobby_api
import rtgo_shared/player

pub fn color_names_and_json_round_trip_test() {
  list.each(player.all_colors, fn(color) {
    should.equal(player.color_from_name(player.color_name(color)), Ok(color))
    should.equal(
      color
        |> player.color_to_json
        |> json.to_string
        |> json.parse(player.color_decoder()),
      Ok(color),
    )
  })
  should.equal(player.color_from_name("red"), Error(Nil))
  list.each(["\"red\"", "42", "null"], fn(text) {
    json.parse(text, player.color_decoder()) |> should.be_error
  })
}

pub fn registration_color_is_optional_for_old_clients_but_validated_test() {
  should.equal(
    json.parse("{\"username\":\"alice\"}", auth.registration_request_decoder()),
    Ok(auth.RegistrationRequest("alice", player.Black)),
  )
  let request = auth.RegistrationRequest("alice", player.Pink)
  should.equal(
    request
      |> auth.registration_request_to_json
      |> json.to_string
      |> json.parse(auth.registration_request_decoder()),
    Ok(request),
  )
  json.parse(
    "{\"username\":\"alice\",\"preferred_color\":\"red\"}",
    auth.registration_request_decoder(),
  )
  |> should.be_error
}

pub fn room_details_round_trip_player_colors_test() {
  let colors =
    dict.from_list([#("alice", player.Purple), #("bob", player.Cyan)])
  let settings = game.Settings(9, game.MultiplayerGame, game.Cooldown(2))
  let details =
    lobby_api.GameDetails(
      "room",
      game.Negotiating,
      "alice",
      ["alice", "bob"],
      2,
      settings,
      game.default_cooldowns(["alice", "bob"], settings),
      colors,
    )
  should.equal(
    details
      |> lobby_api.game_details_to_json
      |> json.to_string
      |> json.parse(lobby_api.game_details_decoder()),
    Ok(details),
  )
}
