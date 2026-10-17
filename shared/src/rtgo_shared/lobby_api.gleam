import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/json
import gleam/uri
import rtgo_shared/game
import rtgo_shared/player

pub const games_path = "/games"

pub type GameMetadata {
  GameMetadata(
    id: String,
    phase: game.GamePhase,
    player_count: Int,
    settings: game.Settings,
  )
}

pub type GameDetails {
  GameDetails(
    id: String,
    phase: game.GamePhase,
    host: String,
    players: List(String),
    player_count: Int,
    settings: game.Settings,
    cooldowns: Dict(String, Int),
    colors: Dict(String, player.Color),
  )
}

pub type ListGamesResponse {
  ListGamesResponse(games: List(GameMetadata))
}

pub type CreateGameResponse {
  CreateGameResponse(id: String)
}

pub type GetGameResponse {
  GetGameResponse(game: GameDetails)
}

pub type JoinGameResponse {
  JoinGameResponse(joined: Bool)
}

pub type StartGameResponse {
  StartGameResponse(started: Bool)
}

pub fn games_request(server_url: String) -> request.Request(String) {
  let assert Ok(uri) = uri.parse(server_url <> games_path)
  let assert Ok(req) = request.from_uri(uri)
  req |> request.set_method(Get)
}

pub fn create_game_request(
  server_url: String,
  jwt: String,
  settings: game.Settings,
) -> request.Request(String) {
  authenticated_request(server_url <> games_path, jwt)
  |> request.set_header("content-type", "application/json")
  |> request.set_body(json.to_string(game.settings_to_json(settings)))
}

pub fn game_request(server_url: String, id: String) -> request.Request(String) {
  let assert Ok(uri) = uri.parse(server_url <> games_path <> "/" <> id)
  let assert Ok(req) = request.from_uri(uri)
  req |> request.set_method(Get)
}

pub fn join_game_request(
  server_url: String,
  id: String,
  jwt: String,
) -> request.Request(String) {
  authenticated_request(server_url <> games_path <> "/" <> id <> "/join", jwt)
}

pub fn start_game_request(
  server_url: String,
  id: String,
  jwt: String,
) -> request.Request(String) {
  authenticated_request(server_url <> games_path <> "/" <> id <> "/start", jwt)
}

pub fn leave_game_request(
  server_url: String,
  id: String,
  jwt: String,
) -> request.Request(String) {
  authenticated_request(server_url <> games_path <> "/" <> id <> "/leave", jwt)
}

pub fn cancel_game_request(
  server_url: String,
  id: String,
  jwt: String,
) -> request.Request(String) {
  authenticated_request(server_url <> games_path <> "/" <> id <> "/cancel", jwt)
}

