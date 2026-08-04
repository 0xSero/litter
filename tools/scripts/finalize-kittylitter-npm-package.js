#!/usr/bin/env node

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const PATCH_MARKER = "LITTER_CARGO_DIST_WINDOWS_EXTRACTION_FIX";
const NPM_PACKAGE_SUFFIX = "-npm-package.tar.gz";

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    stdio: "pipe",
    ...options,
  });
  if (result.error || result.status !== 0) {
    throw new Error(
      [
        `command failed: ${command} ${args.join(" ")}`,
        result.error ? `error: ${result.error.message}` : "",
        result.stdout ? `stdout:\n${result.stdout}` : "",
        result.stderr ? `stderr:\n${result.stderr}` : "",
      ]
        .filter(Boolean)
        .join("\n"),
    );
  }
  return result;
}

function patchBinaryInstaller(source) {
  if (source.includes(PATCH_MARKER)) {
    throw new Error("cargo-dist binary installer is already finalized");
  }

  const originalWindowsExtractor = `if (this.platform.artifactName.includes("windows")) {
                  // Windows does not have "unzip" by default on many installations, instead
                  // we use Expand-Archive from powershell
                  result = spawnSync("powershell.exe", [
                    "-NoProfile",
                    "-NonInteractive",
                    "-Command",
                    \`& {
                        param([string]$LiteralPath, [string]$DestinationPath)
                        Expand-Archive -LiteralPath $LiteralPath -DestinationPath $DestinationPath -Force
                    }\`,
                    tempFile,
                    this.installDirectory,
                  ]);
                }`;

  const windowsExtractor = `if (this.platform.artifactName.includes("windows")) {
                  // ${PATCH_MARKER}
                  // Modern Windows includes bsdtar. Prefer it because some
                  // PowerShell installations cannot autoload Expand-Archive.
                  result = spawnSync("tar", [
                    "-xf",
                    tempFile,
                    "-C",
                    this.installDirectory,
                  ]);

                  if (result.error || result.status !== 0) {
                    result = spawnSync("powershell.exe", [
                      "-NoProfile",
                      "-NonInteractive",
                      "-ExecutionPolicy",
                      "Bypass",
                      "-Command",
                      \`& {
                        param([string]$LiteralPath, [string]$DestinationPath)
                        $ErrorActionPreference = "Stop"
                        Expand-Archive -LiteralPath $LiteralPath -DestinationPath $DestinationPath -Force
                    }\`,
                      tempFile,
                      this.installDirectory,
                    ]);
                  }
                }`;

  if (!source.includes(originalWindowsExtractor)) {
    throw new Error(
      "cargo-dist 0.31.0 Windows extractor block was not found; update the pinned fixture before changing the patch",
    );
  }
  source = source.replace(originalWindowsExtractor, windowsExtractor);

  const installSuccessBlock = `.then(() => {
        if (!suppressLogs) {
          console.error(\`${"${this.name}"} has been installed!\`);
        }
      })`;

  const verifiedInstallSuccessBlock = `.then(() => {
        if (!this.exists()) {
          const missing = Object.values(this.binaries)
            .map((binRelPath) => join(this.installDirectory, binRelPath))
            .filter((binPath) => !existsSync(binPath));
          throw new Error(
            \`${"${this.name}"} install failed: missing expected binaries: ${'${missing.join(", ")}'}\`,
          );
        }
        if (!suppressLogs) {
          console.error(\`${"${this.name}"} has been installed!\`);
        }
      })`;

  if (!source.includes(installSuccessBlock)) {
    throw new Error(
      "cargo-dist 0.31.0 install-success block was not found; update the pinned fixture before changing the patch",
    );
  }
  return source.replace(installSuccessBlock, verifiedInstallSuccessBlock);
}

function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  hash.update(fs.readFileSync(filePath));
  return hash.digest("hex");
}

function findArtifact(manifest, packageName) {
  if (!manifest || typeof manifest.artifacts !== "object") {
    throw new Error("cargo-dist manifest does not contain an artifacts object");
  }
  const matches = Object.entries(manifest.artifacts).filter(
    ([key, artifact]) => key === packageName || artifact?.name === packageName,
  );
  if (matches.length !== 1) {
    throw new Error(
      `expected exactly one cargo-dist manifest entry for ${packageName}, found ${matches.length}`,
    );
  }
  const artifact = matches[0][1];
  if (!artifact.checksums || typeof artifact.checksums.sha256 !== "string") {
    throw new Error(
      `cargo-dist manifest entry for ${packageName} lacks sha256`,
    );
  }
  return artifact;
}

function updateManifest(manifestPath, packageName, digest) {
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  findArtifact(manifest, packageName).checksums.sha256 = digest;
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
}

function updateChecksumList(checksumPath, packageName, digest) {
  const lines = fs.readFileSync(checksumPath, "utf8").split(/\r?\n/);
  let matches = 0;
  const updated = lines.map((line) => {
    const match = line.match(/^([a-fA-F0-9]{64})(\s+)(\*?)(.+)$/);
    if (!match || path.basename(match[4]) !== packageName) {
      return line;
    }
    matches += 1;
    return `${digest}${match[2]}${match[3]}${match[4]}`;
  });
  if (matches !== 1) {
    throw new Error(
      `expected exactly one checksum-list entry for ${packageName}, found ${matches}`,
    );
  }
  fs.writeFileSync(checksumPath, updated.join("\n"));
}

