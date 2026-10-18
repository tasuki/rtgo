import gleam/http.{Get, Head, Post}
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleeunit/should
import rtgo_server/web
import wisp
import wisp/simulate

const directory = "test/fixtures/frontend"

fn api(req: wisp.Request) -> wisp.Response {
  wisp.json_response(
    json.to_string(
      json.object([
        #("path", json.string(req.path)),
        #("query", json.string(option.unwrap(req.query, ""))),
        #(
          "authorization",
          json.string(
            request.get_header(req, "authorization") |> result.unwrap(""),
          ),
        ),
        #("method", json.string(http.method_to_string(req.method))),
      ]),
    ),
    202,
  )
}

pub fn serves_frontend_for_root_and_spa_deep_links_test() {
  list.each(
    ["/", "/create", "/play/room", "/replay", "/replay/room", "/index.html"],
    fn(path) {
      let response = web.handle(simulate.request(Get, path), directory, api)
      should.equal(response.status, 200)
      should.equal(
        string.contains(simulate.read_body(response), "RTGO frontend fixture"),
        True,
      )
      should.equal(
        response.get_header(response, "content-type"),
        Ok("text/html; charset=utf-8"),
      )
      should.equal(
        response.get_header(response, "cache-control"),
        Ok("no-cache"),
      )
    },
  )
}

pub fn serves_assets_with_content_types_and_conditional_gets_test() {
  let req = simulate.request(Get, "/style.css")
  let response = web.handle(req, directory, api)
  should.equal(response.status, 200)
  should.equal(
    response.get_header(response, "content-type"),
    Ok("text/css; charset=utf-8"),
  )
  should.equal(simulate.read_body(response), "body { color: black; }\n")
  let assert Ok(etag) = response.get_header(response, "etag")
  let cached =
    web.handle(request.set_header(req, "if-none-match", etag), directory, api)
  should.equal(cached.status, 304)
  should.equal(
    web.handle(simulate.request(Head, "/style.css"), directory, api).status,
    200,
  )
}

pub fn api_prefix_is_stripped_without_losing_method_query_or_credentials_test() {
  let req =
    simulate.request(Post, "/api/games/room/bots?test=hello")
    |> request.set_header("authorization", "Bearer token")
  let response = web.handle(req, directory, api)
  should.equal(response.status, 202)
  should.equal(
    simulate.read_body(response),
    "{\"path\":\"/games/room/bots\",\"query\":\"test=hello\",\"authorization\":\"Bearer token\",\"method\":\"POST\"}",
  )
  should.equal(
    simulate.read_body(web.handle(simulate.request(Get, "/api"), directory, api)),
    "{\"path\":\"/\",\"query\":\"\",\"authorization\":\"\",\"method\":\"GET\"}",
  )
}

pub fn missing_assets_unknown_apis_and_unsafe_paths_never_fall_back_to_html_test() {
  list.each(
    [
      "/missing.js", "/api/missing.js", "/play/room/extra", "/games",
      "/%2e%2e%2fprivate.txt", "/..%2fprivate.txt",
      "/%252e%252e%252fprivate.txt", "/..\\private.txt", "/%2e%2e/private.txt",
    ],
    fn(path) {
      let response = web.handle(simulate.request(Get, path), directory, api)
      should.equal(response.status, 202)
      should.equal(
        string.contains(simulate.read_body(response), "must never be served"),
        False,
      )
    },
  )
  should.equal(
    web.handle(simulate.request(Get, "/"), "no-such-directory", api).status,
    202,
  )
}
