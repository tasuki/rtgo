import envoy
import gleeunit

pub fn main() {
  // gleeunit halts the VM; the shell wrapper owns cleanup, even after failures.
  let assert Ok(directory) = envoy.get("RTGO_TEST_SGF_DIR")
    as "Run server tests with mise run test:server to isolate SGF recordings."
  envoy.set("SGF_DIR", directory)
  gleeunit.main()
}
