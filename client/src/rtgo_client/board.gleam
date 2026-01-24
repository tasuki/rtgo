import gleam/float
import gleam/int
import gleam/list
import lustre/attribute
import lustre/element/svg
import rtgo_shared/go

// View

const stroke = "#0009"

pub fn view(game: go.Game) {
  view_board(game.board_size)
}

fn view_board(board_size: Int) {
  let view_box =
    "0.5 0.5 " <> int.to_string(board_size) <> " " <> int.to_string(board_size)

  svg.svg([attribute.attribute("viewBox", view_box)], [
    svg.g([], view_lines(1, board_size)),
    svg.g([], view_star_points(board_size)),
  ])
}

fn view_lines(min: Int, max: Int) {
  let line_width = 0.002 *. int.to_float(max - min)
  let line = fn(x1, y1, x2, y2) {
    svg.line([
      attribute.attribute("x1", int.to_string(x1)),
      attribute.attribute("y1", int.to_string(y1)),
      attribute.attribute("x2", int.to_string(x2)),
      attribute.attribute("y2", int.to_string(y2)),
      attribute.attribute("stroke", stroke),
      attribute.attribute("stroke-width", float.to_string(line_width)),
    ])
  }

  let offsets = list.range(from: min, to: max)
  list.append(
    list.map(offsets, fn(o) { line(min, o, max, o) }),
    list.map(offsets, fn(o) { line(o, min, o, max) }),
  )
}

fn view_star_points(board_size: Int) {
  let board_plus = board_size + 1
  let board_half = board_plus / 2
  let points = case board_size % 2 == 0 {
    True -> []
    _ if board_size < 11 -> [
      #(3, 3),
      #(3, board_plus - 3),
      #(board_plus - 3, 3),
      #(board_plus - 3, board_plus - 3),
    ]
    _ if board_size < 15 -> [
      #(4, 4),
      #(4, board_plus - 4),
      #(board_half, board_half),
      #(board_plus - 4, 4),
      #(board_plus - 4, board_plus - 4),
    ]
    _ -> [
      #(4, 4),
      #(4, board_half),
      #(4, board_plus - 4),
      #(board_half, 4),
      #(board_half, board_half),
      #(board_half, board_plus - 4),
      #(board_plus - 4, 4),
      #(board_plus - 4, board_half),
      #(board_plus - 4, board_plus - 4),
    ]
  }

  use #(x, y) <- list.map(points)

  let point_size = 0.005 *. int.to_float(board_size)
  svg.circle([
    attribute.attribute("cx", int.to_string(x)),
    attribute.attribute("cy", int.to_string(y)),
    attribute.attribute("r", float.to_string(point_size)),
    attribute.attribute("fill", stroke),
  ])
}
