#!/usr/bin/env node
/**
 * Generates LitterMaterialSchemes.generated.kt for Android.
 *
 * Android's LitterTheme currently maps only a handful of Material3 color
 * roles, so Material3 components (sheets, dialogs, text fields, chips,
 * cards, etc.) fall back to the baseline M3 surface palette. This script
 * uses the official Material color-utilities (the engine behind the
 * Material Theme Builder) to derive every M3 color role from the resolved
 * Litter theme tokens, and emits a generated Kotlin file that
 * LitterAppTheme consumes to build a complete ColorScheme.
 *
 * Inputs (shared with iOS):
 *   apps/ios/Sources/Litter/Resources/Themes/theme-manifest.json
 *   apps/ios/Sources/Litter/Resources/Themes/<slug>.json
 *
 * Output:
 *   apps/android/app/src/main/java/com/litter/android/ui/LitterMaterialSchemes.generated.kt
 *
 * Run from the repo root:
 *   node tools/scripts/generate-material-schemes.mjs
 */

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  DynamicScheme,
  Hct,
  TonalPalette,
  Variant,
  MaterialDynamicColors,
} from "@material/material-color-utilities";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..", "..");
const THEMES_DIR = join(REPO_ROOT, "apps/ios/Sources/Litter/Resources/Themes");
const MANIFEST_PATH = join(THEMES_DIR, "theme-manifest.json");
const OUT_DIR = join(
  REPO_ROOT,
  "apps/android/app/src/main/java/com/litter/android/ui",
);
const OUT_PATH = join(OUT_DIR, "LitterMaterialSchemes.generated.kt");

// Every M3 color role in role order. `getArgb(scheme)` returns an ARGB int.
const ROLES = [
  "primary",
  "onPrimary",
  "primaryContainer",
  "onPrimaryContainer",
  "inversePrimary",
  "secondary",
  "onSecondary",
  "secondaryContainer",
  "onSecondaryContainer",
  "tertiary",
  "onTertiary",
  "tertiaryContainer",
  "onTertiaryContainer",
  "background",
  "onBackground",
  "surface",
  "onSurface",
  "surfaceVariant",
  "onSurfaceVariant",
  "surfaceTint",
  "inverseSurface",
  "inverseOnSurface",
  "error",
  "onError",
  "errorContainer",
  "onErrorContainer",
  "outline",
  "outlineVariant",
  "scrim",
  "surfaceDim",
  "surfaceBright",
  "surfaceContainerLowest",
  "surfaceContainerLow",
  "surfaceContainer",
  "surfaceContainerHigh",
  "surfaceContainerHighest",
];

function parseColor(hex, fallback) {
  const s = String(hex ?? "").trim();
  if (/^#[0-9a-fA-F]{3}$/.test(s)) {
    // #RGB shorthand -> #RRGGBB
    const r = s[1];
    const g = s[2];
    const b = s[3];
    return parseInt(r + r + g + g + b + b, 16) | 0xff000000;
  }
  if (/^#[0-9a-fA-F]{6}$/.test(s)) {
    return parseInt(s.slice(1), 16) | 0xff000000;
  }
  // VS Code themes occasionally carry #RRGGBBAA (alpha last). iOS drops the
  // trailing alpha pair and renders the solid color; do the same here so
  // Android matches iOS instead of reading 8-digit hex as #AARRGGBB.
  if (/^#[0-9a-fA-F]{8}$/.test(s)) {
    return parseInt(s.slice(1, 7), 16) | 0xff000000;
  }
  return fallback;
}

function brightnessOf(argb) {
  const r = ((argb >> 16) & 0xff) / 255;
  const g = ((argb >> 8) & 0xff) / 255;
  const b = (argb & 0xff) / 255;
  return 0.299 * r + 0.587 * g + 0.114 * b;
}

function adjustBrightness(argb, amount) {
  const r = Math.min(1, Math.max(0, ((argb >> 16) & 0xff) / 255 + amount));
  const g = Math.min(1, Math.max(0, ((argb >> 8) & 0xff) / 255 + amount));
  const b = Math.min(1, Math.max(0, ((argb & 0xff) / 255) + amount));
  return (
    0xff000000 |
    (Math.round(r * 255) << 16) |
    (Math.round(g * 255) << 8) |
    Math.round(b * 255)
  );
}

