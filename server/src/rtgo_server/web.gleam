import gleam/http.{Get}
import gleam/http/request
import gleam/string
import wisp.{type Request, type Response}

/// The container serves both the SPA and its same-origin /api backend. Keep
/// unprefixed API routes working for the existing standalone development setup.
pub fn handle(
  req: Request,
  directory: String,
  api: fn(Request) -> Response,
) -> Response {
  use req <- wisp.handle_head(req)
  case req.method, wisp.path_segments(req) {
    _, ["api", ..segments] ->
      api(request.Request(..req, path: "/" <> string.join(segments, "/")))
    Get, []
    | Get, ["create"]
    | Get, ["play", _]
    | Get, ["replay"]
    | Get, ["replay", _]
    -> serve(req, "index.html", directory, fn() { api(req) })
    Get, [file] -> {
      // All generated assets are flat. Reject separators/encoded traversal
      // before serve_static's percent-decoding; never expose files above here.
      case safe_asset(file) {
        True -> serve(req, file, directory, fn() { api(req) })
        False -> api(req)
      }
    }
    _, _ -> api(req)
  }
}

fn safe_asset(file: String) -> Bool {
  !string.contains(file, "..")
  && !string.contains(file, "%")
  && !string.contains(file, "\\")
  && !string.contains(file, "/")
}

fn serve(
  req: Request,
  file: String,
  directory: String,
  next: fn() -> Response,
) -> Response {
  wisp.serve_static(
    request.Request(..req, path: "/" <> file),
    "",
    directory,
    next,
  )
  // Bundles have stable filenames; revalidate rather than caching an old build.
  |> wisp.set_header("cache-control", "no-cache")
}
