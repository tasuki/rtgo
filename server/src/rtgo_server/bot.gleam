import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import rtgo_server/game
import rtgo_server/katago
import rtgo_server/log
import rtgo_shared/game as shared_game
import rtgo_shared/go

/// One lightweight worker per seat; the shared engine does the thinking.
pub fn start(subject: process.Subject(game.Message), name: String) -> Nil {
  let _ = process.spawn_unlinked(fn() { run(subject, name, None) })
  Nil
}

pub fn should_think(
  snapshot: game.Snapshot,
  name: String,
  last: Option(go.Stones),
) -> Bool {
  snapshot.phase == shared_game.Started
  && last != Some(snapshot.board.stones)
  && list.any(snapshot.live.players, fn(status) {
    status.player.username == name && status.cooldown_ms == 0
  })
}

fn run(
  subject: process.Subject(game.Message),
  name: String,
  last: Option(go.Stones),
) -> Nil {
  let snapshot = game.get_game(subject)
  case snapshot.phase {
    shared_game.Finished -> Nil
    _ -> {
      let last = case should_think(snapshot, name, last) {
        False -> last
        True -> {
          case katago.move(snapshot.board, name) {
            Ok(point) -> {
              case point {
                Some(point) -> {
                  // No tactical overrides. The authoritative game
                  // still checks legality and cooldown against its current board.
                  let _ = game.play(subject, name, point)
                  Nil
                }
                None -> {
                  let _ = game.pass(subject, name)
                  Nil
                }
              }
              // Passes and rejections don't repeatedly query the same position.
              Some(snapshot.board.stones)
            }
            Error(_) -> {
              log.info("KataGo could not choose a move for " <> name)
              process.sleep(1000)
              None
            }
          }
        }
      }
      // Don't retain the snapshot's complete superko history while sleeping.
      wait(subject, name, last)
    }
  }
}

fn wait(
  subject: process.Subject(game.Message),
  name: String,
  last: Option(go.Stones),
) -> Nil {
  process.sleep(250)
  run(subject, name, last)
}
