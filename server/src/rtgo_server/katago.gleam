import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import rtgo_shared/go

@external(erlang, "rtgo_katago_ffi", "start")
pub fn start() -> Result(Nil, Nil)

@external(erlang, "rtgo_katago_ffi", "available")
pub fn available() -> Bool

@external(erlang, "rtgo_katago_ffi", "analyse")
fn analyse(query: String) -> Result(String, Nil)

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

const columns = "ABCDEFGHJKLMNOPQRST"

pub fn vertex(point: go.Point, size: Int) -> String {
  let #(x, y) = point
  string.slice(columns, x, 1) <> int.to_string(size - y)
}

/// A fresh setup position, not a fabricated alternating move history.
fn position(
  board: go.Game,
  name: String,
  id: String,
) -> List(#(String, json.Json)) {
  let stones =
    board.stones
    |> dict.to_list
    |> list.map(fn(entry) {
      let #(point, player) = entry
      json.array(
        [
          case player.username == name {
            True -> "B"
            False -> "W"
          },
          vertex(point, board.board_size),
        ],
        json.string,
      )
    })
  [
    #("id", json.string(id)),
    #("initialStones", json.array(stones, fn(s) { s })),
    #("initialPlayer", json.string("B")),
    #("moves", json.array([], json.string)),
    #("rules", json.string("tromp-taylor")),
    #("komi", json.int(0)),
    #("boardXSize", json.int(board.board_size)),
    #("boardYSize", json.int(board.board_size)),
    #("maxVisits", json.int(1)),
  ]
}

pub fn query(board: go.Game, name: String, id: String) -> String {
  position(board, name, id)
  |> list.append([#("includePolicy", json.bool(True))])
  |> json.object
  |> json.to_string
}

fn number_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.map(decode.int, int.to_float)])
}

pub fn ownership_query(board: go.Game, name: String, id: String) -> String {
  position(board, name, id)
  |> list.append([
    #("includeOwnership", json.bool(True)),
    // The projected player is always black and to move.
    #(
      "overrideSettings",
      json.object([
        #("reportAnalysisWinratesAs", json.string("BLACK")),
        // One raw NN evaluation, with no symmetry averaging.
        #("rootNumSymmetriesToSample", json.int(1)),
      ]),
    ),
  ])
  |> json.object
  |> json.to_string
}

pub fn ownership_response(
  body: String,
  size: Int,
) -> Result(dict.Dict(go.Point, Float), Nil) {
  let decoder = {
    use ownership <- decode.field("ownership", decode.list(number_decoder()))
    decode.success(ownership)
  }
  use ownership <- result.try(
    json.parse(body, decoder) |> result.replace_error(Nil),
  )
  case
    list.length(ownership) == size * size
    && list.all(ownership, fn(value) { value >=. -1.0 && value <=. 1.0 })
  {
    False -> Error(Nil)
    True ->
      Ok(
        ownership
        |> list.index_map(fn(value, i) { #(#(i % size, i / size), value) })
        |> dict.from_list,
      )
  }
}

pub fn ownership(
  board: go.Game,
  name: String,
) -> Result(dict.Dict(go.Point, Float), Nil) {
  use body <- result.try(
    ownership_query(board, name, int.to_string(unique_integer())) |> analyse,
  )
  ownership_response(body, board.board_size)
}

pub fn response(body: String, size: Int) -> Result(Option(go.Point), Nil) {
  let probability = number_decoder()
  let decoder = {
    use policy <- decode.field("policy", decode.list(probability))
    decode.success(policy)
  }
  use policy <- result.try(
    json.parse(body, decoder) |> result.replace_error(Nil),
  )
  case list.length(policy) == size * size + 1 {
    False -> Error(Nil)
    True -> {
      // One visit evaluates only the root, so moveInfos is empty. Use the
      // network's policy directly: row-major intersections, followed by pass.
      // KataGo marks its illegal moves -1. No RTGO reranking or fallback moves.
      let #(index, _) =
        policy
        |> list.index_map(fn(p, i) { #(i, p) })
        |> list.fold(#(-1, -1.0), fn(best, candidate) {
          case candidate.1 >. best.1 {
            True -> candidate
            False -> best
          }
        })
      case index {
        -1 -> Error(Nil)
        i if i == size * size -> Ok(None)
        i -> Ok(Some(#(i % size, i / size)))
      }
    }
  }
}

pub fn move(board: go.Game, name: String) -> Result(Option(go.Point), Nil) {
  use body <- result.try(
    query(board, name, int.to_string(unique_integer())) |> analyse,
  )
  response(body, board.board_size)
}
