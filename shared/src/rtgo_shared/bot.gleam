import gleam/string

// Reserved at registration so humans cannot impersonate server-controlled seats.
pub const name_prefix = "KataGo "

pub fn is_bot(name: String) -> Bool {
  string.starts_with(name, name_prefix)
}
