import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element/html
import lustre/event
import rtgo_client/board
import rtgo_shared/game
import rtgo_shared/go
import rtgo_shared/player
import rtgo_shared/sgf

pub type Model {
  Model(
    source: String,
    replay: Option(sgf.Replay),
    index: Int,
    error: Option(String),
  )
}

pub type Msg {
  SourceChanged(String)
  Load
  Seek(String)
  Step(Int)
}

pub fn new() -> Model {
  Model("", None, 0, None)
}

pub fn load(model: Model, source: String) -> Model {
  case sgf.decode(source) {
    Ok(replay) -> Model(source, Some(replay), 0, None)
    Error(message) -> Model(..model, source: source, error: Some(message))
  }
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    SourceChanged(source) -> Model(..model, source: source)
    Load -> load(model, model.source)
    Seek(value) -> seek(model, int.parse(value) |> result.unwrap(model.index))
    Step(delta) -> seek(model, model.index + delta)
  }
}

fn seek(model: Model, index: Int) -> Model {
  let last = case model.replay {
    Some(replay) -> list.length(replay.frames) - 1
    None -> 0
  }
  Model(..model, index: int.clamp(index, 0, last))
}

pub fn frame(model: Model) -> sgf.Frame {
  case model.replay {
    Some(replay) ->
      replay.frames
      |> list.drop(model.index)
      |> list.first
      |> result.unwrap(sgf.Frame(go.new_game(19), None))
    None -> sgf.Frame(go.new_game(19), None)
  }
}

fn controls(model: Model, replay: sgf.Replay) {
  let last = list.length(replay.frames) - 1
  let current = frame(model)
  let move_text = case current.move {
    None -> "Start of game"
    Some(move) -> {
      let name =
        list.find(replay.record.seats, fn(s) { s.id == move.seat })
        |> result.map(fn(s) { s.player.username })
        |> result.unwrap(move.seat)
      name
      <> " · "
      <> sgf.point_text(move.point)
      <> " · "
      <> int.to_string(move.at_ms / 1000)
      <> "."
      <> string.slice(int.to_string(1000 + move.at_ms % 1000), 1, 3)
      <> "s"
    }
  }
  html.div([attribute.class("replay-controls")], [
    html.div([attribute.class("game-actions")], [
      html.button(
        [event.on_click(Seek("0")), attribute.disabled(model.index == 0)],
        [html.text("Start")],
      ),
      html.button(
        [event.on_click(Step(-1)), attribute.disabled(model.index == 0)],
        [html.text("Previous")],
      ),
      html.button(
        [event.on_click(Step(1)), attribute.disabled(model.index == last)],
        [html.text("Next")],
      ),
      html.button(
        [
          event.on_click(Seek(int.to_string(last))),
          attribute.disabled(model.index == last),
        ],
        [html.text("End")],
      ),
    ]),
    html.label([attribute.for("replay-seek")], [
      html.text(
        "Move " <> int.to_string(model.index) <> " / " <> int.to_string(last),
      ),
    ]),
    html.input([
      attribute.id("replay-seek"),
      attribute.type_("range"),
      attribute.min("0"),
      attribute.max(int.to_string(last)),
      attribute.value(int.to_string(model.index)),
      event.on_input(Seek),
    ]),
    html.p([attribute.attribute("role", "status")], [html.text(move_text)]),
  ])
}

pub fn view(model: Model, loading: Bool) {
  html.div([attribute.id("replay-page")], [
    html.h1([], [html.text("Replay")]),
    case model.error {
      Some(message) ->
        html.p(
          [attribute.class("error"), attribute.attribute("role", "alert")],
          [html.text(message)],
        )
      None -> html.text("")
    },
    case loading {
      True -> html.p([], [html.text("Loading recording…")])
      False -> html.text("")
    },
    case model.replay {
      None -> html.text("")
      Some(replay) -> {
        let current = frame(model)
        let final =
          model.index == list.length(replay.frames) - 1
          && replay.record.finished_at != None
        let dead = case final {
          True -> replay.record.dead
          False -> []
        }
        let area = case final && replay.record.scoring != "pending" {
          True -> current.board |> go.remove_stones(dead) |> go.area
          False -> dict.new()
        }
        html.div([], [
          html.div([attribute.class("replay-board")], [
            board.view(
              current.board,
              dead,
              area,
              None,
              None,
              None,
              fn(_) { Step(0) },
              fn(_) { Step(0) },
              Step(0),
            ),
          ]),
          controls(model, replay),
          html.p([], [
            html.text(case replay.record.time_settings {
              Some(timing) -> game.timing_label(timing)
              None -> "Crazy Cooldown"
            }),
          ]),
          html.ul(
            [attribute.class("live-players")],
            list.map(replay.record.seats, fn(seat) {
              html.li([], [
                html.span(
                  [
                    attribute.class("player-color"),
                    attribute.style(
                      "background-color",
                      player.color_to_str(seat.player.color),
                    ),
                  ],
                  [],
                ),
                html.strong([], [html.text(seat.player.username)]),
                html.span([], [
                  html.text(case replay.record.time_settings {
                    Some(game.DragDerby) -> "Unlimited placements"
                    Some(game.StoneSavings(_, cap, gap)) ->
                      int.to_string(seat.cooldown_ms / 1000)
                      <> "s base recharge · "
                      <> int.to_string(cap)
                      <> " stone reserve · "
                      <> int.to_string(gap)
                      <> "ms gap"
                    Some(game.CushyCooldown(_)) ->
                      int.to_string(seat.cooldown_ms / 1000)
                      <> "s cooldown · up to 25% credit"
                    _ -> int.to_string(seat.cooldown_ms / 1000) <> "s cooldown"
                  }),
                ]),
              ])
            }),
          ),
          case replay.record.finished_at {
            None ->
              html.p([], [
                html.text("Unfinished recording. No final result was recorded."),
              ])
            Some(_) ->
              html.div([], [
                html.p([], [
                  html.text(case replay.record.scoring {
                    "estimated" ->
                      "Final score: KataGo estimate (dead stones marked × at the end)."
                    "unassisted" -> "Final score: unassisted area score."
                    _ -> "Play finished; scoring was not recorded yet."
                  }),
                ]),
                html.ul(
                  [],
                  list.map(replay.record.seats, fn(seat) {
                    case dict.get(replay.record.scores, seat.player.username) {
                      Ok(score) ->
                        html.li([], [
                          html.text(
                            seat.player.username
                            <> ": "
                            <> int.to_string(score)
                            <> " points",
                          ),
                        ])
                      Error(_) -> html.text("")
                    }
                  }),
                ),
              ])
          },
        ])
      }
    },
    html.details(
      case model.replay {
        None -> [attribute.attribute("open", "")]
        Some(_) -> []
      },
      [
        html.summary([], [html.text("Paste an RTGO SGF recording")]),
        html.p([], [
          html.text(
            "Paste the contents of a downloaded .sgf file. Imports stay in this browser page; they are not uploaded.",
          ),
        ]),
        html.label([attribute.for("sgf-source")], [html.text("SGF")]),
        html.textarea(
          [
            attribute.id("sgf-source"),
            attribute.disabled(loading),
            attribute.attribute("rows", "8"),
            attribute.attribute("maxlength", "1000000"),
            event.on_input(SourceChanged),
          ],
          model.source,
        ),
        html.button([attribute.disabled(loading), event.on_click(Load)], [
          html.text("Load SGF"),
        ]),
      ],
    ),
  ])
}
