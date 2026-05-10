import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub fn generate(length: Int) -> String {
  let vowels = ["a", "e", "i", "o", "u", "y"]
  let consonants = [
    "b", "c", "d", "f", "g", "h", "j", "k", "l", "m", "n", "p", "q", "r", "s",
    "t", "v", "w", "x", "z",
  ]

  list.range(1, length / 2)
  |> list.map(fn(_) {
    let c = get_random_element(consonants)
    let v = get_random_element(vowels)
    c <> v
  })
  |> string.concat
}

fn get_random_element(elements: List(String)) -> String {
  let index = int.random(list.length(elements))
  elements |> list.drop(index) |> list.first |> result.unwrap("")
}
