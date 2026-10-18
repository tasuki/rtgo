import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/json
import gleam/list
import gleam/uri
import rtgo_shared/go
import rtgo_shared/player

/// cooldown_ms is the wait for the next placement (including bank/gap limits).
/// pass_in_ms is zero while passing, positive until auto-pass, or -1 when only
/// explicit passing applies. A pass never implies permission to bypass timing.
pub type PlayerStatus {
  PlayerStatus(player: player.Player, cooldown_ms: Int, pass_in_ms: Int)
}

pub type SavingsStatus {
  SavingsStatus(credits: Int, capacity: Int, recharge_ms: Int)
}

pub type ScoringStatus {
  NotScored
  Scoring
  Estimated
  Unavailable
}

pub type State {
  State(
    board: go.Game,
    players: List(PlayerStatus),
    finished: Bool,
    revision: Int,
    // -1 if an active player has no automatic pass deadline.
    end_in_ms: Int,
    scores: Dict(String, Int),
    scoring: ScoringStatus,
    dead_stones: List(go.Point),
    savings: Dict(String, SavingsStatus),
  )
}

pub fn state_request(server_url: String, id: String) -> request.Request(String) {
  let assert Ok(req) =
    request.to(server_url <> "/games/" <> uri.percent_encode(id) <> "/board")
  req |> request.set_method(Get)
}

pub fn move_request(
  server_url: String,
  id: String,
  jwt: String,
  point: go.Point,
) -> request.Request(String) {
  let assert Ok(req) =
    request.to(server_url <> "/games/" <> uri.percent_encode(id) <> "/moves")
  req
  |> request.set_method(Post)
  |> request.set_header("authorization", "Bearer " <> jwt)
  |> request.set_header("content-type", "application/json")
  |> request.set_body(
    json.to_string(
      json.object([#("x", json.int(point.0)), #("y", json.int(point.1))]),
    ),
  )
}

pub fn pass_request(
  server_url: String,
  id: String,
  jwt: String,
) -> request.Request(String) {
  let assert Ok(req) =
    request.to(server_url <> "/games/" <> uri.percent_encode(id) <> "/pass")
  req
  |> request.set_method(Post)
  |> request.set_header("authorization", "Bearer " <> jwt)
}

pub fn move_decoder() -> decode.Decoder(go.Point) {
  use x <- decode.field("x", decode.int)
  use y <- decode.field("y", decode.int)
  decode.success(#(x, y))
}

fn player_json(p: player.Player) -> json.Json {
  json.object([
    #("name", json.string(p.username)),
    #("color", json.string(player.color_to_str(p.color))),
  ])
}

fn player_decoder() -> decode.Decoder(player.Player) {
  use name <- decode.field("name", decode.string)
  use color <- decode.field("color", decode.string)
  case list.find(player.all_colors, fn(c) { player.color_to_str(c) == color }) {
    Ok(c) -> decode.success(player.Player(name, c))
    Error(_) ->
      decode.failure(player.Player(name, player.Black), "player color")
  }
}

pub fn state_to_json(state: State) -> json.Json {
  json.object([
    #("board_size", json.int(state.board.board_size)),
    #(
      "stones",
      json.array(dict.to_list(state.board.stones), fn(entry) {
        let #(point, p) = entry
        json.object([
          #("x", json.int(point.0)),
          #("y", json.int(point.1)),
          #("player", player_json(p)),
        ])
      }),
    ),
    #(
      "players",
      json.array(state.players, fn(status) {
        json.object([
          #("player", player_json(status.player)),
          #("cooldown_ms", json.int(status.cooldown_ms)),
          #("pass_in_ms", json.int(status.pass_in_ms)),
        ])
      }),
    ),
    #(
      "savings",
      json.dict(state.savings, fn(name) { name }, fn(bank) {
        json.object([
          #("credits", json.int(bank.credits)),
          #("capacity", json.int(bank.capacity)),
          #("recharge_ms", json.int(bank.recharge_ms)),
        ])
      }),
    ),
    #("finished", json.bool(state.finished)),
    #("revision", json.int(state.revision)),
    #("end_in_ms", json.int(state.end_in_ms)),
    #("scores", json.dict(state.scores, fn(name) { name }, json.int)),
    #(
      "scoring",
      json.string(case state.scoring {
        NotScored -> "not_scored"
        Scoring -> "pending"
        Estimated -> "estimated"
        Unavailable -> "unavailable"
      }),
    ),
    #(
      "dead_stones",
      json.array(state.dead_stones, fn(point) {
        json.object([#("x", json.int(point.0)), #("y", json.int(point.1))])
      }),
    ),
  ])
}

pub fn state_decoder() -> decode.Decoder(State) {
  use size <- decode.field("board_size", decode.int)
  use stones <- decode.field(
    "stones",
    decode.list({
      use point <- decode.then(move_decoder())
      use p <- decode.field("player", player_decoder())
      decode.success(#(point, p))
    }),
  )
  use players <- decode.field(
    "players",
    decode.list({
      use p <- decode.field("player", player_decoder())
      use cooldown <- decode.field("cooldown_ms", decode.int)
      use pass_in <- decode.field("pass_in_ms", decode.int)
      decode.success(PlayerStatus(p, cooldown, pass_in))
    }),
  )
  use savings <- decode.optional_field(
    "savings",
    dict.new(),
    decode.dict(decode.string, {
      use credits <- decode.field("credits", decode.int)
      use capacity <- decode.field("capacity", decode.int)
      use recharge <- decode.field("recharge_ms", decode.int)
      decode.success(SavingsStatus(credits, capacity, recharge))
    }),
  )
  use finished <- decode.field("finished", decode.bool)
  use revision <- decode.field("revision", decode.int)
  use end_in <- decode.field("end_in_ms", decode.int)
  use scores <- decode.field("scores", decode.dict(decode.string, decode.int))
  use scoring <- decode.field(
    "scoring",
    decode.then(decode.string, fn(value) {
      case value {
        "not_scored" -> decode.success(NotScored)
        "pending" -> decode.success(Scoring)
        "estimated" -> decode.success(Estimated)
        "unavailable" -> decode.success(Unavailable)
        _ -> decode.failure(NotScored, "scoring status")
      }
    }),
  )
  use dead_stones <- decode.field("dead_stones", decode.list(move_decoder()))
  let board = go.Game(..go.new_game(size), stones: dict.from_list(stones))
  decode.success(State(
    board,
    players,
    finished,
    revision,
    end_in,
    scores,
    scoring,
    dead_stones,
    savings,
  ))
}
