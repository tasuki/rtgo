import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import lustre/dev/query
import lustre/element
import rtgo_client/color_picker
import rtgo_shared/player

pub fn palette_always_shows_colored_stones_without_visible_text_or_dropdown_test() {
  let view =
    color_picker.view(
      "preferred-color",
      "Preferred color",
      Some(player.Pink),
      player.all_colors,
      [],
      False,
      fn(_) { Nil },
    )
  let buttons = query.find_all(view, query.element(query.tag("button")))
  should.equal(list.length(buttons), 8)
  query.find(view, query.element(query.tag("select"))) |> should.be_error
  query.find(view, query.element(query.tag("label"))) |> should.be_error
  let html = element.to_string(view)
  should.equal(string.contains(html, "color-palette"), True)
  should.equal(string.contains(html, ">Preferred color<"), False)
  list.each(player.all_colors, fn(color) {
    let name = player.color_name(color)
    let assert Ok(button) =
      query.find(view, query.element(query.attribute("value", name)))
    let html = element.to_string(button)
    should.equal(string.contains(html, "aria-label=\"" <> name <> "\""), True)
    should.equal(
      string.contains(html, "background-color:" <> player.color_to_str(color)),
      True,
    )
    should.equal(string.contains(html, "type=\"button\""), True)
    should.equal(string.contains(html, ">" <> name <> "<"), False)
    should.equal(
      string.contains(html, "aria-pressed=\"true\""),
      color == player.Pink,
    )
  })
}

pub fn unavailable_and_pending_choices_remain_visible_but_disabled_test() {
  let view =
    color_picker.view(
      "game-color",
      "Your color",
      Some(player.Black),
      player.two_player_colors,
      [player.White],
      False,
      fn(_) { Nil },
    )
  should.equal(
    view |> query.find_all(query.element(query.tag("button"))) |> list.length,
    2,
  )
  let assert Ok(white) =
    query.find(view, query.element(query.attribute("value", "white")))
  let assert Ok(black) =
    query.find(view, query.element(query.attribute("value", "black")))
  should.equal(white |> element.to_string |> string.contains("disabled"), True)
  should.equal(black |> element.to_string |> string.contains("disabled"), False)
  let pending =
    color_picker.view(
      "preferred-color",
      "Preferred color",
      Some(player.Pink),
      player.all_colors,
      [],
      True,
      fn(_) { Nil },
    )
  let buttons = query.find_all(pending, query.element(query.tag("button")))
  should.equal(list.length(buttons), 8)
  list.each(buttons, fn(button) {
    should.equal(
      button |> element.to_string |> string.contains("disabled"),
      True,
    )
  })
}

pub fn unknown_selection_shows_all_stones_without_placeholder_text_test() {
  let view =
    color_picker.view(
      "game-color",
      "Your color",
      None,
      player.two_player_colors,
      [],
      False,
      fn(_) { Nil },
    )
  should.equal(
    view |> query.find_all(query.element(query.tag("button"))) |> list.length,
    2,
  )
  should.equal(
    view |> element.to_string |> string.contains("aria-pressed=\"true\""),
    False,
  )
  should.equal(
    view |> element.to_string |> string.contains("Choose color"),
    False,
  )
}
