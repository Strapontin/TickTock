import { defineConfig } from "vitest/config";

// The end-to-end tests start anvil, deploy with forge, and run the indexer: they take minutes, not seconds.
export default defineConfig({
  test: { testTimeout: 180_000, hookTimeout: 600_000, fileParallelism: false },
});
