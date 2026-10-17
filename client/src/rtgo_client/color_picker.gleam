import gleam/list
import gleam/option.{type Option, Some}
import lustre/attribute
import lustre/element/html
import lustre/event
import rtgo_shared/player

pub fn view(
  id: String,
  label: String,
  selected: Option(player.Color),
  colors: List(player.Color),
  unavailable: List(player.Color),
  disabled: Bool,
  on_change: fn(String) -> msg,
) {
  html.div(
    [
      attribute.id(id),
      attribute.class("color-picker"),
      attribute.attribute("role", "group"),
      attribute.attribute("aria-label", label),
    ],
    [
      html.div(
        [attribute.class("color-palette")],
        list.map(colors, fn(color) {
          let name = player.color_name(color)
          html.button(
            [
              attribute.type_("button"),
              attribute.class("color-choice"),
              attribute.value(name),
              attribute.attribute("aria-label", name),
              attribute.attribute("aria-pressed", case selected == Some(color) {
                True -> "true"
                False -> "false"
              }),
              attribute.disabled(disabled || list.contains(unavailable, color)),
              attribute.style("background-color", player.color_to_str(color)),
              event.on_click(on_change(name)),
            ],
            [],
          )
        }),
      ),
    ],
  )
}
