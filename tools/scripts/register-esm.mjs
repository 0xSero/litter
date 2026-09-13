/**
 * Registers the ESM resolver hook for tools/scripts.
 * Load with: node --import ./tools/scripts/register-esm.mjs
 */
import { register } from "node:module";

register(new URL("./esm-resolver.mjs", import.meta.url).href);
