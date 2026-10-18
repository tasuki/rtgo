/// RTGO's versioned SGF extension. See docs/sgf.md for the on-disk contract.
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import rtgo_shared/go
import rtgo_shared/player

pub type Seat {
  Seat(id: String, player: player.Player, cooldown_ms: Int)
}

pub type Move {
  Move(seat: String, point: go.Point, at_ms: Int)
}

pub type Record {
  Record(
    size: Int,
    seats: List(Seat),
    // Newest first, so recording a move is constant time.
    moves: List(Move),
    finished_at: Option(Int),
    scoring: String,
    scores: Dict(String, Int),
    dead: List(go.Point),
    date: Option(String),
  )
}

pub type Frame {
  Frame(board: go.Game, move: Option(Move))
}

pub type Replay {
  Replay(record: Record, frames: List(Frame))
}

pub fn new(size: Int, seats: List(Seat)) -> Record {
  Record(size, seats, [], None, "pending", dict.new(), [], None)
}

fn escape(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("]", "\\]")
  |> string.replace(":", "\\:")
}

fn value(text: String) -> String {
  "[" <> escape(text) <> "]"
}

const letters = "abcdefghijklmnopqrstuvwxyz"

pub fn point_text(point: go.Point) -> String {
  string.slice(letters, point.0, 1) <> string.slice(letters, point.1, 1)
}

pub fn encode(record: Record) -> String {
  let roster =
    record.seats
    |> list.map(fn(seat) {
      "["
      <> escape(seat.id)
      <> ":"
      <> escape(seat.player.username)
      <> ":"
      <> player.color_name(seat.player.color)
      <> ":"
      <> int.to_string(seat.cooldown_ms)
      <> "]"
    })
    |> string.join("")
  let conventional = case record.seats {
    [a, b] if a.player.color == player.Black && b.player.color == player.White ->
      "PB" <> value(a.player.username) <> "PW" <> value(b.player.username)
    [a, b] if b.player.color == player.Black && a.player.color == player.White ->
      "PB" <> value(b.player.username) <> "PW" <> value(a.player.username)
    _ -> ""
  }
  let ending = case record.finished_at {
    None -> ""
    Some(ms) -> "RTEND" <> value(int.to_string(ms))
  }
  let scores =
    record.seats
    |> list.filter_map(fn(seat) {
      use score <- result.try(dict.get(record.scores, seat.player.username))
      Ok("[" <> seat.id <> ":" <> int.to_string(score) <> "]")
    })
    |> string.join("")
  let moves =
    record.moves
    |> list.reverse
    |> list.map(fn(move) {
      let standard = case
        conventional != "",
        list.find(record.seats, fn(s) { s.id == move.seat })
      {
        True, Ok(seat) ->
          case seat.player.color {
            player.Black -> "B" <> value(point_text(move.point))
            _ -> "W" <> value(point_text(move.point))
          }
        _, _ -> ""
      }
      ";"
      <> standard
      <> "RTMOVE["
      <> move.seat
      <> ":"
      <> point_text(move.point)
      <> "]RTTIME"
      <> value(int.to_string(move.at_ms))
    })
    |> string.join("\n")
  "(;FF[4]CA[UTF-8]GM[1]AP[RTGO:1]SZ"
  <> value(int.to_string(record.size))
  <> case record.date {
    Some(date) -> "DT" <> value(date)
    None -> ""
  }
  <> "RU[RTGO positional superko; no suicide; area; no komi]RTFORMAT[1]\nRTPLAYER"
  <> roster
  <> conventional
  <> ending
  <> "RTSCORING"
  <> value(record.scoring)
  <> case scores {
    "" -> ""
    _ -> "RTSCORE" <> scores
  }
  <> case record.dead {
    [] -> ""
    _ ->
      "RTDEAD"
      <> {
        record.dead
        |> list.map(fn(p) { value(point_text(p)) })
        |> string.join("")
      }
  }
  <> "\n"
  <> moves
  <> ")\n"
}

