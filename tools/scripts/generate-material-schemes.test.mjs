import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, mkdirSync, copyFileSync, symlinkSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { parseColor, schemeFor } from "./generate-material-schemes.mjs";

const themesDir = new URL("../../apps/ios/Sources/Litter/Resources/Themes/", import.meta.url);
const manifest = JSON.parse(readFileSync(new URL("theme-manifest.json", themesDir)));

test("theme hex colors use solid CSS RGB, including alpha-last values", () => {
  for (const [hex, expected] of [["#45858880", 0xff458588], ["#abc", 0xffaabbcc], [" #123456 ", 0xff123456]]) {
    assert.equal(parseColor(hex, 0) >>> 0, expected);
  }
  assert.equal(parseColor("#oops", 123), 123);
  assert.equal(parseColor(null, 123), 123);
});

test("every bundled theme generates a complete, deterministic opaque scheme", () => {
  const keys = new Set();
  for (const entry of manifest) {
    const def = JSON.parse(readFileSync(new URL(`${entry.slug}.json`, themesDir)));
    const result = schemeFor(entry, def);
    const key = `${result.slug}:${result.type}`;
    assert.ok(!keys.has(key), `duplicate ${key}`);
    keys.add(key);
    assert.equal(Object.keys(result.roles).length, 36, key);
    assert.deepEqual(result, schemeFor(entry, def), key);
    for (const [role, color] of Object.entries(result.roles)) {
      assert.ok(Number.isInteger(color), `${key} ${role}`);
      assert.equal(color >>> 24, 255, `${key} ${role}`);
    }
    assert.equal(result.roles.background >>> 0, parseColor(def.colors["editor.background"], def.type === "dark" ? 0xff111111 : 0xffffffff) >>> 0);
  }
});

test("gruvbox's alpha-last button color keeps its RGB channels", () => {
  const def = JSON.parse(readFileSync(new URL("gruvbox-dark-medium.json", themesDir)));
  assert.equal(schemeFor({slug: "gruvbox-dark-medium"}, def).roles.primary >>> 0, 0xff458588);
});


test("a missing bundled theme fails generation instead of emitting a partial table", () => {
  const root = mkdtempSync(join(tmpdir(), "material-schemes-test-"));
  try {
    const scripts = join(root, "tools/scripts");
    mkdirSync(scripts, { recursive: true });
    for (const file of ["generate-material-schemes.mjs", "register-esm.mjs", "esm-resolver.mjs"]) {
      copyFileSync(new URL(file, import.meta.url), join(scripts, file));
    }
    symlinkSync(new URL("node_modules", import.meta.url), join(scripts, "node_modules"));
    const themes = join(root, "apps/ios/Sources/Litter/Resources/Themes");
    mkdirSync(themes, { recursive: true });
    writeFileSync(join(themes, "theme-manifest.json"), JSON.stringify([{ slug: "missing" }]));
    const result = spawnSync(process.execPath, ["--import", join(scripts, "register-esm.mjs"), join(scripts, "generate-material-schemes.mjs")], { encoding: "utf8" });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /missing\.json/);
    assert.equal(existsSync(join(root, "apps/android/app/src/main/java/com/litter/android/ui/LitterMaterialSchemes.generated.kt")), false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