function dimColor(argb, factor) {
  const r = ((argb >> 16) & 0xff) / 255;
  const g = ((argb >> 8) & 0xff) / 255;
  const b = (argb & 0xff) / 255;
  if (brightnessOf(argb) > 0.5) {
    return (
      0xff000000 |
      (Math.round(r * factor * 255) << 16) |
      (Math.round(g * factor * 255) << 8) |
      Math.round(b * factor * 255)
    );
  }
  const inv = 1 - factor;
  return (
    0xff000000 |
    (Math.round((r + (1 - r) * inv) * 255) << 16) |
    (Math.round((g + (1 - g) * inv) * 255) << 8) |
    Math.round((b + (1 - b) * inv) * 255)
  );
}

/**
 * Mirror of LitterResolvedTheme.resolve() / iOS ResolvedTheme.init. Kept in
 * lockstep with those so the generated schemes always match what iOS renders.
 */
function resolveTheme(def) {
  const c = def.colors ?? {};
  const isDark = def.type === "dark";

  const background = parseColor(
    c["editor.background"],
    isDark ? 0xff111111 : 0xffffffff,
  );
  const foreground = parseColor(
    c["editor.foreground"],
    isDark ? 0xfffcfcfc : 0xff0d0d0d,
  );
  const surface =
    (c["sideBar.background"] != null &&
      c["sideBar.background"] !== "" &&
      parseColor(c["sideBar.background"], 0)) ||
    adjustBrightness(background, isDark ? 0.03 : -0.02);
  const surfaceLight =
    (c["activityBar.background"] != null &&
      c["activityBar.background"] !== "" &&
      parseColor(c["activityBar.background"], 0)) ||
    adjustBrightness(surface, isDark ? 0.04 : -0.03);
  const accent =
    (c["textLink.foreground"] != null &&
      c["textLink.foreground"] !== "" &&
      parseColor(c["textLink.foreground"], 0)) ||
    (c["button.background"] != null &&
      c["button.background"] !== "" &&
      parseColor(c["button.background"], 0)) ||
    (isDark ? 0xffb0b0b0 : 0xff4a4a4a);
  const accentStrong =
    (c["button.background"] != null &&
      c["button.background"] !== "" &&
      parseColor(c["button.background"], 0)) ||
    (c["textLink.foreground"] != null &&
      c["textLink.foreground"] !== "" &&
      parseColor(c["textLink.foreground"], 0)) ||
    accent;
  const border =
    (c["editorGroup.border"] != null &&
      c["editorGroup.border"] !== "" &&
      parseColor(c["editorGroup.border"], 0)) ||
    (c["sideBar.border"] != null &&
      c["sideBar.border"] !== "" &&
      parseColor(c["sideBar.border"], 0)) ||
    adjustBrightness(surface, isDark ? 0.05 : -0.05);
  const separator =
    (c["panel.border"] != null &&
      c["panel.border"] !== "" &&
      parseColor(c["panel.border"], 0)) ||
    adjustBrightness(background, isDark ? 0.04 : -0.04);

  const textPrimary = foreground;
  const textSecondary =
    (c["sideBar.foreground"] != null &&
      c["sideBar.foreground"] !== "" &&
      parseColor(c["sideBar.foreground"], 0)) ||
    dimColor(foreground, 0.55);
  const textMuted =
    (c["editorLineNumber.foreground"] != null &&
      c["editorLineNumber.foreground"] !== "" &&
      parseColor(c["editorLineNumber.foreground"], 0)) ||
    dimColor(foreground, 0.35);
  const textBody = dimColor(foreground, 0.88);
  const textSystem = dimColor(foreground, 0.7);
  const danger = isDark ? 0xffff5555 : 0xffd32f2f;
  const success = isDark ? 0xff6ea676 : 0xff2e7d32;
  const warning = isDark ? 0xffe2a644 : 0xffe65100;
  const textOnAccent = brightnessOf(accentStrong) > 0.5 ? 0xff0d0d0d : 0xffffffff;
  const codeBackground = background;

  return {
    isDark,
    background,
    surface,
    surfaceLight,
    textPrimary,
    textSecondary,
    textMuted,
    textBody,
    textSystem,
    accent,
    accentStrong,
    border,
    separator,
    danger,
    success,
    warning,
    textOnAccent,
    codeBackground,
  };
}

function resolveRole(role, scheme) {
  return new MaterialDynamicColors()[role]().getArgb(scheme);
}

