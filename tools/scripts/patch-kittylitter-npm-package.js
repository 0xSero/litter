#!/usr/bin/env node

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const root = path.resolve(__dirname, "..", "..");
const defaultPackageDir = path.join(root, "npm");
const packagePaths = process.argv.slice(2);

function fail(message) {
  console.error(message);
  process.exit(1);
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    stdio: "pipe",
    ...options,
  });
  if (result.status !== 0 || result.error) {
    fail(
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

function findPackages() {
  if (packagePaths.length > 0) {
    return packagePaths.map((p) => path.resolve(p));
  }
  if (!fs.existsSync(defaultPackageDir)) {
    fail(`npm package directory not found: ${defaultPackageDir}`);
  }
  return fs
    .readdirSync(defaultPackageDir)
    .filter((name) => name.endsWith("-npm-package.tar.gz"))
    .map((name) => path.join(defaultPackageDir, name));
}

function patchBinaryInstaller(source) {
  const windowsExtractor = `if (this.platform.artifactName.includes("windows")) {
                  // Prefer bsdtar on Windows. It is available on modern Windows
                  // installs and avoids PowerShell execution-policy failures
                  // when importing Microsoft.PowerShell.Archive.
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

  if (!source.includes(originalWindowsExtractor)) {
    fail("could not find generated Windows zip extractor block");
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
    fail("could not find generated install success block");
  }
  return source.replace(installSuccessBlock, verifiedInstallSuccessBlock);
}

function patchPackage(packagePath) {
  if (!fs.existsSync(packagePath)) {
    fail(`npm package not found: ${packagePath}`);
  }

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "kittylitter-npm-"));
  try {
    run("tar", ["-xzf", packagePath, "-C", tempDir]);
    const packageRoot = path.join(tempDir, "package");
    const installerPath = path.join(packageRoot, "binary-install.js");
    if (!fs.existsSync(installerPath)) {
      fail(`binary-install.js not found in ${packagePath}`);
    }

    const source = fs.readFileSync(installerPath, "utf8");
    const patched = patchBinaryInstaller(source);
    fs.writeFileSync(installerPath, patched);

    const repacked = `${packagePath}.patched`;
    run("tar", ["-czf", repacked, "-C", tempDir, "package"]);
    fs.renameSync(repacked, packagePath);
    console.error(`patched npm package: ${packagePath}`);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

for (const packagePath of findPackages()) {
  patchPackage(packagePath);
}
