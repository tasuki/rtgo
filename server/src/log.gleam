import gleam/list
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import logging

fn get_prefix(input: String) -> String {
  input
  |> string.split(".")
  |> list.first
  |> result.unwrap(input)
}

fn log(level: logging.LogLevel, msg: String) {
  let logtime: String =
    timestamp.system_time()
    |> timestamp.to_rfc3339(calendar.utc_offset)
    |> get_prefix
  logging.log(level, logtime <> " " <> msg)
}

pub fn debug(msg: String) {
  log(logging.Debug, msg)
}

pub fn info(msg: String) {
  log(logging.Info, msg)
}

pub fn notice(msg: String) {
  log(logging.Notice, msg)
}

pub fn warn(msg: String) {
  log(logging.Warning, msg)
}

pub fn err(msg: String) {
  log(logging.Error, msg)
}
