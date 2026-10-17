import gleam/option.{None}
import gleam/uri
import modem

// Resolve against the page's actual origin: works on localhost, LAN addresses,
// and HTTPS deployments without baking a hostname or port into the bundle.
pub fn server_url() -> String {
  let assert Ok(location) = modem.initial_uri()
  uri.to_string(uri.Uri(..location, path: "/api", query: None, fragment: None))
}
