import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import rtgo_server/bot
import rtgo_server/game
import rtgo_server/katago
import rtgo_shared/game as shared_game
import rtgo_shared/go
import rtgo_shared/player

fn policy_response(size: Int, best: Int) -> String {
  json.object([
    // As in a real one-visit response, there are no searched child moves.
    #("moveInfos", json.array([], json.string)),
    #(
      "policy",
      json.array(list.range(0, size * size), fn(i) {
        case i == best {
          True -> json.float(0.9)
          False -> json.int(-1)
        }
      }),
    ),
  ])
  |> json.to_string
}

pub fn policy_coordinates_and_gtp_queries_agree_on_all_board_sizes_test() {
  list.each([9, 13, 19], fn(size) {
    list.each([0, size - 1, size * size / 2, size * size - 1], fn(index) {
      should.equal(
        katago.response(policy_response(size, index), size),
        Ok(Some(#(index % size, index / size))),
      )
    })
  })
  should.equal(katago.vertex(#(0, 0), 9), "A9")
  should.equal(katago.vertex(#(8, 0), 19), "J19")
  should.equal(katago.vertex(#(18, 18), 19), "T1")
}

pub fn query_collapses_only_other_players_and_uses_fixed_settings_test() {
  let board =
    go.Game(
      ..go.new_game(13),
      stones: dict.from_list([
        #(#(0, 0), player.Player("bot", player.Orange)),
        #(#(1, 1), player.Player("human", player.Black)),
        #(#(2, 2), player.Player("other bot", player.Blue)),
      ]),
    )
  let decoder = {
    use id <- decode.field("id", decode.string)
    use size_x <- decode.field("boardXSize", decode.int)
    use size_y <- decode.field("boardYSize", decode.int)
    use visits <- decode.field("maxVisits", decode.int)
    use include_policy <- decode.field("includePolicy", decode.bool)
    use komi <- decode.field("komi", decode.int)
    use initial <- decode.field("initialPlayer", decode.string)
    use moves <- decode.field("moves", decode.list(decode.string))
    use stones <- decode.field(
      "initialStones",
      decode.list(decode.list(decode.string)),
    )
    decode.success(#(
      id,
      size_x,
      size_y,
      visits,
      include_policy,
      komi,
      initial,
      moves,
      stones,
    ))
  }
  let assert Ok(#(
    id,
    x,
    y,
    visits,
    include_policy,
    komi,
    initial,
    moves,
    stones,
  )) = json.parse(katago.query(board, "bot", "test"), decoder)
  should.equal(
    #(id, x, y, visits, include_policy, komi, initial, moves),
    #("test", 13, 13, 1, True, 0, "B", []),
  )
  should.equal(list.length(stones), 3)
  list.each([["B", "A13"], ["W", "B12"], ["W", "C11"]], fn(stone) {
    should.equal(list.contains(stones, stone), True)
  })
}

pub fn response_uses_only_highest_policy_and_preserves_passes_test() {
  should.equal(katago.response(policy_response(9, 81), 9), Ok(None))
  should.equal(
    katago.response("{\"policy\":[-1,0.1,0.2,0.6,0.1]}", 2),
    Ok(Some(#(1, 1))),
  )
  list.each(
    [
      "not json", "{\"error\":\"bad position\"}", "{\"moveInfos\":[]}",
      "{\"policy\":[]}", "{\"policy\":[-1,-1,-1,-1,-1]}",
    ],
    fn(body) { katago.response(body, 2) |> should.be_error },
  )
}

pub fn ownership_is_decoded_row_major_with_strict_shape_and_range_checks_test() {
  should.equal(
    katago.ownership_response("{\"ownership\":[-1,0,0.5,1]}", 2),
    Ok(
      dict.from_list([
        #(#(0, 0), -1.0),
        #(#(1, 0), 0.0),
        #(#(0, 1), 0.5),
        #(#(1, 1), 1.0),
      ]),
    ),
  )
  list.each(
    [
      "{}", "{\"ownership\":[]}", "{\"ownership\":[1,1,1]}",
      "{\"ownership\":[1,1,1,2]}", "{\"ownership\":[-2,0,0,0]}",
      "{\"ownership\":[1,1,1,null]}", "not json",
    ],
    fn(body) { katago.ownership_response(body, 2) |> should.be_error },
  )
}

pub fn ownership_requests_one_visit_in_owners_turn_without_averaging_test() {
  let decoder = {
    use initial <- decode.field("initialPlayer", decode.string)
    use include <- decode.field("includeOwnership", decode.bool)
    use report <- decode.then(decode.at(
      ["overrideSettings", "reportAnalysisWinratesAs"],
      decode.string,
    ))
    use visits <- decode.field("maxVisits", decode.int)
    use symmetries <- decode.then(decode.at(
      ["overrideSettings", "rootNumSymmetriesToSample"],
      decode.int,
    ))
    decode.success(#(initial, include, report, visits, symmetries))
  }
  list.each([9, 13, 19], fn(size) {
    should.equal(
      json.parse(
        katago.ownership_query(go.new_game(size), "bot", "test"),
        decoder,
      ),
      Ok(#("B", True, "BLACK", 1, 1)),
    )
  })
}

pub fn ownership_queries_keep_original_stone_coordinates_and_colors_test() {
  let board =
    go.Game(
      ..go.new_game(9),
      stones: dict.from_list([
        #(#(1, 2), player.Player("bot", player.Orange)),
      ]),
    )
  let decoder = {
    use stones <- decode.field(
      "initialStones",
      decode.list(decode.list(decode.string)),
    )
    decode.success(stones)
  }
  should.equal(
    json.parse(katago.ownership_query(board, "bot", "test"), decoder),
    Ok([["B", "B7"]]),
  )
}

pub fn ownership_coordinates_round_trip_on_every_board_size_test() {
  list.each([9, 13, 19], fn(size) {
    let points = list.range(0, size * size - 1)
    let value = fn(i) { int.to_float(i) /. int.to_float(size * size) }
    let expected =
      points
      |> list.map(fn(i) { #(#(i % size, i / size), value(i)) })
      |> dict.from_list
    let body =
      json.object([
        #("ownership", json.array(points, fn(i) { json.float(value(i)) })),
      ])
      |> json.to_string
    should.equal(katago.ownership_response(body, size), Ok(expected))
  })
}

pub fn bot_waits_for_cooldown_and_new_positions_after_passing_test() {
  let players =
    dict.from_list([
      #("bot", player.Player("bot", player.Black)),
      #("human", player.Player("human", player.White)),
    ])
  let state =
    game.new_state(players, shared_game.default_settings, dict.new(), 0)
  let ready = shared_game.base_cooldown(state.settings) * 1000
  should.equal(bot.should_think(game.snapshot_at(state, 0), "bot", None), False)
  should.equal(
    bot.should_think(game.snapshot_at(state, ready - 1), "bot", None),
    False,
  )
  let snapshot = game.snapshot_at(state, ready)
  should.equal(bot.should_think(snapshot, "bot", None), True)
  should.equal(bot.should_think(snapshot, "unknown", None), False)
  should.equal(
    bot.should_think(snapshot, "bot", Some(snapshot.board.stones)),
    False,
  )
  let assert Ok(moved) = game.play_at(state, "bot", #(0, 0), ready)
  should.equal(
    bot.should_think(game.snapshot_at(moved, ready + 1), "bot", None),
    False,
  )
  should.equal(
    bot.should_think(
      game.snapshot_at(moved, ready * 2),
      "bot",
      Some(snapshot.board.stones),
    ),
    True,
  )
  should.equal(
    bot.should_think(
      game.snapshot_at(moved, ready * 2 + game.pass_grace_ms),
      "bot",
      None,
    ),
    False,
  )
}
