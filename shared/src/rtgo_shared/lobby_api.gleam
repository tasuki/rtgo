import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/json
import gleam/uri
import rtgo_shared/game

pub const games_path = "/games"

pub type CreateGameRequest {
  CreateGameRequest(username: String)
}

pub type JoinGameRequest {
  JoinGameRequest(username: String)
}

pub type StartGameRequest {
  StartGameRequest(username: String)
}

pub type GameMetadata {
  GameMetadata(id: String, phase: game.GamePhase, player_count: Int)
}

pub type GameDetails {
  GameDetails(
    id: String,
    phase: game.GamePhase,
    host: String,
    players: List(String),
    player_count: Int,
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
  username: String,
) -> request.Request(String) {
  let assert Ok(uri) = uri.parse(server_url <> games_path)
  let assert Ok(req) = request.from_uri(uri)

  req
  |> request.set_method(Post)
  |> request.set_header("content-type", "application/json")
  |> request.set_body(
    json.to_string(create_game_request_to_json(CreateGameRequest(username))),
  )
}

pub fn game_request(server_url: String, id: String) -> request.Request(String) {
  let assert Ok(uri) = uri.parse(server_url <> games_path <> "/" <> id)
  let assert Ok(req) = request.from_uri(uri)
  req |> request.set_method(Get)
}

pub fn join_game_request(
  server_url: String,
  id: String,
  username: String,
) -> request.Request(String) {
  let assert Ok(uri) =
    uri.parse(server_url <> games_path <> "/" <> id <> "/join")
  let assert Ok(req) = request.from_uri(uri)

  req
  |> request.set_method(Post)
  |> request.set_header("content-type", "application/json")
  |> request.set_body(
    json.to_string(join_game_request_to_json(JoinGameRequest(username))),
  )
}

pub fn start_game_request(
  server_url: String,
  id: String,
  username: String,
) -> request.Request(String) {
  let assert Ok(uri) =
    uri.parse(server_url <> games_path <> "/" <> id <> "/start")
  let assert Ok(req) = request.from_uri(uri)

  req
  |> request.set_method(Post)
  |> request.set_header("content-type", "application/json")
  |> request.set_body(
    json.to_string(start_game_request_to_json(StartGameRequest(username))),
  )
}

pub fn create_game_request_to_json(request: CreateGameRequest) -> json.Json {
  let CreateGameRequest(username:) = request
  json.object([#("username", json.string(username))])
}

pub fn create_game_request_decoder() -> decode.Decoder(CreateGameRequest) {
  use username <- decode.field("username", decode.string)
  decode.success(CreateGameRequest(username:))
}

pub fn join_game_request_to_json(request: JoinGameRequest) -> json.Json {
  let JoinGameRequest(username:) = request
  json.object([#("username", json.string(username))])
}

pub fn join_game_request_decoder() -> decode.Decoder(JoinGameRequest) {
  use username <- decode.field("username", decode.string)
  decode.success(JoinGameRequest(username:))
}

pub fn start_game_request_to_json(request: StartGameRequest) -> json.Json {
  let StartGameRequest(username:) = request
  json.object([#("username", json.string(username))])
}

pub fn start_game_request_decoder() -> decode.Decoder(StartGameRequest) {
  use username <- decode.field("username", decode.string)
  decode.success(StartGameRequest(username:))
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
  let GameMetadata(id:, phase:, player_count:) = metadata
  json.object([
    #("id", json.string(id)),
    #("phase", phase_to_json(phase)),
    #("player_count", json.int(player_count)),
  ])
}

pub fn game_metadata_decoder() -> decode.Decoder(GameMetadata) {
  use id <- decode.field("id", decode.string)
  use phase <- decode.field("phase", phase_decoder())
  use player_count <- decode.field("player_count", decode.int)
  decode.success(GameMetadata(id:, phase:, player_count:))
}

pub fn game_details_to_json(details: GameDetails) -> json.Json {
  let GameDetails(id:, phase:, host:, players:, player_count:) = details
  json.object([
    #("id", json.string(id)),
    #("phase", phase_to_json(phase)),
    #("host", json.string(host)),
    #("players", json.array(players, json.string)),
    #("player_count", json.int(player_count)),
  ])
}

pub fn game_details_decoder() -> decode.Decoder(GameDetails) {
  use id <- decode.field("id", decode.string)
  use phase <- decode.field("phase", phase_decoder())
  use host <- decode.field("host", decode.string)
  use players <- decode.field("players", decode.list(decode.string))
  use player_count <- decode.field("player_count", decode.int)
  decode.success(GameDetails(id:, phase:, host:, players:, player_count:))
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
