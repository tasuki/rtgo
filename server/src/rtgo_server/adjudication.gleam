import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/set
import rtgo_server/katago
import rtgo_shared/go

/// Ownership is an estimate, not a life-and-death proof. A whole group is
/// excluded when every stone's ownership is at most -0.6 in its owner's
/// single own-turn evaluation.
/// Missing or less-negative ownership keeps the group in the score.
pub fn dead_stones(
  board: go.Game,
  estimates: Dict(String, Dict(go.Point, Float)),
) -> List(go.Point) {
  go.groups(board)
  |> list.flat_map(fn(entry) {
    let #(player, group) = entry
    case dict.get(estimates, player.username) {
      Error(_) -> []
      Ok(ownership) -> {
        let dead =
          set.to_list(group)
          |> list.all(fn(point) {
            dict.get(ownership, point) |> result.unwrap(0.0) <=. -0.6
          })
        case dead {
          True -> set.to_list(group)
          False -> []
        }
      }
    }
  })
}

/// Each player gets their own projection: theirs black, everybody else white.
/// One single-visit query per player, with that player to move. No transformed
/// boards, extra side-to-move evaluation, or averaging.
pub fn estimate(board: go.Game) -> Result(List(go.Point), Nil) {
  let names =
    board.stones |> dict.values |> list.map(fn(p) { p.username }) |> list.unique
  case names, katago.available() {
    [], _ -> Ok([])
    _, False -> Error(Nil)
    _, True -> {
      use estimates <- result.try(
        list.try_map(names, fn(name) {
          use ownership <- result.try(katago.ownership(board, name))
          Ok(#(name, ownership))
        }),
      )
      Ok(dead_stones(board, dict.from_list(estimates)))
    }
  }
}
