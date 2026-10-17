import gleam/dict
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/list
import gleeunit/should
import rtgo_server/game as running_game
import rtgo_server/lobby
import rtgo_server/players
import rtgo_server/test_support.{read_json, test_sign_key}
import rtgo_shared/auth
import rtgo_shared/auth_api
import rtgo_shared/game
import rtgo_shared/lobby_api
import rtgo_shared/player

const url = "https://rtgo.test"

const multi = game.Settings(9, game.MultiplayerGame, game.Cooldown(2))

type Send =
  fn(request.Request(String)) -> response.Response(String)

fn server() -> Send {
  let users = players.start(test_sign_key())
  let rooms = lobby.start()
  test_support.send(_, users, rooms)
}

fn register(send: Send, name: String, color: player.Color) -> String {
  let auth.LogInResponse(jwt) =
    auth_api.register_request_with_color(url, name, color)
    |> send
    |> read_json(auth.log_in_response_decoder)
  jwt
}

fn create(send: Send, jwt: String, settings: game.Settings) -> String {
  let lobby_api.CreateGameResponse(id) =
    lobby_api.create_game_request(url, jwt, settings)
    |> send
    |> read_json(lobby_api.create_game_response_decoder)
  id
}

fn details(send: Send, id: String) -> lobby_api.GameDetails {
  let lobby_api.GetGameResponse(details) =
    lobby_api.game_request(url, id)
    |> send
    |> read_json(lobby_api.get_game_response_decoder)
  details
}

pub fn preferred_color_survives_login_and_updates_only_the_authenticated_account_test() {
  let send = server()
  let alice = register(send, "alice", player.Blue)
  let bob = register(send, "bob", player.Green)
  should.equal(
    auth_api.preferred_color_request(url, alice)
      |> send
      |> read_json(auth_api.preferred_color_decoder),
    player.Blue,
  )
  should.equal(
    send(auth_api.register_request_with_color(url, "alice", player.Pink)).status,
    409,
  )
  let auth.LogInResponse(renewed) =
    auth_api.log_in_request(url, alice)
    |> send
    |> read_json(auth.log_in_response_decoder)
  should.equal(
    auth_api.preferred_color_request(url, renewed)
      |> send
      |> read_json(auth_api.preferred_color_decoder),
    player.Blue,
  )
  let saved =
    auth_api.set_preferred_color_request(url, renewed, player.Purple)
    |> request.set_body("{\"preferred_color\":\"purple\",\"username\":\"bob\"}")
    |> send
    |> read_json(auth_api.preferred_color_decoder)
  should.equal(saved, player.Purple)
  should.equal(
    auth_api.preferred_color_request(url, bob)
      |> send
      |> read_json(auth_api.preferred_color_decoder),
    player.Green,
  )
  let room = create(send, renewed, multi)
  should.equal(dict.get(details(send, room).colors, "alice"), Ok(player.Purple))
}

pub fn joining_prefers_free_color_and_randomly_falls_back_without_recoloring_existing_members_test() {
  let send = server()
  let host = register(send, "host", player.Cyan)
  let guest = register(send, "guest", player.Cyan)
  let id = create(send, host, multi)
  should.equal(dict.get(details(send, id).colors, "host"), Ok(player.Cyan))
  should.equal(send(lobby_api.join_game_request(url, id, guest)).status, 200)
  let first = details(send, id)
  let assert Ok(assigned) = dict.get(first.colors, "guest")
  should.not_equal(assigned, player.Cyan)
  should.equal(list.contains(player.all_colors, assigned), True)
  should.equal(
    send(auth_api.set_preferred_color_request(url, guest, player.Cyan)).status,
    200,
  )
  should.equal(send(lobby_api.join_game_request(url, id, guest)).status, 200)
  should.equal(details(send, id).colors, first.colors)
  should.equal(send(lobby_api.leave_game_request(url, id, guest)).status, 204)
  should.equal(
    send(lobby_api.choose_color_request(url, id, host, player.White)).status,
    204,
  )
  should.equal(send(lobby_api.join_game_request(url, id, guest)).status, 200)
  should.equal(dict.get(details(send, id).colors, "guest"), Ok(player.Cyan))
}

