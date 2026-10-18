import gleam/list
import gleeunit/should
import lustre/dev/query
import rtgo_client as app
import rtgo_client/player_info

fn model(mode: String) -> app.Model {
  let initial =
    app.initial_model(
      app.CreateJoinGame,
      player_info.LoggedIn("alice", "jwt"),
      "https://rtgo.test",
    )
  let #(model, _) = app.update(initial, app.TimeModeChanged(mode))
  model
}

pub fn every_creation_field_keeps_its_label_and_control_in_one_row_test() {
  list.each(
    ["crazy_cooldown", "cushy_cooldown", "stone_savings", "drag_derby"],
    fn(mode) {
      let assert Ok(form) =
        query.find(
          app.view(model(mode)),
          query.element(query.class("create-game")),
        )
      let ids = case mode {
        "stone_savings" -> [
          "game-type",
          "board-size",
          "time-mode",
          "cooldown",
          "savings-cap",
          "savings-gap",
        ]
        _ -> ["game-type", "board-size", "time-mode", "cooldown"]
      }
      let fields =
        query.find_all(form, query.element(query.class("create-game-field")))
      should.equal(list.length(fields), list.length(ids))
      list.each(list.zip(fields, ids), fn(entry) {
        let #(field, id) = entry
        let assert Ok(_) =
          query.find(
            field,
            query.element(query.class("create-game-field"))
              |> query.child(
                query.tag("label") |> query.and(query.attribute("for", id)),
              ),
          )
        let assert Ok(_) =
          query.find(
            field,
            query.element(query.class("create-game-control"))
              |> query.child(query.id(id)),
          )
      })
      // Help text must stay with the picker, not become a loose form grid cell.
      should.equal(
        query.find_all(
          form,
          query.element(query.class("create-game"))
            |> query.child(query.tag("p")),
        ),
        [],
      )
      let assert Ok(time_field) = fields |> list.drop(2) |> list.first
      let assert Ok(_) =
        query.find(
          time_field,
          query.element(query.class("create-game-control"))
            |> query.child(query.id("time-mode-help")),
        )
      let assert Ok(_) =
        query.find(
          form,
          query.element(
            query.id("time-mode")
            |> query.and(query.attribute("aria-describedby", "time-mode-help")),
          ),
        )
    },
  )
}

pub fn savings_fields_share_the_standard_field_layout_test() {
  let assert Ok(group) =
    query.find(
      app.view(model("stone_savings")),
      query.element(query.class("create-game-savings")),
    )
  should.equal(
    list.length(query.find_all(
      group,
      query.element(query.class("create-game-savings"))
        |> query.child(query.class("create-game-field")),
    )),
    2,
  )
}