function readInstallerSource(packagePath) {
  return run("tar", ["-xOzf", packagePath, "package/binary-install.js"]).stdout;
}

function verifyFinalizedPackage(packagePath, manifestPath, checksumPath) {
  const packageName = path.basename(packagePath);
  const digest = sha256File(packagePath);
  const source = readInstallerSource(packagePath);
  if (!source.includes(PATCH_MARKER)) {
    throw new Error(
      `${packageName} does not contain the Windows extraction fix`,
    );
  }
  if (!source.includes("missing expected binaries")) {
    throw new Error(`${packageName} does not verify its installed binaries`);
  }

  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  const manifestDigest = findArtifact(manifest, packageName).checksums.sha256;
  if (manifestDigest !== digest) {
    throw new Error(
      `${packageName} manifest sha256 mismatch: expected ${digest}, found ${manifestDigest}`,
    );
  }

  const checksumLines = fs.readFileSync(checksumPath, "utf8").split(/\r?\n/);
  const matchingLines = checksumLines.filter((line) => {
    const match = line.match(/^([a-fA-F0-9]{64})\s+\*?(.+)$/);
    return match && path.basename(match[2]) === packageName;
  });
  if (matchingLines.length !== 1 || !matchingLines[0].startsWith(digest)) {
    throw new Error(
      `${packageName} unified checksum does not match final bytes`,
    );
  }
  return digest;
}

function finalizePackage(packagePath, manifestPath, checksumPath) {
  if (!fs.existsSync(packagePath)) {
    throw new Error(`npm package not found: ${packagePath}`);
  }
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "kittylitter-npm-"));
  const repackedPath = path.join(
    path.dirname(packagePath),
    `.${path.basename(packagePath)}.final-${process.pid}`,
  );
  try {
    run("tar", ["-xzf", packagePath, "-C", tempDir]);
    const installerPath = path.join(tempDir, "package", "binary-install.js");
    if (!fs.existsSync(installerPath)) {
      throw new Error(`binary-install.js not found in ${packagePath}`);
    }
    const patched = patchBinaryInstaller(
      fs.readFileSync(installerPath, "utf8"),
    );
    fs.writeFileSync(installerPath, patched);
    run("tar", ["-czf", repackedPath, "-C", tempDir, "package"], {
      // macOS bsdtar otherwise serializes extended attributes as AppleDouble
      // `._*` files, changing the npm payload depending on the finalizer host.
      env: { ...process.env, COPYFILE_DISABLE: "1" },
    });
    // copyFileSync replaces the destination on Windows, where renameSync does
    // not reliably replace an existing artifact.
    fs.copyFileSync(repackedPath, packagePath);

    const packageName = path.basename(packagePath);
    const digest = sha256File(packagePath);
    updateManifest(manifestPath, packageName, digest);
    updateChecksumList(checksumPath, packageName, digest);
    verifyFinalizedPackage(packagePath, manifestPath, checksumPath);
    return digest;
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
    fs.rmSync(repackedPath, { force: true });
  }
}

function findPackages(directory) {
  if (!fs.existsSync(directory)) {
    throw new Error(`artifact directory not found: ${directory}`);
  }
  const packages = fs
    .readdirSync(directory)
    .filter((name) => name.endsWith(NPM_PACKAGE_SUFFIX))
    .sort()
    .map((name) => path.join(directory, name));
  if (packages.length === 0) {
    throw new Error(`no ${NPM_PACKAGE_SUFFIX} artifacts found in ${directory}`);
  }
  return packages;
}

function parseArgs(argv) {
  const options = { verifyOnly: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--verify-only") {
      options.verifyOnly = true;
      continue;
    }
    const key = {
      "--directory": "directory",
      "--manifest": "manifestPath",
      "--checksum-list": "checksumPath",
    }[arg];
    if (!key || index + 1 >= argv.length) {
      throw new Error(`unknown or incomplete argument: ${arg}`);
    }
    options[key] = path.resolve(argv[index + 1]);
    index += 1;
  }
  for (const key of ["directory", "manifestPath", "checksumPath"]) {
    if (!options[key]) {
      throw new Error(`missing required option: ${key}`);
    }
  }
  return options;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  for (const packagePath of findPackages(options.directory)) {
    const digest = options.verifyOnly
      ? verifyFinalizedPackage(
          packagePath,
          options.manifestPath,
          options.checksumPath,
        )
      : finalizePackage(
          packagePath,
          options.manifestPath,
          options.checksumPath,
        );
    const action = options.verifyOnly ? "verified" : "finalized";
    console.error(`${action} ${path.basename(packagePath)} sha256=${digest}`);
  }
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}

module.exports = {
  PATCH_MARKER,
  finalizePackage,
  patchBinaryInstaller,
  sha256File,
  updateChecksumList,
  updateManifest,
  verifyFinalizedPackage,
};
