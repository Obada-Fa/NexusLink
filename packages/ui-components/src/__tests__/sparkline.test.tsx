import { describe, test, expect } from "bun:test";
import { Sparkline } from "../index.tsx";

describe("Sparkline", () => {
  test("renders SVG with line for single data point", () => {
    const element = <Sparkline data={[5]} />;
    expect(element).not.toBeNull();
  });

  test("renders SVG with path for multiple data points", () => {
    const element = <Sparkline data={[1, 2, 3, 4, 5]} />;
    expect(element).not.toBeNull();
  });

  test("accepts custom width and height", () => {
    const element = <Sparkline data={[1, 2, 3]} width={200} height={100} />;
    expect(element).not.toBeNull();
  });

  test("accepts custom color and strokeWidth", () => {
    const element = <Sparkline data={[1, 2, 3]} color="#ff0000" strokeWidth={2} />;
    expect(element).not.toBeNull();
  });

  test("handles all equal values", () => {
    const element = <Sparkline data={[5, 5, 5, 5]} />;
    expect(element).not.toBeNull();
  });

  test("handles negative values", () => {
    const element = <Sparkline data={[-3, -1, 2, 4]} />;
    expect(element).not.toBeNull();
  });
});
