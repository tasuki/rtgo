import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import rtgo_shared/player
import rtgo_shared/sgf

fn record() -> sgf.Record {
  sgf.new(9, [
    sgf.Seat("p1", player.Player("Al:ice]\\back", player.Black), 1000),
    sgf.Seat("p2", player.Player("Bob", player.White), 2000),
    sgf.Seat("p3", player.Player("Carol", player.Cyan), 1000),
  ])
}

fn captured() -> sgf.Record {
  let moves = [
    sgf.Move("p2", #(1, 1), 0),
    sgf.Move("p1", #(0, 1), 0),
    sgf.Move("p1", #(1, 0), 1000),
    sgf.Move("p3", #(2, 1), 1000),
    sgf.Move("p1", #(1, 2), 2000),
  ]
  sgf.Record(
    ..record(),
    moves: list.reverse(moves),
    finished_at: Some(13_000),
    scoring: "estimated",
    dead: [#(2, 1)],
    scores: dict.from_list([#("Al:ice]\\back", 81), #("Bob", 0), #("Carol", 0)]),
  )
}

pub fn multiplayer_round_trip_and_captures_test() {
  let original = captured()
  let source = sgf.encode(original)
  should.equal(
    string.contains(source, "RTPLAYER[p1:Al\\:ice\\]\\\\back:black:1000]"),
    True,
  )
  let assert Ok(replay) = sgf.decode(source)
  should.equal(replay.record, original)
  should.equal(list.length(replay.frames), 6)
  let assert Ok(before) = list.first(list.drop(replay.frames, 4))
  should.equal(dict.has_key(before.board.stones, #(1, 1)), True)
  let assert Ok(after) = list.last(replay.frames)
  should.equal(dict.has_key(after.board.stones, #(1, 1)), False)
  // Dead-stone scoring metadata never deletes stones from replay history.
  should.equal(dict.has_key(after.board.stones, #(2, 1)), True)
  should.equal(dict.size(after.board.stones), 4)
}

pub fn start_date_round_trips_as_standard_dt_metadata_test() {
  let record = sgf.Record(..record(), date: Some("2026-10-18"))
  let source = sgf.encode(record)
  should.equal(string.contains(source, "DT[2026-10-18]"), True)
  let assert Ok(replay) = sgf.decode(source)
  should.equal(replay.record, record)
}

pub fn empty_and_unfinished_games_round_trip_test() {
  let assert Ok(replay) = record() |> sgf.encode |> sgf.decode
  should.equal(replay.record, record())
  should.equal(list.length(replay.frames), 1)
  should.equal(replay.record.finished_at, None)
}

pub fn two_player_records_have_standard_moves_without_double_replay_test() {
  let r =
    sgf.Record(..record(), seats: list.take(record().seats, 2), moves: [
      sgf.Move("p1", #(1, 0), 1000),
      sgf.Move("p1", #(0, 0), 0),
    ])
  let source = sgf.encode(r)
  should.equal(string.contains(source, "PB[Al\\:ice\\]\\\\back]PW[Bob]"), True)
  should.equal(string.contains(source, ";B[aa]RTMOVE[p1:aa]"), True)
  let assert Ok(replay) = sgf.decode(source)
  should.equal(list.length(replay.frames), 3)
}

pub fn invalid_or_unsupported_files_are_rejected_test() {
  let source = sgf.encode(captured())
  [
    "",
    "(;FF[4]SZ[19];B[dd])",
    "(;RTFORMAT[2]SZ[9])",
    source |> string.replace("RTFORMAT[1]", "RTFORMAT[2]"),
    source |> string.replace("SZ[9]", "SZ[99]"),
    source |> string.replace("RTFORMAT[1]", "RTFORMAT[1]RTFORMAT[1]"),
    source |> string.replace("p2:Bob:white:2000", "p1:Bob:white:2000"),
    source |> string.replace("p2:Bob:white:2000", "p2:Bob:black:2000"),
    source |> string.replace("p2:Bob:white:2000", "p2:Bob:white:-1"),
    source |> string.replace("RTMOVE[p2:bb]", "RTMOVE[unknown:bb]"),
    source |> string.replace("RTMOVE[p2:bb]", "RTMOVE[p2:zz]"),
    source |> string.replace("RTMOVE[p1:ba]", "RTMOVE[p1:ab]"),
    source |> string.replace("RTTIME[2000]", "RTTIME[1]"),
    source |> string.replace("RTEND[13000]", "RTEND[1]"),
    source |> string.replace("RTFORMAT[1]", "RTFORMAT[1]AB[aa]"),
    source |> string.replace("RTFORMAT[1]", "RTFORMAT[1]RTMOVE[p1:aa]"),
    source |> string.replace("GM[1]", "GM[2]"),
    source |> string.replace("RTSCORING[estimated]", "RTSCORING[unknown]"),
    source |> string.replace("RTSCORING[estimated]", "RTSCORING[unassisted]"),
    source
      |> string.replace(
        "RTSCORE[p1:81][p2:0][p3:0]",
        "RTSCORE[p1:81][p1:0][p3:0]",
      ),
    source |> string.replace("RTSCORE[p1:81][p2:0][p3:0]", "RTSCORE[p1:81]"),
    source |> string.replace("RTDEAD[cb]", "RTDEAD[ii]"),
    source <> "(;FF[4])",
    source |> string.replace(";RTMOVE[p2:bb]", "(;RTMOVE[p2:bb]"),
    source |> string.replace("RTFORMAT[1]", "RTFORMAT[1"),
  ]
  |> list.each(fn(input) {
    should.equal(result.is_error(sgf.decode(input)), True)
  })
}

pub fn parser_handles_whitespace_unknown_properties_and_escaped_newlines_test() {
  let source =
    record()
    |> sgf.encode
    |> string.replace("RTFORMAT[1]", "C[ignored; (; text] RTFORMAT[1]")
    |> string.replace("Carol", "Ca\\\nrol")
  let assert Ok(replay) = sgf.decode("\n \t" <> source <> "\r\n")
  should.equal(replay.record, record())
}

pub fn names_with_literal_newlines_round_trip_test() {
  let r =
    sgf.new(9, [
      sgf.Seat("p1", player.Player("A\nB", player.Black), 1000),
      sgf.Seat("p2", player.Player("A B", player.White), 1000),
    ])
  let assert Ok(replay) = r |> sgf.encode |> sgf.decode
  should.equal(replay.record, r)
}

pub fn suicide_and_superko_in_imports_are_rejected_test() {
  let suicide =
    captured()
    |> sgf.encode
    |> string.replace(")\n", ";RTMOVE[p2:bb]RTTIME[3000])\n")
  should.equal(sgf.decode(suicide), Error("Illegal move in recording."))
  let moves =
    [
      #("p1", #(1, 0)),
      #("p2", #(2, 0)),
      #("p1", #(0, 1)),
      #("p2", #(3, 1)),
      #("p1", #(1, 2)),
      #("p2", #(2, 2)),
      #("p2", #(1, 1)),
      #("p1", #(2, 1)),
    ]
    |> list.index_map(fn(m, i) { sgf.Move(m.0, m.1, i * 1000) })
    |> list.reverse
  let before = sgf.Record(..record(), moves: moves)
  let assert Ok(_) = before |> sgf.encode |> sgf.decode
  let ko = sgf.Record(..before, moves: [sgf.Move("p2", #(1, 1), 8000), ..moves])
  should.equal(
    ko |> sgf.encode |> sgf.decode,
    Error("Illegal move in recording."),
  )
}

pub fn oversized_input_is_rejected_test() {
  let source = string.repeat("a", 1_000_001)
  should.equal(sgf.decode(source), Error("SGF is too large (maximum 1 MB)."))
}
