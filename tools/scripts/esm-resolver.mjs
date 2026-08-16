/**
 * ESM resolver hook for @material/material-color-utilities@0.4.0.
 *
 * The 0.4.0 package ships extensionless relative imports in a few modules
 * (e.g. `from '../dynamiccolor/dynamic_scheme'`). Node's ESM loader requires
 * explicit `.js` extensions, so those imports fail with ERR_MODULE_NOT_FOUND.
 * This hook retries the resolved specifier with a `.js` extension appended.
 *
 * Register it before the generator runs, e.g.:
 *   node --import ./tools/scripts/register-esm.mjs tools/scripts/generate-material-schemes.mjs
 */

export async function resolve(specifier, context, nextResolve) {
  try {
    return await nextResolve(specifier, context);
  } catch (error) {
    const isRelative =
      specifier.startsWith("./") || specifier.startsWith("../");
    const isBareMaterialImport = specifier.startsWith("@material/");
    if ((isRelative || isBareMaterialImport) && error.code === "ERR_MODULE_NOT_FOUND") {
      return nextResolve(specifier + ".js", context);
    }
    throw error;
  }
}
