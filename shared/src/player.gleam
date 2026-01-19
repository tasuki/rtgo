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

pub type Player {
  Player(name: String, color: Color)
}
