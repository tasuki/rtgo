import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/order
import gleam/otp/actor
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import player
import log

type State {
  State(users: Dict(String, Timestamp))
}

pub type Message {
  LogIn(username: String, client: Subject(Result(player.LogInResponse, Nil)))
  Prune(self: Subject(Message))
}

fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    LogIn(username, client) -> {
      let now = timestamp.system_time()

      let is_taken = case dict.get(state.users, username) {
        Ok(expiry) -> {
          case timestamp.compare(expiry, now) {
            order.Gt -> True
            _ -> False
          }
        }
        Error(Nil) -> False
      }

      case is_taken {
        True -> {
          log.info("Already taken: " <> username)
          process.send(client, Error(Nil))
          actor.continue(state)
        }
        False -> {
          let new_expiry = timestamp.add(now, duration.seconds(10))
          let new_users = dict.insert(state.users, username, new_expiry)
          log.info("Logged in as: " <> username)
          process.send(client, Ok(player.LogInResponse(username)))
          actor.continue(State(users: new_users))
        }
      }
    }

    Prune(self) -> {
      let now = timestamp.system_time()
      let new_users =
        dict.filter(state.users, fn(_, expiry) {
          case timestamp.compare(expiry, now) {
            order.Gt -> True
            _ -> False
          }
        })

      let removed_users = dict.drop(state.users, dict.keys(new_users))
      case dict.is_empty(removed_users) {
        False -> {
          let names =
            removed_users
            |> dict.keys()
            |> string.join(", ")
          log.info("Pruning users: " <> names)
        }
        True -> Nil
      }

      process.send_after(self, 1000, Prune(self))
      actor.continue(State(users: new_users))
    }
  }
}

pub fn start() -> Subject(Message) {
  let assert Ok(actor) =
    actor.new(State(users: dict.new()))
    |> actor.on_message(handle_message)
    |> actor.start
  let subject = actor.data
  process.send(subject, Prune(subject))
  subject
}

pub fn try_login(subject: Subject(Message), username: String) {
  process.call(subject, 100, fn(client) { LogIn(username, client) })
}
