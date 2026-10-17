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

/// Connected groups retain their real player identities, not a two-color projection.
pub fn groups(game: Game) -> List(#(Player, Set(Point))) {
  let #(_, groups) =
    dict.fold(game.stones, #(set.new(), []), fn(acc, point, player) {
      let #(visited, groups) = acc
      case set.contains(visited, point) {
        True -> acc
        False -> {
          let group = get_group(game.stones, point, player)
          #(set.union(visited, group), [#(player, group), ..groups])
        }
      }
    })
  groups
}

/// Area scoring, without komi: stones plus empty regions bordered by exactly
/// one player. Mixed borders (including multiplayer) and unclaimed space are neutral.
/// Scores the supplied position as-is; dead stones must first be removed from it.
pub fn score(game: Game) -> Dict(String, Int) {
  dict.fold(area(game), dict.new(), fn(scores, _, player) {
    add_score(scores, player.username, 1)
  })
}

/// Every counted intersection, including live stones: also used for shading.
pub fn area(game: Game) -> Dict(Point, Player) {
  dict.merge(game.stones, territory(game))
}

/// The exact empty intersections counted by area scoring. Mixed borders and
/// unclaimed regions have no owner. Live stones themselves are not territory.
pub fn territory(game: Game) -> Dict(Point, Player) {
  let points =
    list.flat_map(list.range(0, game.board_size - 1), fn(x) {
      list.map(list.range(0, game.board_size - 1), fn(y) { #(x, y) })
    })
  let #(_, territory) =
    list.fold(points, #(set.new(), dict.new()), fn(acc, point) {
      let #(visited, territory) = acc
      case set.contains(visited, point) || dict.has_key(game.stones, point) {
        True -> acc
        False -> {
          let #(region, borders) =
            empty_region(game, [point], set.new(), set.new())
          let territory = case set.to_list(borders) {
            [owner] ->
              set.fold(region, territory, fn(territory, point) {
                dict.insert(territory, point, owner)
              })
            _ -> territory
          }
          #(set.union(visited, region), territory)
        }
      }
    })
  territory
}

/// A scoring copy: preserve the played position and history in the original.
pub fn remove_stones(game: Game, points: List(Point)) -> Game {
  Game(
    ..game,
    stones: list.fold(points, game.stones, fn(stones, point) {
      dict.delete(stones, point)
    }),
  )
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
  borders: Set(Player),
) -> #(Set(Point), Set(Player)) {
  case queue {
    [] -> #(visited, borders)
    [point, ..rest] ->
      case set.contains(visited, point) {
        True -> empty_region(game, rest, visited, borders)
        False ->
          case dict.get(game.stones, point) {
            Ok(player) ->
              empty_region(game, rest, visited, set.insert(borders, player))
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
