import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleeunit/should
import rtgo_shared/game
import rtgo_shared/player
import rtgo_shared/sgf

pub fn all_timing_settings_round_trip_test() {
  list.each(
    [
      game.Cooldown(5),
      game.CushyCooldown(5),
      game.StoneSavings(5, 7, 250),
      game.DragDerby,
    ],
    fn(mode) {
      let settings = game.Settings(13, game.MultiplayerGame, mode)
      let assert Ok(decoded) =
        settings
        |> game.settings_to_json
        |> json.to_string
        |> json.parse(game.settings_decoder())
      should.equal(decoded, settings)
    },
  )
}

pub fn old_cooldown_settings_still_decode_test() {
  let assert Ok(settings) =
    json.parse(
      "{\"board_size\":19,\"game_type\":\"two_player\",\"cooldown_seconds\":7}",
      game.settings_decoder(),
    )
  should.equal(settings.time_settings, game.Cooldown(7))
}

pub fn missing_timing_does_not_silently_create_a_default_cooldown_test() {
  should.equal(
    result.is_error(json.parse(
      "{\"board_size\":19,\"game_type\":\"two_player\"}",
      game.settings_decoder(),
    )),
    True,
  )
}

pub fn invalid_parameters_and_unimplemented_modes_are_rejected_test() {
  list.each(
    [
      game.Cooldown(0),
      game.CushyCooldown(61),
      game.StoneSavings(5, 0, 0),
      game.StoneSavings(5, 21, 0),
      game.StoneSavings(5, 3, -1),
      game.StoneSavings(5, 3, 5001),
    ],
    fn(mode) {
      should.equal(game.valid_timing(mode), False)
      let encoded = json.to_string(game.timing_to_json(mode))
      should.equal(
        result.is_error(json.parse(encoded, game.timing_decoder())),
        True,
      )
    },
  )
  should.equal(
    result.is_error(json.parse(
      "{\"mode\":\"simul_slaughter\"}",
      game.timing_decoder(),
    )),
    True,
  )
  should.equal(
    result.is_error(json.parse(
      "{\"mode\":\"drag_derby\",\"gain_move_seconds\":5}",
      game.timing_decoder(),
    )),
    True,
  )
}

pub fn drag_disables_handicaps_other_modes_keep_them_test() {
  let drag = game.Settings(9, game.TwoPlayerGame, game.DragDerby)
  should.equal(game.base_cooldown(drag), 0)
  should.equal(game.valid_player_cooldown(drag, 0), True)
  should.equal(game.valid_player_cooldown(drag, 5), False)
  list.each([game.CushyCooldown(5), game.StoneSavings(5, 3, 1000)], fn(mode) {
    let settings = game.Settings(9, game.TwoPlayerGame, mode)
    should.equal(game.valid_player_cooldown(settings, 4), False)
    should.equal(game.valid_player_cooldown(settings, 30), True)
  })
}

pub fn recording_rejects_unknown_or_invalid_timing_instead_of_silently_relabeling_test() {
  let record =
    sgf.new(9, [
      sgf.Seat("p1", player.Player("a", player.Black), 1000),
      sgf.Seat("p2", player.Player("b", player.White), 1000),
    ])
  let invalid =
    record
    |> sgf.encode
    |> string.replace(
      "RTFORMAT[1]",
      "RTFORMAT[1]RTTIMING[{\"mode\":\"simul_slaughter\"}]",
    )
  should.equal(result.is_error(sgf.decode(invalid)), True)
}