pub fn kick_player_request(
  server_url: String,
  id: String,
  jwt: String,
  player: String,
) -> request.Request(String) {
  authenticated_json_request(
    server_url <> games_path <> "/" <> id <> "/kick",
    jwt,
    json.object([#("player", json.string(player))]),
  )
}

pub fn kick_player_request_decoder() -> decode.Decoder(String) {
  use player <- decode.field("player", decode.string)
  decode.success(player)
}

pub fn choose_color_request(
  server_url: String,
  id: String,
  jwt: String,
  color: player.Color,
) -> request.Request(String) {
  authenticated_json_request(
    server_url <> games_path <> "/" <> id <> "/color",
    jwt,
    json.object([#("color", player.color_to_json(color))]),
  )
}

pub fn choose_color_decoder() -> decode.Decoder(player.Color) {
  use color <- decode.field("color", player.color_decoder())
  decode.success(color)
}

pub fn player_cooldown_request(
  server_url: String,
  id: String,
  jwt: String,
  player: String,
  seconds: Int,
) -> request.Request(String) {
  authenticated_json_request(
    server_url <> games_path <> "/" <> id <> "/cooldown",
    jwt,
    json.object([
      #("player", json.string(player)),
      #("cooldown_seconds", json.int(seconds)),
    ]),
  )
}

pub fn player_cooldown_request_decoder() -> decode.Decoder(#(String, Int)) {
  use player <- decode.field("player", decode.string)
  use seconds <- decode.field("cooldown_seconds", decode.int)
  decode.success(#(player, seconds))
}

fn authenticated_json_request(
  url: String,
  jwt: String,
  body: json.Json,
) -> request.Request(String) {
  authenticated_request(url, jwt)
  |> request.set_header("content-type", "application/json")
  |> request.set_body(json.to_string(body))
}

fn authenticated_request(url: String, jwt: String) -> request.Request(String) {
  let assert Ok(uri) = uri.parse(url)
  let assert Ok(req) = request.from_uri(uri)
  req
  |> request.set_method(Post)
  |> request.set_header("authorization", "Bearer " <> jwt)
}

fn phase_to_json(phase: game.GamePhase) -> json.Json {
  case phase {
    game.Negotiating -> json.string("negotiating")
    game.Started -> json.string("started")
    game.Finished -> json.string("finished")
  }
}

fn phase_decoder() -> decode.Decoder(game.GamePhase) {
  decode.then(decode.string, fn(phase) {
    case phase {
      "negotiating" -> decode.success(game.Negotiating)
      "started" -> decode.success(game.Started)
      "finished" -> decode.success(game.Finished)
      _ -> decode.failure(game.Negotiating, "game phase")
    }
  })
}

pub fn game_metadata_to_json(metadata: GameMetadata) -> json.Json {
  let GameMetadata(id:, phase:, player_count:, settings:) = metadata
  json.object([
    #("id", json.string(id)),
    #("phase", phase_to_json(phase)),
    #("player_count", json.int(player_count)),
    #("settings", game.settings_to_json(settings)),
  ])
}

pub fn game_metadata_decoder() -> decode.Decoder(GameMetadata) {
  use id <- decode.field("id", decode.string)
  use phase <- decode.field("phase", phase_decoder())
  use player_count <- decode.field("player_count", decode.int)
  use settings <- decode.field("settings", game.settings_decoder())
  decode.success(GameMetadata(id:, phase:, player_count:, settings:))
}

pub fn game_details_to_json(details: GameDetails) -> json.Json {
  let GameDetails(
    id:,
    phase:,
    host:,
    players:,
    player_count:,
    settings:,
    cooldowns:,
    colors:,
  ) = details
  json.object([
    #("id", json.string(id)),
    #("phase", phase_to_json(phase)),
    #("host", json.string(host)),
    #("players", json.array(players, json.string)),
    #("cooldowns", json.dict(cooldowns, fn(name) { name }, json.int)),
    #("colors", json.dict(colors, fn(name) { name }, player.color_to_json)),
    #("player_count", json.int(player_count)),
    #("settings", game.settings_to_json(settings)),
  ])
}

pub fn game_details_decoder() -> decode.Decoder(GameDetails) {
  use id <- decode.field("id", decode.string)
  use phase <- decode.field("phase", phase_decoder())
  use host <- decode.field("host", decode.string)
  use players <- decode.field("players", decode.list(decode.string))
  use cooldowns <- decode.field(
    "cooldowns",
    decode.dict(decode.string, decode.int),
  )
  use colors <- decode.field(
    "colors",
    decode.dict(decode.string, player.color_decoder()),
  )
  use player_count <- decode.field("player_count", decode.int)
  use settings <- decode.field("settings", game.settings_decoder())
  decode.success(GameDetails(
    id:,
    phase:,
    host:,
    players:,
    player_count:,
    settings:,
    cooldowns:,
    colors:,
  ))
}

pub fn list_games_response_to_json(response: ListGamesResponse) -> json.Json {
  let ListGamesResponse(games:) = response
  json.object([#("games", json.array(games, game_metadata_to_json))])
}

pub fn list_games_response_decoder() -> decode.Decoder(ListGamesResponse) {
  use games <- decode.field("games", decode.list(game_metadata_decoder()))
  decode.success(ListGamesResponse(games:))
}

pub fn create_game_response_to_json(response: CreateGameResponse) -> json.Json {
  let CreateGameResponse(id:) = response
  json.object([#("id", json.string(id))])
}

pub fn create_game_response_decoder() -> decode.Decoder(CreateGameResponse) {
  use id <- decode.field("id", decode.string)
  decode.success(CreateGameResponse(id:))
}

pub fn get_game_response_to_json(response: GetGameResponse) -> json.Json {
  let GetGameResponse(game:) = response
  json.object([#("game", game_details_to_json(game))])
}

pub fn get_game_response_decoder() -> decode.Decoder(GetGameResponse) {
  use game <- decode.field("game", game_details_decoder())
  decode.success(GetGameResponse(game:))
}

pub fn join_game_response_to_json(response: JoinGameResponse) -> json.Json {
  let JoinGameResponse(joined:) = response
  json.object([#("joined", json.bool(joined))])
}

pub fn join_game_response_decoder() -> decode.Decoder(JoinGameResponse) {
  use joined <- decode.field("joined", decode.bool)
  decode.success(JoinGameResponse(joined:))
}

pub fn start_game_response_to_json(response: StartGameResponse) -> json.Json {
  let StartGameResponse(started:) = response
  json.object([#("started", json.bool(started))])
}

pub fn start_game_response_decoder() -> decode.Decoder(StartGameResponse) {
  use started <- decode.field("started", decode.bool)
  decode.success(StartGameResponse(started:))
}
