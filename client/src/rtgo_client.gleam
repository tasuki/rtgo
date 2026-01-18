import lustre
import lustre/element/html

pub fn main() -> Nil {
  let app = lustre.element(html.text("Hello, world!"))
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}
