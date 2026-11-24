import { defineConfig } from "vitest/config";

// The tests start anvil and deploy with forge: they take a minute, not seconds.
export default defineConfig({
  test: { testTimeout: 180_000, hookTimeout: 600_000, fileParallelism: false },
});
