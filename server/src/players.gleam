import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/order
import gleam/otp/actor
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import log
import player
import ywt
import ywt/claim
import ywt/sign_key.{type SignKey}
import ywt/verify_key

type State {
  State(sign_key: SignKey, users: Dict(String, Timestamp))
}

pub type Message {
  Register(
    username: String,
    client: Subject(
      Result(player.LogInResponse, player.RegistrationFailedResponse),
    ),
  )
  LogIn(
    jwt: String,
    client: Subject(Result(player.LogInResponse, player.LogInFailedResponse)),
  )
  Prune(self: Subject(Message))
}

fn expiration_duration() -> Duration {
  // 30 days
  duration.hours(24 * 30)
}

fn get_expire_claim() -> claim.Claim {
  claim.expires_at(max_age: expiration_duration(), leeway: duration.minutes(0))
}

fn gen_jwt(key: SignKey, sub: String) -> String {
  let claims = [claim.subject(sub, []), get_expire_claim()]
  ywt.encode([], claims, key)
}

fn process_login(
  state: State,
  username: String,
  now: Timestamp,
  client: Subject(Result(player.LogInResponse, _)),
) -> actor.Next(State, Message) {
  let jwt = gen_jwt(state.sign_key, username)
  process.send(client, Ok(player.LogInResponse(jwt)))
  let new_users =
    dict.insert(
      state.users,
      username,
      timestamp.add(now, expiration_duration()),
    )
  log.info("Logged in as: " <> username)
  log.debug("Accompanying JWT: " <> jwt)
  actor.continue(State(..state, users: new_users))
}

fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  let now = timestamp.system_time()
  case msg {
    Register(username, client) -> {
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
          log.info("Can't register, already taken: " <> username)
          process.send(
            client,
            Error(player.RegistrationFailedResponse(username)),
          )
          actor.continue(state)
        }
        False -> {
          log.info("Registering: " <> username)
          process_login(state, username, now, client)
        }
      }
    }

    LogIn(jwt, client) -> {
      let decoded =
        ywt.decode(jwt, player.jwt_decoder(), [get_expire_claim()], [
          verify_key.derived(state.sign_key),
        ])
      case decoded {
        Error(e) -> {
          log.info("Could not log in: " <> string.inspect(e))
          process.send(
            client,
            Error(player.LogInFailedResponse(string.inspect(e))),
          )
          actor.continue(state)
        }
        Ok(#(username, exp)) -> {
          log.info(
            "Now: "
            <> string.inspect(now)
            <> ", JWT expires: "
            <> string.inspect(exp),
          )
          process_login(state, username, now, client)
        }
      }
    }

    Prune(self) -> {
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
      actor.continue(State(..state, users: new_users))
    }
  }
}

pub fn start(sign_key: SignKey) -> Subject(Message) {
  let assert Ok(actor) =
    actor.new(State(sign_key: sign_key, users: dict.new()))
    |> actor.on_message(handle_message)
    |> actor.start
  let subject = actor.data
  process.send(subject, Prune(subject))
  subject
}

pub fn try_register(
  subject: Subject(Message),
  username: String,
) -> Result(player.LogInResponse, player.RegistrationFailedResponse) {
  process.call(subject, 100, fn(client) { Register(username, client) })
}

pub fn try_login(
  subject: Subject(Message),
  jwt: String,
) -> Result(player.LogInResponse, player.LogInFailedResponse) {
  process.call(subject, 100, fn(client) { LogIn(jwt, client) })
}
