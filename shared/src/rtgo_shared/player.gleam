pub type Color {
  Black
  White
  Cyan
  Green
  Orange
  Pink
  Purple
  Blue
}

pub fn color_to_str(color: Color) {
  case color {
    Black -> "#333"
    White -> "#FFF"
    Cyan -> "#0FC"
    Green -> "#CF0"
    Orange -> "#F80"
    Pink -> "#F3C"
    Purple -> "#85F"
    Blue -> "#08F"
  }
}

pub const all_colors = [Black, White, Cyan, Green, Orange, Pink, Purple, Blue]

pub const two_player_colors = [Black, White]

pub type Player {
  Player(username: String, color: Color)
}
