import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
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
    playing: Bool,
    clock_ms: Int,
    last_tick: Option(Timestamp),
    generation: Int,
  )
}

pub type Msg {
  SourceChanged(String)
  Load
  Seek(String)
  Step(Int)
  Start
  End
  TogglePlayback
  Tick(Int, Timestamp)
  NoOp
}

pub fn new() -> Model {
  Model("", None, 0, None, False, 0, None, 0)
}

pub fn load(model: Model, source: String) -> Model {
  case sgf.decode(source) {
    Ok(replay) ->
      Model(source, Some(replay), 0, None, False, 0, None, model.generation + 1)
    Error(message) -> Model(..model, source: source, error: Some(message))
  }
}

pub fn update(model: Model, msg: Msg) -> Model {
  case msg {
    SourceChanged(source) -> Model(..model, source: source)
    Load -> load(model, model.source)
    Seek(value) -> seek(model, int.parse(value) |> result.unwrap(model.index))
    Step(delta) -> seek(model, model.index + delta)
    Start -> seek(model, 0)
    End -> seek(model, last_index(model))
    TogglePlayback ->
      case model.playing, last_index(model) {
        True, _ -> stop(model)
        False, 0 -> model
        False, _ -> {
          let model = case model.index == last_index(model) {
            True -> seek(model, 0)
            False -> model
          }
          Model(
            ..model,
            playing: True,
            last_tick: Some(timestamp.system_time()),
            generation: model.generation + 1,
          )
        }
      }
    Tick(generation, now) -> advance(model, generation, now)
    NoOp -> model
  }
}

fn stop(model: Model) -> Model {
  Model(
    ..model,
    playing: False,
    last_tick: None,
    generation: model.generation + 1,
  )
}

fn last_index(model: Model) -> Int {
  case model.replay {
    Some(replay) -> list.length(replay.frames) - 1
    None -> 0
  }
}

fn seek(model: Model, index: Int) -> Model {
  let model =
    Model(..stop(model), index: int.clamp(index, 0, last_index(model)))
  Model(..model, clock_ms: frame_time(frame(model)))
}

fn frame_time(frame: sgf.Frame) -> Int {
  case frame.move {
    Some(move) -> move.at_ms
    None -> 0
  }
}