// Values remain escaped until fields are split: an escaped colon in a name
// must not become a delimiter. Unknown properties are parsed, then ignored.
type Property =
  #(String, List(String))

type Node =
  List(Property)

fn whitespace(chars: List(String)) -> List(String) {
  case chars {
    [" ", ..rest]
    | ["\n", ..rest]
    | ["\r", ..rest]
    | ["\r\n", ..rest]
    | ["\t", ..rest] -> whitespace(rest)
    _ -> chars
  }
}

fn raw_value(
  chars: List(String),
  acc: List(String),
) -> Result(#(String, List(String)), String) {
  case chars {
    [] -> Error("Unclosed SGF value.")
    ["]", ..rest] -> Ok(#(acc |> list.reverse |> string.join(""), rest))
    ["\\", char, ..rest] -> raw_value(rest, [char, "\\", ..acc])
    [char, ..rest] -> raw_value(rest, [char, ..acc])
  }
}

fn values(
  chars: List(String),
  acc: List(String),
) -> Result(#(List(String), List(String)), String) {
  case whitespace(chars) {
    ["[", ..rest] -> {
      use #(value, rest) <- result.try(raw_value(rest, []))
      values(rest, [value, ..acc])
    }
    rest ->
      case acc {
        [] -> Error("Expected an SGF property value.")
        _ -> Ok(#(list.reverse(acc), rest))
      }
  }
}

fn identifier(chars: List(String), acc: List(String)) -> #(String, List(String)) {
  case chars {
    [char, ..rest] ->
      case string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", char) {
        True -> identifier(rest, [char, ..acc])
        False -> #(acc |> list.reverse |> string.join(""), chars)
      }
    _ -> #(acc |> list.reverse |> string.join(""), chars)
  }
}

