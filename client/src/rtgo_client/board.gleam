import gleam/dict
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element/svg
import lustre/event
import rtgo_shared/go
import rtgo_shared/player

// View

const stroke = "#0009"

pub fn view(
  game: go.Game,
  dead_stones: List(go.Point),
  area: dict.Dict(go.Point, player.Player),
  active_player: Option(player.Player),
  hovered: Option(go.Point),
  premove: Option(go.Point),
  on_hover: fn(Option(go.Point)) -> msg,
  on_play: fn(go.Point) -> msg,
  on_cancel: msg,
) {
  let board_size = game.board_size
  let view_box =
    "0.5 0.5 " <> int.to_string(board_size) <> " " <> int.to_string(board_size)
  let points =
    list.flat_map(list.range(0, board_size - 1), fn(x) {
      list.map(list.range(0, board_size - 1), fn(y) { #(x, y) })
    })

  svg.svg(
    [
      attribute.attribute("viewBox", view_box),
      attribute.attribute("aria-label", "Go board"),
      event.on_mouse_leave(on_hover(None)),
      event.advanced("keydown", {
        use key <- decode.field("key", decode.string)
        let handler = event.handler(on_cancel, True, False)
        case key {
          "Escape" -> decode.success(handler)
          _ -> decode.failure(handler, "Escape")
        }
      }),
    ],
    [
      svg.g([], view_lines(1, board_size)),
      svg.g([], view_star_points(board_size)),
      svg.g(
        [
          attribute.class("territory-overlay"),
          attribute.attribute("aria-hidden", "true"),
          attribute.attribute("pointer-events", "none"),
          attribute.attribute("opacity", "0.32"),
          attribute.attribute("shape-rendering", "crispEdges"),
        ],
        area
          |> dict.to_list
          |> list.map(fn(entry) {
            let #(point, owner) = entry
            svg.rect([
              attribute.class("territory-point"),
              attribute.attribute("data-owner", owner.username),
              attribute.attribute(
                "data-point",
                int.to_string(point.0) <> "," <> int.to_string(point.1),
              ),
              attribute.attribute(
                "x",
                float.to_string(int.to_float(point.0) +. 0.5),
              ),
              attribute.attribute(
                "y",
                float.to_string(int.to_float(point.1) +. 0.5),
              ),
              attribute.attribute("width", "1"),
              attribute.attribute("height", "1"),
              attribute.attribute("fill", player.color_to_str(owner.color)),
            ])
          }),
      ),
      svg.g(
        [attribute.class("stones")],
        dict.to_list(game.stones)
          |> list.map(fn(entry) {
            case list.contains(dead_stones, entry.0) {
              True ->
                svg.g([attribute.attribute("opacity", "0.35")], [
                  stone(entry.0, entry.1, "stone dead-stone"),
                ])
              False -> stone(entry.0, entry.1, "stone")
            }
          }),
      ),
      svg.g([], list.map(dead_stones, dead_stone_marker)),
      case active_player, premove {
        Some(p), Some(point) ->
          case dict.has_key(game.stones, point) {
            False -> stone(point, p, "premove-stone")
            True -> svg.g([], [])
          }
        _, _ -> svg.g([], [])
      },
      case active_player, hovered {
        Some(p), Some(point) if hovered != premove ->
          case dict.has_key(game.stones, point) {
            False -> stone(point, p, "ghost-stone")
            True -> svg.g([], [])
          }
        _, _ -> svg.g([], [])
      },
      svg.g(
        [],
        list.map(points, fn(point) {
          let available =
            active_player != None && !dict.has_key(game.stones, point)
          let handlers = case available {
            False -> []
            True -> [
              attribute.attribute("role", "button"),
              attribute.attribute("tabindex", "0"),
              attribute.attribute("aria-pressed", case premove == Some(point) {
                True -> "true"
                False -> "false"
              }),
              event.on_click(on_play(point)),
              event.on_focus(on_hover(Some(point))),
              event.on_blur(on_hover(None)),
              event.advanced("keydown", {
                use key <- decode.field("key", decode.string)
                let handler = event.handler(on_play(point), True, False)
                case key {
                  "Enter" | " " -> decode.success(handler)
                  _ -> decode.failure(handler, "Enter or Space")
                }
              }),
            ]
          }
          svg.rect(list.append(
            [
              attribute.class(case available {
                True -> "board-point playable"
                False -> "board-point"
              }),
              event.on_mouse_enter(
                on_hover(case available {
                  True -> Some(point)
                  False -> None
                }),
              ),
              attribute.attribute(
                "x",
                float.to_string(int.to_float(point.0) +. 0.5),
              ),
              attribute.attribute(
                "y",
                float.to_string(int.to_float(point.1) +. 0.5),
              ),
              attribute.attribute("width", "1"),
              attribute.attribute("height", "1"),
              attribute.attribute(
                "aria-label",
                "Play at column "
                  <> int.to_string(point.0 + 1)
                  <> ", row "
                  <> int.to_string(point.1 + 1),
              ),
            ],
            handlers,
          ))
        }),
      ),
    ],
  )
}

fn dead_stone_marker(point: go.Point) {
  let x = int.to_float(point.0 + 1)
  let y = int.to_float(point.1 + 1)
  svg.g(
    [
      attribute.class("dead-stone-marker"),
      attribute.attribute("role", "img"),
      attribute.attribute(
        "aria-label",
        "Estimated dead stone at column "
          <> int.to_string(point.0 + 1)
          <> ", row "
          <> int.to_string(point.1 + 1),
      ),
      attribute.attribute("pointer-events", "none"),
    ],
    [
      svg.path([
        attribute.attribute(
          "d",
          "M "
            <> float.to_string(x -. 0.2)
            <> " "
            <> float.to_string(y -. 0.2)
            <> " l 0.4 0.4 M "
            <> float.to_string(x -. 0.2)
            <> " "
            <> float.to_string(y +. 0.2)
            <> " l 0.4 -0.4",
        ),
        attribute.attribute("stroke", "#D22"),
        attribute.attribute("stroke-width", "0.08"),
      ]),
    ],
  )
}

fn stone(point: go.Point, p: player.Player, class: String) {
  svg.circle([
    attribute.class(class),
    attribute.attribute("cx", int.to_string(point.0 + 1)),
    attribute.attribute("cy", int.to_string(point.1 + 1)),
    attribute.attribute("r", "0.46"),
    attribute.attribute("fill", player.color_to_str(p.color)),
    attribute.attribute("stroke", "#222"),
    attribute.attribute("stroke-width", "0.045"),
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