// Use elapsed wall time, not timer counts: background tabs and slow frames
// catch up, and moves sharing a timestamp stay in their recorded order.
fn advance(model: Model, generation: Int, now: Timestamp) -> Model {
  case model.replay, model.last_tick {
    Some(replay), Some(previous)
      if model.playing && generation == model.generation
    -> {
      let elapsed =
        timestamp.difference(previous, now)
        |> duration.to_milliseconds
        |> int.max(0)
      let clock = model.clock_ms + elapsed
      let due =
        replay.frames
        |> list.drop(model.index + 1)
        |> list.take_while(fn(frame) { frame_time(frame) <= clock })
        |> list.length
      let model =
        Model(
          ..model,
          index: model.index + due,
          clock_ms: clock,
          // Carry sub-millisecond time forward instead of rounding it away on
          // every tick, which would gradually slow long replays down.
          last_tick: Some(timestamp.add(
            previous,
            duration.milliseconds(elapsed),
          )),
        )
      case model.index == last_index(model) {
        True -> stop(model)
        False -> model
      }
    }
    _, _ -> model
  }
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

fn move_text(model: Model, replay: sgf.Replay) -> String {
  case frame(model).move {
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
}

// Listen on the application root so shortcuts also work over the menu. The
// root is focused when a replay opens; native editing/activation stays intact.
pub fn on_keydown(on_message: fn(Msg) -> msg) {
  event.advanced("keydown", {
    use key <- decode.field("key", decode.string)
    use repeat <- decode.optional_field("repeat", False, decode.bool)
    use control <- decode.optional_field("ctrlKey", False, decode.bool)
    use alt <- decode.optional_field("altKey", False, decode.bool)
    use meta <- decode.optional_field("metaKey", False, decode.bool)
    use shift <- decode.optional_field("shiftKey", False, decode.bool)
    use composing <- decode.optional_field("isComposing", False, decode.bool)
    use prevented <- decode.optional_field(
      "defaultPrevented",
      False,
      decode.bool,
    )
    use target <- decode.optional_field("target", #("", False, ""), {
      use tag <- decode.optional_field("tagName", "", decode.string)
      use id <- decode.optional_field("id", "", decode.string)
      use editable <- decode.optional_field(
        "isContentEditable",
        False,
        decode.bool,
      )
      decode.success(#(string.uppercase(tag), editable, id))
    })
    let editing =
      target.1
      || list.contains(["TEXTAREA", "SELECT"], target.0)
      || { target.0 == "INPUT" && target.2 != "replay-seek" }
    let native_space = list.contains(["BUTTON", "A", "SUMMARY"], target.0)
    let message = case key {
      "ArrowLeft" -> Some(Step(-1))
      "ArrowRight" -> Some(Step(1))
      " " if !native_space ->
        Some(case repeat {
          True -> NoOp
          False -> TogglePlayback
        })
      _ -> None
    }
    case message {
      Some(message)
        if !editing
        && !control
        && !alt
        && !meta
        && !shift
        && !composing
        && !prevented
      -> decode.success(event.handler(on_message(message), True, True))
      _ ->
        decode.failure(
          event.handler(on_message(NoOp), False, False),
          "Replay shortcut",
        )
    }
  })
}

fn control(label: String, icon: String, msg: Msg, disabled: Bool) {
  html.button(
    [
      attribute.type_("button"),
      attribute.attribute("aria-label", label),
      attribute.attribute("title", label),
      attribute.disabled(disabled),
      event.on_click(msg),
    ],
    [html.text(icon)],
  )
}

pub fn controls(model: Model) {
  case model.replay {
    Some(recording) -> playback_controls(model, recording)
    None -> html.text("")
  }
}

fn playback_controls(model: Model, replay: sgf.Replay) {
  let last = last_index(model)
  let label =
    "Move " <> int.to_string(model.index) <> " / " <> int.to_string(last)
  html.div(
    [
      attribute.class("replay-controls"),
      attribute.attribute("role", "group"),
      attribute.attribute("aria-label", "Replay controls"),
    ],
    [
      html.input([
        attribute.id("replay-seek"),
        attribute.type_("range"),
        attribute.min("0"),
        attribute.max(int.to_string(last)),
        attribute.attribute("step", "1"),
        attribute.value(int.to_string(model.index)),
        attribute.disabled(last == 0),
        attribute.attribute("aria-label", "Replay position"),
        attribute.attribute(
          "aria-valuetext",
          label <> " · " <> move_text(model, replay),
        ),
        attribute.attribute("title", label <> " · " <> move_text(model, replay)),
        event.on_input(Seek),
      ]),
      html.div([attribute.class("replay-buttons")], [
        control("Start", "⏮", Start, model.index == 0),
        control("Previous", "◀", Step(-1), model.index == 0),
        control(
          case model.playing {
            True -> "Stop"
            False -> "Play"
          },
          case model.playing {
            True -> "■"
            False -> "▶"
          },
          TogglePlayback,
          last == 0,
        ),
        control("Next", "▶|", Step(1), model.index == last),
        control("End", "⏭", End, model.index == last),
      ]),
    ],
  )
}

pub fn position(model: Model) {
  html.div([attribute.class("replay-position")], [
    html.p([], [html.text("← / →: previous / next move · Space: play / pause")]),
    case model.error {
      Some(message) ->
        html.p(
          [attribute.class("error"), attribute.attribute("role", "alert")],
          [html.text(message)],
        )
      None -> html.text("")
    },
    case model.replay {
      Some(recording) -> html.p([], [html.text(move_text(model, recording))])
      None -> html.text("")
    },
  ])
}

fn result_seats(record: sgf.Record) -> List(sgf.Seat) {
  case record.scoring {
    "pending" -> record.seats
    _ ->
      list.sort(record.seats, fn(a, b) {
        let a_score =
          dict.get(record.scores, a.player.username) |> result.unwrap(0)
        let b_score =
          dict.get(record.scores, b.player.username) |> result.unwrap(0)
        case int.compare(b_score, a_score) {
          order.Eq -> string.compare(a.player.username, b.player.username)
          compared -> compared
        }
      })
  }
}

// Recording metadata belongs in the general menu, never alongside the board.
pub fn information(model: Model) {
  html.div([], [
    html.h2([], [html.text("Replay")]),
    position(model),
    case model.replay {
      None -> html.text("")
      Some(replay) ->
        html.div([], [
          html.p([], [
            html.text(case replay.record.time_settings {
              Some(timing) -> game.timing_label(timing)
              None -> "Crazy Cooldown"
            }),
          ]),
          html.ul(
            [attribute.class("live-players")],
            list.map(result_seats(replay.record), fn(seat) {
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
                case dict.get(replay.record.scores, seat.player.username) {
                  Ok(score) ->
                    html.span([attribute.class("player-score")], [
                      html.text(int.to_string(score) <> " points"),
                    ])
                  Error(_) -> html.text("")
                },
              ])
            }),
          ),
          html.p([], [
            html.text(case replay.record.finished_at {
              None -> "Unfinished recording. No final result was recorded."
              Some(_) ->
                case replay.record.scoring {
                  "estimated" ->
                    "Final score: KataGo estimate (dead stones marked × at the end)."
                  "unassisted" -> "Final score: unassisted area score."
                  _ -> "Play finished; scoring was not recorded yet."
                }
            }),
          ]),
        ])
    },
  ])
}

pub fn importer(model: Model) {
  html.details([attribute.class("lobby-section")], [
    html.summary([], [html.text("Import an SGF recording")]),
    case model.error {
      Some(message) ->
        html.p(
          [attribute.class("error"), attribute.attribute("role", "alert")],
          [html.text(message)],
        )
      None -> html.text("")
    },
    html.p([], [
      html.text(
        "Paste the contents of a downloaded .sgf file. Imports stay in this browser page; they are not uploaded.",
      ),
    ]),
    html.label([attribute.for("sgf-source")], [html.text("SGF")]),
    html.textarea(
      [
        attribute.id("sgf-source"),
        attribute.attribute("rows", "8"),
        attribute.attribute("maxlength", "1000000"),
        event.on_input(SourceChanged),
      ],
      model.source,
    ),
    html.button([event.on_click(Load)], [
      html.text("Load SGF"),
    ]),
  ])
}

pub fn board_view(model: Model) {
  let current = frame(model)
  let final = model.index == last_index(model)
  let dead = case model.replay {
    Some(recording) if final && recording.record.finished_at != None ->
      recording.record.dead
    _ -> []
  }
  let area = case model.replay {
    Some(recording)
      if final
      && recording.record.finished_at != None
      && recording.record.scoring != "pending"
    -> current.board |> go.remove_stones(dead) |> go.area
    _ -> dict.new()
  }
  board.view(
    current.board,
    dead,
    area,
    None,
    None,
    None,
    fn(_) { NoOp },
    fn(_) { NoOp },
    NoOp,
  )
}
