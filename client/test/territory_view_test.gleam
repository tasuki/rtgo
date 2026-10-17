import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import lustre/dev/query
import lustre/element
import rtgo_client/board
import rtgo_shared/go
import rtgo_shared/player

pub fn territory_uses_owner_colors_and_is_layered_beneath_stones_test() {
  let black = player.Player("black", player.Black)
  let blue = player.Player("blue", player.Blue)
  let white = player.Player("white", player.White)
  let game =
    go.Game(
      ..go.new_game(9),
      stones: dict.from_list([
        #(#(0, 0), black),
        #(#(2, 2), white),
      ]),
    )
  let view =
    board.view(
      game,
      [#(2, 2)],
      dict.from_list([
        #(#(2, 2), black),
        #(#(8, 8), blue),
      ]),
      None,
      None,
      None,
      fn(_) { Nil },
      fn(_) { Nil },
      Nil,
    )
  let assert Ok(overlay) =
    query.find(view, query.element(query.class("territory-overlay")))
  let html = element.to_string(overlay)
  should.equal(string.contains(html, "opacity=\"0.32\""), True)
  should.equal(string.contains(html, "pointer-events=\"none\""), True)
  should.equal(string.contains(html, "aria-hidden=\"true\""), True)
  should.equal(
    query.find_all(overlay, query.element(query.class("territory-point")))
      |> list.length,
    2,
  )
  list.each(
    [#("black", "#333", "2,2", "2.5"), #("blue", "#08F", "8,8", "8.5")],
    fn(owner) {
      let assert Ok(point) =
        query.find(
          overlay,
          query.element(query.attribute("data-owner", owner.0)),
        )
      let html = element.to_string(point)
      should.equal(string.contains(html, "fill=\"" <> owner.1 <> "\""), True)
      should.equal(
        string.contains(html, "data-point=\"" <> owner.2 <> "\""),
        True,
      )
      should.equal(string.contains(html, "x=\"" <> owner.3 <> "\""), True)
      should.equal(string.contains(html, "width=\"1\""), True)
    },
  )
  // SVG paints in document order: board -> territory -> stones -> dead markers.
  let html = element.to_string(view)
  let assert Ok(#(under, over)) =
    string.split_once(html, "class=\"territory-overlay\"")
  should.equal(string.contains(under, "<line"), True)
  should.equal(string.contains(under, "class=\"stones\""), False)
  let assert Ok(#(territory, stones)) =
    string.split_once(over, "class=\"stones\"")
  should.equal(string.contains(territory, "territory-point"), True)
  should.equal(string.contains(stones, "stone dead-stone"), True)
  should.equal(string.contains(stones, "dead-stone-marker"), True)
}
