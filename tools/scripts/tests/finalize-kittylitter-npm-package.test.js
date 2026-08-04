const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const test = require("node:test");

const {
  PATCH_MARKER,
  finalizePackage,
  patchBinaryInstaller,
  sha256File,
  verifyFinalizedPackage,
} = require("../finalize-kittylitter-npm-package.js");

const fixturePath = path.resolve(
  __dirname,
  "../fixtures/cargo-dist-0.31.0/binary-install.js",
);

function run(command, args) {
  const result = spawnSync(command, args, { encoding: "utf8" });
  assert.equal(
    result.status,
    0,
    `${command} ${args.join(" ")} failed:\n${result.stderr}`,
  );
  return result;
}

function makeArtifactFixture(tempDir) {
  const packageRoot = path.join(tempDir, "source", "package");
  const artifactDir = path.join(tempDir, "artifacts");
  fs.mkdirSync(packageRoot, { recursive: true });
  fs.mkdirSync(artifactDir, { recursive: true });
  fs.copyFileSync(fixturePath, path.join(packageRoot, "binary-install.js"));
  fs.writeFileSync(
    path.join(packageRoot, "package.json"),
    `${JSON.stringify({ name: "kittylitter", version: "0.0.0-test" })}\n`,
  );

  const packageName = "kittylitter-npm-package.tar.gz";
  const packagePath = path.join(artifactDir, packageName);
  run("tar", ["-czf", packagePath, "-C", path.dirname(packageRoot), "package"]);
  const originalDigest = sha256File(packagePath);

  const manifestPath = path.join(tempDir, "dist-manifest.json");
  fs.writeFileSync(
    manifestPath,
    `${JSON.stringify(
      {
        artifacts: {
          [packageName]: {
            name: packageName,
            kind: "installer",
            checksums: { sha256: originalDigest },
          },
        },
      },
      null,
      2,
    )}\n`,
  );

  const checksumPath = path.join(artifactDir, "sha256.sum");
  fs.writeFileSync(checksumPath, `${originalDigest} *${packageName}\n`);
  return { checksumPath, manifestPath, originalDigest, packagePath };
}

test("patches the pinned cargo-dist 0.31.0 Windows installer", () => {
  const source = fs.readFileSync(fixturePath, "utf8");
  const patched = patchBinaryInstaller(source);

  assert.match(patched, new RegExp(PATCH_MARKER));
  assert.match(patched, /spawnSync\("tar", \[/);
  assert.match(patched, /"-ExecutionPolicy",\s+"Bypass"/);
  assert.match(patched, /\$ErrorActionPreference = "Stop"/);
  assert.match(patched, /missing expected binaries/);
  assert.doesNotMatch(
    patched,
    /Windows does not have "unzip" by default on many installations/,
  );

  const windowsCheckout = patchBinaryInstaller(source.replace(/\n/g, "\r\n"));
  assert.match(windowsCheckout, new RegExp(PATCH_MARKER));
});

test("fails closed when cargo-dist changes the pinned extractor", () => {
  const source = fs
    .readFileSync(fixturePath, "utf8")
    .replace("Expand-Archive from powershell", "a different extractor");

  assert.throws(
    () => patchBinaryInstaller(source),
    /Windows extractor block was not found/,
  );
});

test("repacked bytes update and verify manifest and unified checksum provenance", () => {
  const tempDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "kittylitter-finalize-test-"),
  );
  try {
    const fixture = makeArtifactFixture(tempDir);
    const finalDigest = finalizePackage(
      fixture.packagePath,
      fixture.manifestPath,
      fixture.checksumPath,
    );

    assert.notEqual(finalDigest, fixture.originalDigest);
    assert.equal(finalDigest, sha256File(fixture.packagePath));
    assert.equal(
      verifyFinalizedPackage(
        fixture.packagePath,
        fixture.manifestPath,
        fixture.checksumPath,
      ),
      finalDigest,
    );

    const manifest = JSON.parse(fs.readFileSync(fixture.manifestPath, "utf8"));
    assert.equal(
      manifest.artifacts["kittylitter-npm-package.tar.gz"].checksums.sha256,
      finalDigest,
    );
    assert.equal(
      fs.readFileSync(fixture.checksumPath, "utf8"),
      `${finalDigest} *kittylitter-npm-package.tar.gz\n`,
    );
    const archiveEntries = run("tar", ["-tzf", fixture.packagePath]).stdout;
    assert.doesNotMatch(archiveEntries, /(^|\/)\._[^/]+$/m);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});

test("verification rejects bytes that no longer match recorded provenance", () => {
  const tempDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "kittylitter-verify-test-"),
  );
  try {
    const fixture = makeArtifactFixture(tempDir);
    finalizePackage(
      fixture.packagePath,
      fixture.manifestPath,
      fixture.checksumPath,
    );
    fs.appendFileSync(fixture.packagePath, "tampered");

    assert.throws(
      () =>
        verifyFinalizedPackage(
          fixture.packagePath,
          fixture.manifestPath,
          fixture.checksumPath,
        ),
      /manifest sha256 mismatch/,
    );
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
