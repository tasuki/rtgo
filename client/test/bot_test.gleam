import gleam/dict
import gleam/http/response
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import lustre/element
import rsvp
import rtgo_client as app
import rtgo_client/player_info
import rtgo_shared/game
import rtgo_shared/lobby_api
import rtgo_shared/player

fn room(name: String) -> app.Model {
  let model =
    app.initial_model(
      app.Play("room"),
      player_info.LoggedIn(name, "jwt"),
      "https://rtgo.test",
    )
  app.Model(
    ..model,
    current_game: Some(lobby_api.GameDetails(
      "room",
      game.Negotiating,
      "host",
      ["host"],
      1,
      game.default_settings,
      dict.from_list([#("host", 5)]),
      dict.from_list([#("host", player.Black)]),
    )),
  )
}

pub fn room_actions_appear_above_players_test() {
  let html = room("host") |> app.view |> element.to_string
  let assert [before_players, _] = string.split(html, "<h2>Players</h2>")
  should.equal(string.contains(before_players, "Add KataGo bot"), True)
  should.equal(string.contains(before_players, "Start game"), True)
  should.equal(string.contains(before_players, "Cancel game"), True)
}

pub fn only_host_sees_and_can_add_bots_test() {
  let host = room("host")
  should.equal(
    host |> app.view |> element.to_string |> string.contains("Add KataGo bot"),
    True,
  )
  let guest = room("guest")
  should.equal(
    guest |> app.view |> element.to_string |> string.contains("Add KataGo bot"),
    False,
  )
  let #(adding, _) = app.update(host, app.AddBotPressed("room"))
  should.equal(adding.pending_action, True)
  let #(unchanged, _) = app.update(guest, app.AddBotPressed("room"))
  should.equal(unchanged, guest)
  let #(unchanged, _) = app.update(adding, app.AddBotPressed("room"))
  should.equal(unchanged, adding)
}

pub fn unavailable_engine_error_is_visible_and_stale_responses_are_ignored_test() {
  let host = room("host")
  let #(adding, _) = app.update(host, app.AddBotPressed("room"))
  let error =
    rsvp.HttpError(
      response.new(503)
      |> response.set_body(
        "{\"msg\":\"KataGo is not installed on this server\"}",
      ),
    )
  let #(failed, _) =
    app.update(adding, app.BotAdded(adding.page_version, Error(error)))
  should.equal(failed.pending_action, False)
  should.equal(
    failed.action_error,
    Some("KataGo is not installed on this server"),
  )
  let #(unchanged, _) =
    app.update(adding, app.BotAdded(adding.page_version - 1, Ok(Nil)))
  should.equal(unchanged, adding)
  let #(refreshed, _) =
    app.update(adding, app.BotAdded(adding.page_version, Ok(Nil)))
  should.equal(refreshed.pending_action, False)
  should.equal(refreshed.loading_game, True)
}
