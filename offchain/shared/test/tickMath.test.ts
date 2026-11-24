import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "vitest";
import { getSqrtPriceAtTick, MAX_TICK, MIN_TICK, TICK_MATH_FACTORS } from "../src/tickMath.js";
import { repoRoot } from "../testing/index.js";

describe("getSqrtPriceAtTick", () => {
  test("uses v4-core's constants", () => {
    const source = readFileSync(join(repoRoot, "lib/v4-core/src/libraries/TickMath.sol"), "utf8");
    const pairs = [...source.matchAll(/absTick & (0x[0-9a-f]+) != 0\) price = \(price \* (0x[0-9a-f]+)\) >> 128/g)];
    expect(pairs.map(([, bit, factor]) => [Number(bit), BigInt(factor!)])).toEqual(TICK_MATH_FACTORS);
    expect(source).toContain("0xfffcb933bd6fad37aa2d162d1a594001");
  });

  test("matches v4-core's known prices", () => {
    expect(getSqrtPriceAtTick(MIN_TICK)).toBe(4295128739n); // TickMath.MIN_SQRT_PRICE
    expect(getSqrtPriceAtTick(MAX_TICK)).toBe(1461446703485210103287273052203988822378723970342n); // MAX_SQRT_PRICE
    expect(getSqrtPriceAtTick(0)).toBe(1n << 96n);
  });

  test("increases with the tick, about 0.005% per tick", () => {
    for (const tick of [-600_000, -196_260, -1, 0, 1, 196_260, 600_000]) {
      const ratio = Number(getSqrtPriceAtTick(tick + 1) * 10n ** 12n / getSqrtPriceAtTick(tick)) / 1e12;
      expect(ratio).toBeCloseTo(Math.sqrt(1.0001), 9);
    }
  });

  test("refuses ticks outside the range", () => {
    expect(() => getSqrtPriceAtTick(MAX_TICK + 1)).toThrow(RangeError);
    expect(() => getSqrtPriceAtTick(1.5)).toThrow(RangeError);
  });
});
