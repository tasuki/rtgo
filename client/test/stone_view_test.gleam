import gleam/dict
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import lustre/dev/query
import lustre/element
import rtgo_client/board
import rtgo_shared/go
import rtgo_shared/player

pub fn placed_hovered_and_queued_stones_share_normal_geometry_test() {
  let p = player.Player("alice", player.Black)
  let assert Ok(game) = go.play(go.new_game(19), p, #(2, 2))
  let view =
    board.view(
      game,
      [],
      dict.new(),
      Some(p),
      Some(#(3, 3)),
      Some(#(4, 4)),
      fn(_) { Nil },
      fn(_) { Nil },
      Nil,
    )
  list.each(["stone", "ghost-stone", "premove-stone"], fn(class) {
    let assert Ok(stone) =
      query.find(view, query.element(query.attribute("class", class)))
    let html = element.to_string(stone)
    should.equal(string.contains(html, "r=\"0.46\""), True)
    should.equal(string.contains(html, "stroke-width=\"0.045\""), True)
    should.equal(string.contains(html, "transform="), False)
  })
}
