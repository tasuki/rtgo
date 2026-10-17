import gleam/dict.{type Dict}
import gleam/list
import gleam/set.{type Set}
import rtgo_shared/player.{type Player}

pub type Point =
  #(Int, Int)

pub type Stones =
  Dict(Point, Player)

pub type Game {
  Game(board_size: Int, stones: Stones, history: Set(Stones))
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
    history: set.from_list([dict.new()]),
  )
}

pub fn play(game: Game, player: Player, point: Point) -> Result(Game, MoveError) {
  use <- check_bounds(game.board_size, point)
  use <- check_empty(game.stones, point)

  let candidate_stones = dict.insert(game.stones, point, player)
  let stones_after_captures =
    process_captures(candidate_stones, point, player, game.board_size)

  use <- check_suicide(stones_after_captures, point, player, game.board_size)
  use <- check_ko(game.history, stones_after_captures)

  Ok(
    Game(
      ..game,
      stones: stones_after_captures,
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
  board_size: Int,
) -> Stones {
  list.fold(get_neighbors(move), stones, fn(current_stones, neighbor) {
    case dict.get(current_stones, neighbor) {
      Ok(p) if p != player -> {
        let group = get_group(stones, neighbor, p)
        case has_liberties(stones, group, board_size) {
          True -> current_stones
          False -> set.fold(group, current_stones, dict.delete)
        }
      }
      _ -> current_stones
    }
  })
}

fn check_suicide(
  stones: Stones,
  point: Point,
  player: Player,
  board_size: Int,
  next: fn() -> Result(a, MoveError),
) {
  let group = get_group(stones, point, player)
  case has_liberties(stones, group, board_size) {
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

fn has_liberties(stones: Stones, group: Set(Point), board_size: Int) -> Bool {
  use point <- list.any(set.to_list(group))
  use neighbor <- list.any(neighbors(point, board_size))
  !dict.has_key(stones, neighbor)
}

fn neighbors(point: Point, size: Int) -> List(Point) {
  list.filter(get_neighbors(point), fn(p) {
    p.0 >= 0 && p.0 < size && p.1 >= 0 && p.1 < size
  })
}

/// Area scoring, without komi: stones plus empty regions bordered by exactly
/// one player. Mixed borders (including multiplayer) and unclaimed space are neutral.
/// Dead stones must be captured before the game ends.
pub fn score(game: Game) -> Dict(String, Int) {
  let points =
    list.flat_map(list.range(0, game.board_size - 1), fn(x) {
      list.map(list.range(0, game.board_size - 1), fn(y) { #(x, y) })
    })
  let stones =
    dict.fold(game.stones, dict.new(), fn(scores, _, player) {
      add_score(scores, player.username, 1)
    })
  let #(_, scores) =
    list.fold(points, #(set.new(), stones), fn(acc, point) {
      let #(visited, scores) = acc
      case set.contains(visited, point) || dict.has_key(game.stones, point) {
        True -> acc
        False -> {
          let #(region, borders) =
            empty_region(game, [point], set.new(), set.new())
          let scores = case set.to_list(borders) {
            [name] -> add_score(scores, name, set.size(region))
            _ -> scores
          }
          #(set.union(visited, region), scores)
        }
      }
    })
  scores
}

fn add_score(
  scores: Dict(String, Int),
  name: String,
  amount: Int,
) -> Dict(String, Int) {
  let previous = case dict.get(scores, name) {
    Ok(n) -> n
    Error(_) -> 0
  }
  dict.insert(scores, name, previous + amount)
}

fn empty_region(
  game: Game,
  queue: List(Point),
  visited: Set(Point),
  borders: Set(String),
) -> #(Set(Point), Set(String)) {
  case queue {
    [] -> #(visited, borders)
    [point, ..rest] ->
      case set.contains(visited, point) {
        True -> empty_region(game, rest, visited, borders)
        False ->
          case dict.get(game.stones, point) {
            Ok(player) ->
              empty_region(
                game,
                rest,
                visited,
                set.insert(borders, player.username),
              )
            Error(_) ->
              empty_region(
                game,
                list.append(rest, neighbors(point, game.board_size)),
                set.insert(visited, point),
                borders,
              )
          }
      }
  }
}
