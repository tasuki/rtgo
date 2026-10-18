// Pointer capture keeps mouse, pen and touch gestures alive across board cells.
// No network/timing decisions live here: this only samples a pointer path.
const gestures = new WeakMap();

export function tracePoints(from, to, size) {
  const points = [];
  let x = Math.floor(from.x - 0.5);
  let y = Math.floor(from.y - 0.5);
  const endX = Math.floor(to.x - 0.5);
  const endY = Math.floor(to.y - 0.5);
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  const sx = Math.sign(dx);
  const sy = Math.sign(dy);
  const stepX = dx === 0 ? Infinity : Math.abs(1 / dx);
  const stepY = dy === 0 ? Infinity : Math.abs(1 / dy);
  let nextX = dx === 0 ? Infinity : (x + (sx > 0 ? 1.5 : 0.5) - from.x) / dx;
  let nextY = dy === 0 ? Infinity : (y + (sy > 0 ? 1.5 : 0.5) - from.y) / dy;
  // Browser coordinates are finite; this bound also protects synthetic events.
  const steps = Math.min(10000, Math.abs(endX - x) + Math.abs(endY - y) + 1);
  for (let i = 0; i < steps; i++) {
    if (x >= 0 && x < size && y >= 0 && y < size) points.push({ x, y });
    if (x === endX && y === endY) break;
    if (nextX < nextY) {
      x += sx;
      nextX += stepX;
    } else if (nextY < nextX) {
      y += sy;
      nextY += stepY;
    } else {
      x += sx;
      y += sy;
      nextX += stepX;
      nextY += stepY;
    }
  }
  return points;
}

export function dragPoints(event, size) {
  const svg = event.currentTarget;
  if (!svg) return [];
  let gesture = gestures.get(svg);
  if (event.type === "pointercancel" || event.type === "lostpointercapture") {
    if (gesture?.id === event.pointerId) gestures.delete(svg);
    return [];
  }
  if (event.type !== "pointerdown" && gesture?.id !== event.pointerId) return [];
  if (event.type === "pointerdown" && (event.button !== 0 || event.isPrimary === false)) return [];
  if (event.type === "pointermove" && !(event.buttons & 1)) {
    gestures.delete(svg);
    return [];
  }
  const matrix = svg.getScreenCTM();
  if (!matrix) return [];
  const point = svg.createSVGPoint();
  point.x = event.clientX;
  point.y = event.clientY;
  const position = point.matrixTransform(matrix.inverse());
  if (!Number.isFinite(position.x) || !Number.isFinite(position.y)) return [];
  if (event.type === "pointerdown") {
    if (position.x < 0.5 || position.y < 0.5 || position.x >= size + 0.5 || position.y >= size + 0.5) return [];
    gesture = { id: event.pointerId, position, last: null };
    gestures.set(svg, gesture);
    svg.setPointerCapture(event.pointerId);
  }
  const points = tracePoints(gesture.position, position, size).filter((point) => {
    const key = `${point.x},${point.y}`;
    if (key === gesture.last) return false;
    gesture.last = key;
    return true;
  });
  gesture.position = position;
  if (event.type === "pointerup") {
    gestures.delete(svg);
    if (svg.hasPointerCapture(event.pointerId)) svg.releasePointerCapture(event.pointerId);
  }
  event.preventDefault();
  return points;
}
