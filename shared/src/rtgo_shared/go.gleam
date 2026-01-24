import gleam/dict.{type Dict}
import gleam/list
import gleam/set.{type Set}
import rtgo_shared/player.{type Player}

pub type Point =
  #(Int, Int)

pub type Stones =
  Dict(Point, Player)

pub type Game {
  Game(
    board_size: Int,
    stones: Stones,
    captures: Dict(Player, Int),
    history: Set(Stones),
  )
}

pub type MoveError {
  OutOfBounds
  Occupied
  Suicide
  Ko
}

pub fn new_game(board_size: Int) -> Game {
  Game(
    board_size: board_size,
    stones: dict.new(),
    captures: dict.new(),
    history: set.new(),
  )
}

pub fn play(game: Game, player: Player, point: Point) -> Result(Game, MoveError) {
  use <- check_bounds(game.board_size, point)
  use <- check_empty(game.stones, point)

  let candidate_stones = dict.insert(game.stones, point, player)

  let #(stones_after_captures, captured_count) =
    process_captures(candidate_stones, point, player)

  use <- check_suicide(stones_after_captures, point, player)
  use <- check_ko(game.history, stones_after_captures)

  let new_captures =
    dict.insert(game.captures, player, case dict.get(game.captures, player) {
      Ok(c) -> c + captured_count
      Error(_) -> captured_count
    })

  Ok(
    Game(
      ..game,
      stones: stones_after_captures,
      captures: new_captures,
      history: set.insert(game.history, stones_after_captures),
    ),
  )
}

fn check_bounds(
  board_size: Int,
  point: Point,
  next: fn() -> Result(a, MoveError),
) {
  let #(x, y) = point
  case x >= 0 && x < board_size && y >= 0 && y < board_size {
    True -> next()
    False -> Error(OutOfBounds)
  }
}

fn check_empty(stones: Stones, point: Point, next: fn() -> Result(a, MoveError)) {
  case dict.has_key(stones, point) {
    False -> next()
    True -> Error(Occupied)
  }
}

fn process_captures(
  stones: Stones,
  move: Point,
  player: Player,
) -> #(Stones, Int) {
  list.fold(get_neighbors(move), #(stones, 0), fn(acc, neighbor) {
    let #(current_stones, count) = acc
    case dict.get(current_stones, neighbor) {
      Ok(p) if p != player -> {
        let group = get_group(current_stones, neighbor, player)
        case has_liberties(current_stones, group) {
          True -> acc
          False -> {
            let new_stones =
              set.fold(group, current_stones, fn(b, p) { dict.delete(b, p) })
            #(new_stones, count + set.size(group))
          }
        }
      }
      _ -> acc
    }
  })
}

fn check_suicide(
  stones: Stones,
  point: Point,
  player: Player,
  next: fn() -> Result(a, MoveError),
) {
  let group = get_group(stones, point, player)
  case has_liberties(stones, group) {
    True -> next()
    False -> Error(Suicide)
  }
}

fn check_ko(
  history: Set(Stones),
  stones: Stones,
  next: fn() -> Result(a, MoveError),
) {
  case set.contains(history, stones) {
    False -> next()
    True -> Error(Ko)
  }
}

fn get_neighbors(point: Point) -> List(Point) {
  let #(x, y) = point
  [#(x + 1, y), #(x - 1, y), #(x, y + 1), #(x, y - 1)]
}

fn get_group(stones: Stones, start: Point, color: Player) -> Set(Point) {
  flood_fill(stones, [start], color, set.new())
}

fn flood_fill(
  stones: Stones,
  queue: List(Point),
  color: Player,
  visited: Set(Point),
) -> Set(Point) {
  case queue {
    [] -> visited
    [curr, ..rest] -> {
      case set.contains(visited, curr) {
        True -> flood_fill(stones, rest, color, visited)
        False -> {
          let matching_neighbors =
            list.filter(get_neighbors(curr), fn(n) {
              dict.get(stones, n) == Ok(color)
            })
          flood_fill(
            stones,
            list.append(rest, matching_neighbors),
            color,
            set.insert(visited, curr),
          )
        }
      }
    }
  }
}

fn has_liberties(stones: Stones, group: Set(Point)) -> Bool {
  use point <- list.any(set.to_list(group))
  use neighbor <- list.any(get_neighbors(point))
  !dict.has_key(stones, neighbor)
}
