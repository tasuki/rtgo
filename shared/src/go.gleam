import gleam/dict.{type Dict}
import gleam/list
import gleam/set.{type Set}
import player.{type Player}

pub type Point =
  #(Int, Int)

pub type Board =
  Dict(Point, Player)

pub type Game {
  Game(
    size: Int,
    board: Board,
    captures: Dict(Player, Int),
    history: Set(Board),
  )
}

pub type MoveError {
  OutOfBounds
  Occupied
  Suicide
  Ko
}

pub fn new_game(size: Int) -> Game {
  Game(size: size, board: dict.new(), captures: dict.new(), history: set.new())
}

pub fn play(game: Game, player: Player, point: Point) -> Result(Game, MoveError) {
  use <- check_bounds(game.size, point)
  use <- check_empty(game.board, point)

  let candidate_board = dict.insert(game.board, point, player)

  let #(board_after_captures, captured_count) =
    process_captures(candidate_board, point, player)

  use <- check_suicide(board_after_captures, point, player)
  use <- check_ko(game.history, board_after_captures)

  let new_captures =
    dict.insert(game.captures, player, case dict.get(game.captures, player) {
      Ok(c) -> c + captured_count
      Error(_) -> captured_count
    })

  Ok(
    Game(
      ..game,
      board: board_after_captures,
      captures: new_captures,
      history: set.insert(game.history, board_after_captures),
    ),
  )
}

fn check_bounds(size: Int, point: Point, next: fn() -> Result(a, MoveError)) {
  let #(x, y) = point
  case x >= 0 && x < size && y >= 0 && y < size {
    True -> next()
    False -> Error(OutOfBounds)
  }
}

fn check_empty(board: Board, point: Point, next: fn() -> Result(a, MoveError)) {
  case dict.has_key(board, point) {
    False -> next()
    True -> Error(Occupied)
  }
}

fn process_captures(board: Board, move: Point, player: Player) -> #(Board, Int) {
  list.fold(get_neighbors(move), #(board, 0), fn(acc, neighbor) {
    let #(current_board, count) = acc
    case dict.get(current_board, neighbor) {
      Ok(p) if p != player -> {
        let group = get_group(current_board, neighbor, player)
        case has_liberties(current_board, group) {
          True -> acc
          False -> {
            let new_board =
              set.fold(group, current_board, fn(b, p) { dict.delete(b, p) })
            #(new_board, count + set.size(group))
          }
        }
      }
      _ -> acc
    }
  })
}

fn check_suicide(
  board: Board,
  point: Point,
  player: Player,
  next: fn() -> Result(a, MoveError),
) {
  let group = get_group(board, point, player)
  case has_liberties(board, group) {
    True -> next()
    False -> Error(Suicide)
  }
}

fn check_ko(
  history: Set(Board),
  board: Board,
  next: fn() -> Result(a, MoveError),
) {
  case set.contains(history, board) {
    False -> next()
    True -> Error(Ko)
  }
}

fn get_neighbors(point: Point) -> List(Point) {
  let #(x, y) = point
  [#(x + 1, y), #(x - 1, y), #(x, y + 1), #(x, y - 1)]
}

fn get_group(board: Board, start: Point, color: Player) -> Set(Point) {
  flood_fill(board, [start], color, set.new())
}

fn flood_fill(
  board: Board,
  queue: List(Point),
  color: Player,
  visited: Set(Point),
) -> Set(Point) {
  case queue {
    [] -> visited
    [curr, ..rest] -> {
      case set.contains(visited, curr) {
        True -> flood_fill(board, rest, color, visited)
        False -> {
          let matching_neighbors =
            list.filter(get_neighbors(curr), fn(n) {
              dict.get(board, n) == Ok(color)
            })
          flood_fill(
            board,
            list.append(rest, matching_neighbors),
            color,
            set.insert(visited, curr),
          )
        }
      }
    }
  }
}

fn has_liberties(board: Board, group: Set(Point)) -> Bool {
  use point <- list.any(set.to_list(group))
  use neighbor <- list.any(get_neighbors(point))
  !dict.has_key(board, neighbor)
}