fn node(chars: List(String), acc: Node) -> Result(#(Node, List(String)), String) {
  let chars = whitespace(chars)
  case chars {
    [";", ..] | [")", ..] -> Ok(#(list.reverse(acc), chars))
    _ -> {
      let #(id, rest) = identifier(chars, [])
      case id == "" || list.any(acc, fn(p) { p.0 == id }) {
        True -> Error("Invalid or duplicate SGF property.")
        False -> {
          use #(values, rest) <- result.try(values(rest, []))
          node(rest, [#(id, values), ..acc])
        }
      }
    }
  }
}

fn nodes(chars: List(String), acc: List(Node)) -> Result(List(Node), String) {
  case whitespace(chars) {
    [";", ..rest] -> {
      use #(node, rest) <- result.try(node(rest, []))
      nodes(rest, [node, ..acc])
    }
    [")", ..rest] ->
      case whitespace(rest) {
        [] -> Ok(list.reverse(acc))
        _ -> Error("Only one SGF game is supported.")
      }
    _ -> Error("Expected a linear SGF game (variations are not supported).")
  }
}

fn split_fields(
  chars: List(String),
  current: List(String),
  acc: List(String),
) -> List(String) {
  case chars {
    [] -> list.reverse([current |> list.reverse |> string.join(""), ..acc])
    ["\\", "\r", "\n", ..rest]
    | ["\\", "\r\n", ..rest]
    | ["\\", "\n", ..rest]
    | ["\\", "\r", ..rest] -> split_fields(rest, current, acc)
    ["\\", char, ..rest] -> split_fields(rest, [char, ..current], acc)
    [":", ..rest] ->
      split_fields(rest, [], [current |> list.reverse |> string.join(""), ..acc])
    [char, ..rest] -> split_fields(rest, [char, ..current], acc)
  }
}

fn fields(raw: String) -> List(String) {
  split_fields(string.to_graphemes(raw), [], [])
}

fn get(node: Node, key: String) -> List(String) {
  list.find(node, fn(p) { p.0 == key })
  |> result.map(fn(p) { p.1 })
  |> result.unwrap([])
}

fn one(node: Node, key: String) -> Result(String, String) {
  case get(node, key) {
    [raw] -> Ok(fields(raw) |> string.join(":"))
    _ -> Error("Expected exactly one " <> key <> " value.")
  }
}

fn number(text: String) -> Result(Int, String) {
  use n <- result.try(
    int.parse(text) |> result.replace_error("Invalid integer."),
  )
  case n >= 0 {
    True -> Ok(n)
    False -> Error("Negative time or score.")
  }
}

fn letter_index(char: String) -> Result(Int, Nil) {
  letters
  |> string.to_graphemes
  |> list.index_map(fn(c, i) { #(c, i) })
  |> list.key_find(char)
}

fn coordinate(text: String, size: Int) -> Result(go.Point, String) {
  case string.to_graphemes(text) {
    [x, y] -> {
      use x <- result.try(
        letter_index(x) |> result.replace_error("Invalid coordinate."),
      )
      use y <- result.try(
        letter_index(y) |> result.replace_error("Invalid coordinate."),
      )
      case x < size && y < size {
        True -> Ok(#(x, y))
        False -> Error("Coordinate outside board.")
      }
    }
    _ -> Error("Expected a two-letter coordinate.")
  }
}

fn seat(raw: String) -> Result(Seat, String) {
  case fields(raw) {
    [id, name, color, cooldown] -> {
      use color <- result.try(
        player.color_from_name(color)
        |> result.replace_error("Unknown player color."),
      )
      use cooldown <- result.try(number(cooldown))
      case
        id != ""
        && cooldown > 0
        && list.all(string.to_graphemes(id), fn(c) {
          string.contains("abcdefghijklmnopqrstuvwxyz0123456789", c)
        })
      {
        True -> Ok(Seat(id, player.Player(name, color), cooldown))
        False -> Error("Invalid seat ID or cooldown.")
      }
    }
    _ -> Error("RTPLAYER needs id:name:color:cooldown.")
  }
}

fn check_structure(root: Node, nodes: List(Node)) -> Result(Nil, String) {
  let setup =
    list.any([root, ..nodes], fn(node) {
      list.any(node, fn(p) {
        list.contains(["AB", "AW", "AE", "PL", "HA"], p.0)
      })
    })
  let root_move =
    list.any(root, fn(p) { list.contains(["RTMOVE", "B", "W"], p.0) })
  case setup || root_move || !list.contains([[], ["1"]], get(root, "GM")) {
    True ->
      Error("Setup stones, root moves, and non-Go games are not supported.")
    False -> Ok(Nil)
  }
}

pub fn decode(source: String) -> Result(Replay, String) {
  case string.byte_size(source) > 1_000_000 {
    True -> Error("SGF is too large (maximum 1 MB).")
    False -> {
      use nodes <- result.try(case whitespace(string.to_graphemes(source)) {
        ["(", ..rest] -> nodes(rest, [])
        _ -> Error("Expected an SGF game beginning with (;.")
      })
      use #(root, rest) <- result.try(case nodes {
        [root, ..rest] -> Ok(#(root, rest))
        _ -> Error("SGF has no root node.")
      })
      use _ <- result.try(check_structure(root, rest))
      use version <- result.try(
        one(root, "RTFORMAT")
        |> result.replace_error(
          "This replay supports RTGO recordings with RTFORMAT[1], not arbitrary Go SGFs.",
        ),
      )
      use size <- result.try(one(root, "SZ") |> result.try(number))
      use seats <- result.try(get(root, "RTPLAYER") |> list.try_map(seat))
      let unique = fn(items) {
        set.size(set.from_list(items)) == list.length(items)
      }
      case
        version == "1"
        && size >= 2
        && size <= 25
        && list.length(seats) >= 2
        && list.length(seats) <= 8
        && unique(list.map(seats, fn(s) { s.id }))
        && unique(list.map(seats, fn(s) { s.player.username }))
        && unique(list.map(seats, fn(s) { player.color_name(s.player.color) }))
      {
        False ->
          Error("Unsupported RTGO version, board size, or player roster.")
        True -> {
          use date <- result.try(case get(root, "DT") {
            [] -> Ok(None)
            _ -> one(root, "DT") |> result.map(Some)
          })
          use finished <- result.try(case get(root, "RTEND") {
            [] -> Ok(None)
            _ -> one(root, "RTEND") |> result.try(number) |> result.map(Some)
          })
          use dead <- result.try(
            get(root, "RTDEAD")
            |> list.try_map(fn(raw) { coordinate(raw, size) }),
          )
          use scores <- result.try(
            get(root, "RTSCORE")
            |> list.try_map(fn(raw) {
              case fields(raw) {
                [id, score] -> {
                  use seat <- result.try(
                    list.find(seats, fn(s) { s.id == id })
                    |> result.replace_error("Unknown score seat."),
                  )
                  use n <- result.try(number(score))
                  Ok(#(seat.player.username, n))
                }
                _ -> Error("Invalid RTSCORE.")
              }
            }),
          )
          use scoring <- result.try(case get(root, "RTSCORING") {
            [] -> Ok("pending")
            _ -> one(root, "RTSCORING")
          })
          let valid_scoring = case scoring {
            "pending" -> scores == [] && dead == []
            "unassisted" ->
              finished != None
              && dead == []
              && list.length(scores) == list.length(seats)
            "estimated" ->
              finished != None && list.length(scores) == list.length(seats)
            _ -> False
          }
          case
            valid_scoring
            && unique(list.map(scores, fn(s) { s.0 }))
            && set.size(set.from_list(dead)) == list.length(dead)
            && list.all(scores, fn(s) { s.1 <= size * size })
          {
            False -> Error("Invalid or incomplete final scoring metadata.")
            True -> {
              let record =
                Record(
                  size,
                  seats,
                  [],
                  finished,
                  scoring,
                  dict.from_list(scores),
                  dead,
                  date,
                )
              replay_nodes(
                rest,
                record,
                go.new_game(size),
                [Frame(go.new_game(size), None)],
                0,
                0,
              )
            }
          }
        }
      }
    }
  }
}

fn replay_nodes(
  nodes: List(Node),
  record: Record,
  board: go.Game,
  frames: List(Frame),
  last_time: Int,
  count: Int,
) -> Result(Replay, String) {
  case nodes {
    [] ->
      case record.finished_at {
        Some(end) if end < last_time -> Error("Game ends before its last move.")
        _ ->
          case
            list.all(record.dead, fn(point) {
              dict.has_key(board.stones, point)
            })
          {
            True -> Ok(Replay(record, list.reverse(frames)))
            False -> Error("Dead-stone annotation refers to an empty point.")
          }
      }
    [node, ..rest] -> {
      use raw <- result.try(case get(node, "RTMOVE") {
        [v] -> Ok(v)
        _ -> Error("Each replay node needs one RTMOVE.")
      })
      use #(id, point) <- result.try(case fields(raw) {
        [id, point] ->
          coordinate(point, record.size) |> result.map(fn(p) { #(id, p) })
        _ -> Error("Invalid RTMOVE.")
      })
      use seat <- result.try(
        list.find(record.seats, fn(s) { s.id == id })
        |> result.replace_error("Unknown move seat."),
      )
      use at <- result.try(one(node, "RTTIME") |> result.try(number))
      use board <- result.try(
        go.play(board, seat.player, point)
        |> result.replace_error("Illegal move in recording."),
      )
      case at < last_time || count >= 10_000 {
        True ->
          Error("Moves are out of time order, or there are too many moves.")
        False -> {
          let move = Move(id, point, at)
          replay_nodes(
            rest,
            Record(..record, moves: [move, ..record.moves]),
            board,
            [Frame(go.Game(..board, history: set.new()), Some(move)), ..frames],
            at,
            count + 1,
          )
        }
      }
    }
  }
}