/**
 * Build a DynamicScheme whose palettes are seeded from the resolved Litter
 * tokens, so the derived M3 roles stay faithful to the existing design.
 */
function buildScheme(tokens) {
  return new DynamicScheme({
    sourceColorHct: Hct.fromInt(tokens.accentStrong),
    variant: Variant.TONAL_SPOT,
    contrastLevel: 0.0,
    isDark: tokens.isDark,
    platform: "phone",
    specVersion: "2021",
    primaryPalette: TonalPalette.fromInt(tokens.accentStrong),
    secondaryPalette: TonalPalette.fromInt(tokens.accent),
    tertiaryPalette: TonalPalette.fromInt(tokens.success),
    neutralPalette: TonalPalette.fromInt(tokens.background),
    neutralVariantPalette: TonalPalette.fromInt(tokens.surface),
    errorPalette: TonalPalette.fromInt(tokens.danger),
  });
}

function schemeFor(manifestEntry, def) {
  const tokens = resolveTheme(def);
  const scheme = buildScheme(tokens);
  const roles = {};
  for (const role of ROLES) {
    roles[role] = resolveRole(role, scheme);
  }

  // Override roles that map 1:1 onto the resolved Litter tokens so the
  // resulting scheme keeps the exact colors iOS renders for these surfaces.
  const direct = {
    background: tokens.background,
    surface: tokens.surface,
    onSurface: tokens.textPrimary,
    onBackground: tokens.textBody,
    surfaceVariant: tokens.surfaceLight,
    onSurfaceVariant: tokens.textSecondary,
    primary: tokens.accentStrong,
    onPrimary: tokens.textOnAccent,
    secondary: tokens.accent,
    onSecondary: tokens.textPrimary,
    outline: tokens.border,
    outlineVariant: tokens.separator,
    error: tokens.danger,
    onError: tokens.textOnAccent,
  };
  for (const [role, argb] of Object.entries(direct)) {
    roles[role] = argb;
  }

  return { slug: manifestEntry.slug, type: def.type, roles };
}

function hexKt(argb) {
  return "0x" + (argb >>> 0).toString(16).toUpperCase().padStart(8, "0");
}

function main() {
  const manifest = JSON.parse(readFileSync(MANIFEST_PATH, "utf8"));
  const entries = [];

  for (const entry of manifest) {
    const defPath = join(THEMES_DIR, `${entry.slug}.json`);
    let def;
    try {
      def = JSON.parse(readFileSync(defPath, "utf8"));
    } catch {
      console.warn(`[material-schemes] missing theme file: ${entry.slug}.json`);
      continue;
    }
    entries.push(schemeFor(entry, def));
  }

  const lines = [];
  lines.push(`// @generated by tools/scripts/generate-material-schemes.mjs`);
  lines.push(`// Do not edit by hand.`);
  lines.push(`package com.litter.android.ui`);
  lines.push(``);
  lines.push(`import androidx.compose.ui.graphics.Color`);
  lines.push(``);
  lines.push(`internal data class MaterialSchemeRoles(`);
  for (const role of ROLES) {
    lines.push(`    val ${role}: Color,`);
  }
  lines.push(`)`);
  lines.push(``);
  lines.push(`internal object LitterMaterialSchemes {`);
  lines.push(`    private val schemes: Map<String, MaterialSchemeRoles> =`);
  lines.push(`        mapOf(`);
    for (const entry of entries) {
      const k = `${entry.slug}:${entry.type}`;
      lines.push(`            "${k}" to MaterialSchemeRoles(`);
    for (const role of ROLES) {
      lines.push(`                ${role} = Color(${hexKt(entry.roles[role])}),`);
    }
    lines.push(`            ),`);
  }
  lines.push(`        )`);
  lines.push(``);
  lines.push(`    fun rolesFor(slug: String, isDark: Boolean): MaterialSchemeRoles? =`);
  lines.push(`        schemes[slug + ":" + if (isDark) "dark" else "light"]`);
  lines.push(`}`);
  lines.push(``);

  mkdirSync(OUT_DIR, { recursive: true });
  writeFileSync(OUT_PATH, lines.join("\n"), "utf8");
  console.log(
    `[material-schemes] wrote ${OUT_PATH} (${entries.length} themes, ${ROLES.length} roles each)`,
  );
}

main();
