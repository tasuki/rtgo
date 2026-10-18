import assert from "node:assert/strict";
import test from "node:test";
import { dragPoints, tracePoints } from "../src/rtgo_drag_ffi.mjs";

function board() {
  let captured = null;
  return {
    getScreenCTM: () => ({ inverse: () => ({}) }),
    createSVGPoint: () => ({
      x: 0, y: 0,
      matrixTransform() { return { x: this.x, y: this.y }; },
    }),
    setPointerCapture(id) { captured = id; },
    hasPointerCapture(id) { return captured === id; },
    releasePointerCapture() { captured = null; },
  };
}

function pointer(svg, type, x, y, extra = {}) {
  return {
    currentTarget: svg, type, clientX: x, clientY: y,
    pointerId: 1, button: 0, buttons: 1, isPrimary: true,
    preventDefault() {}, ...extra,
  };
}

test("fast drags include intervening cells, in either direction", () => {
  const row = Array.from({ length: 9 }, (_, x) => ({ x, y: 0 }));
  assert.deepEqual(tracePoints({ x: 1, y: 1 }, { x: 9, y: 1 }, 9), row);
  assert.deepEqual(tracePoints({ x: 9, y: 1 }, { x: 1, y: 1 }, 9), row.toReversed());
  assert.deepEqual(tracePoints({ x: 1, y: 1 }, { x: 3, y: 3 }, 9), [{ x: 0, y: 0 }, { x: 1, y: 1 }, { x: 2, y: 2 }]);
});

test("only in-bounds cells are submitted", () => {
  assert.deepEqual(tracePoints({ x: -2, y: 1 }, { x: 12, y: 1 }, 9), Array.from({ length: 9 }, (_, x) => ({ x, y: 0 })));
});

test("down sends immediately; moves suppress consecutive duplicates; up releases", () => {
  const svg = board();
  assert.deepEqual(dragPoints(pointer(svg, "pointermove", 1, 1), 9), []);
  assert.deepEqual(dragPoints(pointer(svg, "pointerdown", 1, 1), 9), [{ x: 0, y: 0 }]);
  assert.equal(svg.hasPointerCapture(1), true);
  assert.deepEqual(dragPoints(pointer(svg, "pointermove", 4, 1), 9), [{ x: 1, y: 0 }, { x: 2, y: 0 }, { x: 3, y: 0 }]);
  assert.deepEqual(dragPoints(pointer(svg, "pointermove", 4.1, 1), 9), []);
  assert.deepEqual(dragPoints(pointer(svg, "pointerup", 4.1, 1), 9), []);
  assert.equal(svg.hasPointerCapture(1), false);
  assert.deepEqual(dragPoints(pointer(svg, "pointermove", 5, 1), 9), []);
});

test("re-entering a cell later is a fresh attempt, not permanently suppressed", () => {
  const svg = board();
  dragPoints(pointer(svg, "pointerdown", 1, 1), 9);
  dragPoints(pointer(svg, "pointermove", 2, 1), 9);
  assert.deepEqual(dragPoints(pointer(svg, "pointermove", 1, 1), 9), [{ x: 0, y: 0 }]);
});

test("right button and secondary touch cannot start or hijack a gesture", () => {
  const svg = board();
  assert.deepEqual(dragPoints(pointer(svg, "pointerdown", 1, 1, { button: 2 }), 9), []);
  dragPoints(pointer(svg, "pointerdown", 1, 1), 9);
  assert.deepEqual(dragPoints(pointer(svg, "pointerdown", 5, 5, { pointerId: 2, isPrimary: false }), 9), []);
  assert.deepEqual(dragPoints(pointer(svg, "pointermove", 5, 5, { pointerId: 2 }), 9), []);
  assert.deepEqual(dragPoints(pointer(svg, "pointermove", 2, 1), 9), [{ x: 1, y: 0 }]);
});

test("cancel, capture loss and button release stop drawing", () => {
  for (const type of ["pointercancel", "lostpointercapture", "pointermove"]) {
    const svg = board();
    dragPoints(pointer(svg, "pointerdown", 1, 1), 9);
    assert.deepEqual(dragPoints(pointer(svg, type, 2, 1, { buttons: 0 }), 9), []);
    assert.deepEqual(dragPoints(pointer(svg, "pointermove", 3, 1), 9), []);
  }
});