pub fn members_can_choose_only_free_colors_for_themselves_before_start_test() {
  let send = server()
  let host = register(send, "host", player.Black)
  let guest = register(send, "guest", player.White)
  let stranger = register(send, "stranger", player.Cyan)
  let id = create(send, host, multi)
  should.equal(send(lobby_api.join_game_request(url, id, guest)).status, 200)
  should.equal(
    send(lobby_api.choose_color_request(url, id, stranger, player.Pink)).status,
    404,
  )
  should.equal(
    send(lobby_api.choose_color_request(url, id, guest, player.Black)).status,
    409,
  )
  should.equal(
    send(lobby_api.choose_color_request(url, id, guest, player.White)).status,
    204,
  )
  let forged_target =
    lobby_api.choose_color_request(url, id, guest, player.Purple)
    |> request.set_body("{\"color\":\"purple\",\"player\":\"host\"}")
    |> send
  should.equal(forged_target.status, 204)
  let chosen = details(send, id)
  should.equal(
    chosen.colors,
    dict.from_list([#("host", player.Black), #("guest", player.Purple)]),
  )
  // Per-game choice does not silently change the saved account preference.
  should.equal(
    auth_api.preferred_color_request(url, guest)
      |> send
      |> read_json(auth_api.preferred_color_decoder),
    player.White,
  )
  should.equal(
    send(lobby_api.choose_color_request(url, id, host, player.White)).status,
    204,
  )
  should.equal(send(lobby_api.start_game_request(url, id, host)).status, 200)
  should.equal(
    send(lobby_api.choose_color_request(url, id, guest, player.Cyan)).status,
    409,
  )
  should.equal(dict.get(details(send, id).colors, "guest"), Ok(player.Purple))
}

pub fn two_player_games_keep_black_and_white_even_with_other_preferences_test() {
  let send = server()
  let host = register(send, "host", player.White)
  let guest = register(send, "guest", player.Blue)
  let id = create(send, host, game.default_settings)
  should.equal(dict.get(details(send, id).colors, "host"), Ok(player.White))
  should.equal(send(lobby_api.join_game_request(url, id, guest)).status, 200)
  should.equal(
    details(send, id).colors,
    dict.from_list([#("host", player.White), #("guest", player.Black)]),
  )
  should.equal(
    send(lobby_api.choose_color_request(url, id, guest, player.Purple)).status,
    400,
  )
  should.equal(
    send(lobby_api.choose_color_request(url, id, guest, player.White)).status,
    409,
  )
}

pub fn competing_color_claims_are_atomic_and_start_retains_the_chosen_colors_test() {
  let actor = lobby.start()
  let assert Ok(id) =
    lobby.create_game_with_preference(actor, "host", multi, player.Black)
  should.equal(
    lobby.join_game_with_preference(actor, id, "guest", player.White),
    Ok(True),
  )
  should.equal(lobby.choose_color(actor, id, "host", player.Pink), Ok(Nil))
  should.equal(
    lobby.choose_color(actor, id, "guest", player.Pink),
    Error(lobby.ColorTaken),
  )
  should.equal(lobby.choose_color(actor, id, "guest", player.Black), Ok(Nil))
  should.equal(lobby.start_game(actor, id, "host"), Ok(True))
  let assert Ok(lobby.Running(subject:, ..)) = lobby.get_game(actor, id)
  let snapshot = running_game.get_game(subject)
  should.equal(
    dict.get(snapshot.players, "host"),
    Ok(player.Player("host", player.Pink)),
  )
  should.equal(
    dict.get(snapshot.players, "guest"),
    Ok(player.Player("guest", player.Black)),
  )
}

pub fn simultaneous_color_claims_have_only_one_winner_test() {
  let actor = lobby.start()
  let assert Ok(id) =
    lobby.create_game_with_preference(actor, "host", multi, player.Black)
  let assert Ok(True) =
    lobby.join_game_with_preference(actor, id, "guest", player.White)
  let replies = process.new_subject()
  list.each(["host", "guest"], fn(name) {
    let _ =
      process.spawn(fn() {
        process.send(replies, lobby.choose_color(actor, id, name, player.Blue))
      })
    Nil
  })
  let assert Ok(first) = process.receive(replies, 1000)
  let assert Ok(second) = process.receive(replies, 1000)
  should.equal(
    case first, second {
      Ok(Nil), Error(lobby.ColorTaken) | Error(lobby.ColorTaken), Ok(Nil) ->
        True
      _, _ -> False
    },
    True,
  )
  let assert Ok(lobby.Open(room)) = lobby.get_game(actor, id)
  should.equal(
    room.players
      |> dict.values
      |> list.filter(fn(p) { p.color == player.Blue })
      |> list.length,
    1,
  )
}

pub fn color_apis_validate_input_and_authentication_test() {
  let send = server()
  let host = register(send, "host", player.Black)
  let id = create(send, host, multi)
  list.each(["", "not-a-jwt"], fn(jwt) {
    list.each(
      [
        auth_api.preferred_color_request(url, jwt),
        auth_api.set_preferred_color_request(url, jwt, player.Cyan),
        lobby_api.choose_color_request(url, id, jwt, player.Cyan),
      ],
      fn(req) { should.equal(send(req).status, 401) },
    )
  })
  list.each(["\"red\"", "42", "null"], fn(value) {
    should.equal(
      auth_api.set_preferred_color_request(url, host, player.Black)
        |> request.set_body("{\"preferred_color\":" <> value <> "}")
        |> send
        |> fn(res) { res.status },
      400,
    )
    should.equal(
      lobby_api.choose_color_request(url, id, host, player.Black)
        |> request.set_body("{\"color\":" <> value <> "}")
        |> send
        |> fn(res) { res.status },
      400,
    )
  })
  should.equal(
    send(lobby_api.choose_color_request(url, "missing", host, player.Cyan)).status,
    404,
  )
  let legacy =
    auth_api.register_request(url, "legacy")
    |> request.set_body("{\"username\":\"legacy\"}")
    |> send
    |> read_json(auth.log_in_response_decoder)
  should.equal(
    auth_api.preferred_color_request(url, legacy.jwt)
      |> send
      |> read_json(auth_api.preferred_color_decoder),
    player.Black,
  )
  should.equal(
    send(
      auth_api.register_request(url, "invalid")
      |> request.set_body(
        "{\"username\":\"invalid\",\"preferred_color\":\"red\"}",
      ),
    ).status,
    400,
  )
}
