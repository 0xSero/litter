#!/usr/bin/env node

const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

function fail(message) {
  throw new Error(message);
}

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env ?? process.env,
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (status, signal) => {
      resolve({ signal, status, stderr, stdout });
    });
  });
}

function requireSuccess(result, description) {
  if (result.status !== 0) {
    fail(
      `${description} failed with status ${result.status}:\n${result.stdout}\n${result.stderr}`,
    );
  }
}

function startArchiveServer(archivePath) {
  const archiveName = path.basename(archivePath);
  const server = http.createServer((request, response) => {
    if (request.url !== `/${archiveName}`) {
      response.writeHead(404);
      response.end("not found");
      return;
    }
    response.writeHead(200, {
      "Content-Length": fs.statSync(archivePath).size,
      "Content-Type": "application/zip",
    });
    fs.createReadStream(archivePath).pipe(response);
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      resolve({
        baseUrl: `http://127.0.0.1:${address.port}`,
        close: () => new Promise((done) => server.close(done)),
      });
    });
  });
}

async function main() {
  if (process.platform !== "win32") {
    fail("the kittylitter npm installer smoke test must run on Windows");
  }
  const [packageArgument, archiveArgument] = process.argv.slice(2);
  if (!packageArgument || !archiveArgument) {
    fail(
      "usage: test-kittylitter-npm-windows.js <npm-package.tar.gz> <windows.zip>",
    );
  }
  const packagePath = path.resolve(packageArgument);
  const archivePath = path.resolve(archiveArgument);
  for (const artifactPath of [packagePath, archivePath]) {
    if (!fs.existsSync(artifactPath)) {
      fail(`artifact not found: ${artifactPath}`);
    }
  }

  const tempDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "kittylitter-win-smoke-"),
  );
  const server = await startArchiveServer(archivePath);
  try {
    fs.writeFileSync(
      path.join(tempDir, "package.json"),
      `${JSON.stringify({ name: "kittylitter-windows-smoke", private: true })}\n`,
    );
    const npm = process.platform === "win32" ? "npm.cmd" : "npm";
    const npmInstall = await run(
      npm,
      ["install", "--ignore-scripts", "--no-audit", "--no-fund", packagePath],
      { cwd: tempDir },
    );
    requireSuccess(npmInstall, "installing the finalized npm tarball");

    const packageRoot = path.join(tempDir, "node_modules", "kittylitter");
    const metadataPath = path.join(packageRoot, "package.json");
    const metadata = JSON.parse(fs.readFileSync(metadataPath, "utf8"));
    const windowsTarget = metadata.supportedPlatforms["x86_64-pc-windows-msvc"];
    if (!windowsTarget) {
      fail("final npm package lacks x86_64-pc-windows-msvc metadata");
    }
    metadata.artifactDownloadUrls = [server.baseUrl];
    windowsTarget.artifactName = path.basename(archivePath);
    fs.writeFileSync(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`);

    const install = await run(process.execPath, ["install.js"], {
      cwd: packageRoot,
    });
    requireSuccess(install, "extracting the real Windows archive");
    const installOutput = `${install.stdout}\n${install.stderr}`;
    if (!installOutput.includes("kittylitter has been installed!")) {
      fail(`successful install omitted confirmation:\n${installOutput}`);
    }

    const installDirectory = path.join(
      packageRoot,
      "node_modules",
      ".bin_real",
    );
    const executablePath = path.join(installDirectory, "kittylitter.exe");
    if (!fs.existsSync(executablePath)) {
      fail(`successful install did not create ${executablePath}`);
    }
    const version = await run(executablePath, ["--version"], { cwd: tempDir });
    requireSuccess(version, "executing the installed kittylitter.exe");
    if (
      !`${version.stdout}\n${version.stderr}`
        .toLowerCase()
        .includes("kittylitter")
    ) {
      fail("kittylitter.exe --version did not identify kittylitter");
    }

    fs.rmSync(installDirectory, { recursive: true, force: true });
    metadata.supportedPlatforms["x86_64-pc-windows-msvc"].bins.kittylitter =
      "missing-kittylitter.exe";
    fs.writeFileSync(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`);

    const missingBinary = await run(process.execPath, ["install.js"], {
      cwd: packageRoot,
    });
    const missingOutput = `${missingBinary.stdout}\n${missingBinary.stderr}`;
    if (missingBinary.status === 0) {
      fail(`missing-binary install unexpectedly succeeded:\n${missingOutput}`);
    }
    if (missingOutput.includes("kittylitter has been installed!")) {
      fail(`missing-binary install printed false success:\n${missingOutput}`);
    }
    if (!missingOutput.includes("missing expected binaries")) {
      fail(
        `missing-binary install lacked actionable failure:\n${missingOutput}`,
      );
    }

    console.log("finalized npm tarball installed and executed kittylitter.exe");
    console.log("missing-binary extraction failed without false success");
  } finally {
    await server.close();
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
