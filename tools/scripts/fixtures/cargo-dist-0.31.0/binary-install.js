// Pinned from cargo-dist 0.31.0 output in the published kittylitter v0.3.4 npm artifact.
// Upstream generated file: package/binary-install.js
const { createWriteStream, existsSync, mkdirSync, mkdtemp } = require("fs");
const { join, sep } = require("path");
const { spawnSync } = require("child_process");
const { tmpdir } = require("os");

const axios = require("axios");
const rimraf = require("rimraf");
const tmpDir = tmpdir();

const error = (msg) => {
  console.error(msg);
  process.exit(1);
};

class Package {
  constructor(platform, name, url, filename, zipExt, binaries) {
    let errors = [];
    if (typeof url !== "string") {
      errors.push("url must be a string");
    } else {
      try {
        new URL(url);
      } catch (e) {
        errors.push(e);
      }
    }
    if (name && typeof name !== "string") {
      errors.push("package name must be a string");
    }
    if (!name) {
      errors.push("You must specify the name of your package");
    }
    if (binaries && typeof binaries !== "object") {
      errors.push("binaries must be a string => string map");
    }
    if (!binaries) {
      errors.push("You must specify the binaries in the package");
    }

    if (errors.length > 0) {
      let errorMsg =
        "One or more of the parameters you passed to the Binary constructor are invalid:\n";
      errors.forEach((error) => {
        errorMsg += error;
      });
      errorMsg +=
        '\n\nCorrect usage: new Package("my-binary", "https://example.com/binary/download.tar.gz", {"my-binary": "my-binary"})';
      error(errorMsg);
    }

    this.platform = platform;
    this.url = url;
    this.name = name;
    this.filename = filename;
    this.zipExt = zipExt;
    this.installDirectory = join(__dirname, "node_modules", ".bin_real");
    this.binaries = binaries;

    if (!existsSync(this.installDirectory)) {
      mkdirSync(this.installDirectory, { recursive: true });
    }
  }

  exists() {
    for (const binaryName in this.binaries) {
      const binRelPath = this.binaries[binaryName];
      const binPath = join(this.installDirectory, binRelPath);
      if (!existsSync(binPath)) {
        return false;
      }
    }
    return true;
  }

  install(fetchOptions, suppressLogs = false) {
    if (this.exists()) {
      if (!suppressLogs) {
        console.error(
          `${this.name} is already installed, skipping installation.`,
        );
      }
      return Promise.resolve();
    }

    if (existsSync(this.installDirectory)) {
      rimraf.sync(this.installDirectory);
    }

    mkdirSync(this.installDirectory, { recursive: true });

    if (!suppressLogs) {
      console.error(`Downloading release from ${this.url}`);
    }

    return axios({ ...fetchOptions, url: this.url, responseType: "stream" })
      .then((res) => {
        return new Promise((resolve, reject) => {
          mkdtemp(`${tmpDir}${sep}`, (err, directory) => {
            let tempFile = join(directory, this.filename);
            const sink = res.data.pipe(createWriteStream(tempFile));
            sink.on("error", (err) => reject(err));
            sink.on("close", () => {
              if (/\.tar\.*/.test(this.zipExt)) {
                const result = spawnSync("tar", [
                  "xf",
                  tempFile,
                  // The tarballs are stored with a leading directory
                  // component; we strip one component in the
                  // shell installers too.
                  "--strip-components",
                  "1",
                  "-C",
                  this.installDirectory,
                ]);
                if (result.status == 0) {
                  resolve();
                } else if (result.error) {
                  reject(result.error);
                } else {
                  reject(
                    new Error(
                      `An error occurred untarring the artifact: stdout: ${result.stdout}; stderr: ${result.stderr}`,
                    ),
                  );
                }
              } else if (this.zipExt == ".zip") {
                let result;
                if (this.platform.artifactName.includes("windows")) {
                  // Windows does not have "unzip" by default on many installations, instead
                  // we use Expand-Archive from powershell
                  result = spawnSync("powershell.exe", [
                    "-NoProfile",
                    "-NonInteractive",
                    "-Command",
                    `& {
                        param([string]$LiteralPath, [string]$DestinationPath)
                        Expand-Archive -LiteralPath $LiteralPath -DestinationPath $DestinationPath -Force
                    }`,
                    tempFile,
                    this.installDirectory,
                  ]);
                } else {
                  result = spawnSync("unzip", [
                    "-q",
                    tempFile,
                    "-d",
                    this.installDirectory,
                  ]);
                }

                if (result.status == 0) {
                  resolve();
                } else if (result.error) {
                  reject(result.error);
                } else {
                  reject(
                    new Error(
                      `An error occurred unzipping the artifact: stdout: ${result.stdout}; stderr: ${result.stderr}`,
                    ),
                  );
                }
              } else {
                reject(
                  new Error(`Unrecognized file extension: ${this.zipExt}`),
                );
              }
            });
          });
        });
      })
      .then(() => {
        if (!suppressLogs) {
          console.error(`${this.name} has been installed!`);
        }
      })
      .catch((e) => {
        error(`Error fetching release: ${e.message}`);
      });
  }

  run(binaryName, fetchOptions) {
    const promise = !this.exists()
      ? this.install(fetchOptions, true)
      : Promise.resolve();

    promise
      .then(() => {
        const [, , ...args] = process.argv;

        const options = { cwd: process.cwd(), stdio: "inherit" };

        const binRelPath = this.binaries[binaryName];
        if (!binRelPath) {
          error(`${binaryName} is not a known binary in ${this.name}`);
        }
        const binPath = join(this.installDirectory, binRelPath);
        const result = spawnSync(binPath, args, options);

        if (result.error) {
          error(result.error);
        }

        process.exit(result.status);
      })
      .catch((e) => {
        error(e.message);
        process.exit(1);
      });
  }
}

module.exports.Package = Package;
