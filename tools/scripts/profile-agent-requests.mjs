#!/usr/bin/env bun
// Real Iroh/agent RPC probes. No model turns, changes to settings, or extra packages.
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { createInterface } from 'node:readline';

const binary = process.env.KITTYLITTER_BIN || 'kittylitter';
const repeats = Number(process.env.REPEATS || 3);
// Shell is a PTY service (shell/spawn/input/resize/kill), not an agent RPC surface.
const agents = (process.env.AGENTS || 'codex,pi,omp,amp,opencode,claude,droid,hermes,devin,grok,local-studio').split(',');
const methods = (process.env.METHODS || 'thread/list,model/list,config/read').split(',');
const timeout = Number(process.env.TIMEOUT_SECONDS || 45);
if (!Number.isInteger(repeats) || repeats < 1 || !Number.isFinite(timeout) || timeout <= 0) {
    throw new Error('REPEATS must be a positive integer; TIMEOUT_SECONDS must be positive');
}
const output = resolve(process.argv[2] || `artifacts/request-latency/${new Date().toISOString().replaceAll(':', '-')}`);
await mkdir(output, { recursive: true });
const identity = await mkdtemp(join(tmpdir(), 'litter-latency-'));
const rows = [];

async function probe(agent, method, iteration) {
    const started = performance.now();
    const row = { agent, method, iteration, ok: false };
    const frames = [];
    const outbound = new Map();
    const inbound = new Map();
    let requestId;
    // One pipe preserves stdout/stderr ordering. Pass every argument separately;
    // none of the binary path or probe arguments are interpreted as shell code.
    const child = spawn('/bin/sh', ['-c', 'exec "$@" 2>&1', 'litter-probe', binary,
        'probe', '--client-key-file', join(identity, `${agent}.key`),
        '--agent', agent, '--method', method, '--params', '{}', '--linger-secs', '0',
        '--timeout-secs', String(timeout)], { stdio: ['ignore', 'pipe', 'pipe'] });
    const timer = setTimeout(() => { row.timedOut = true; child.kill('SIGKILL'); }, timeout * 1000);
    for (const stream of [child.stdout, child.stderr]) {
        let frame = '';
        let direction;
        let frameAt;
        createInterface({ input: stream }).on('line', line => {
            const at = performance.now() - started;
            // The probe prints a token fingerprint in its dial diagnostic. Omit it.
            frames.push(`${at.toFixed(3)} ${line.replace(/token=\S+/g, 'token=[redacted]')}`);
            if (line.includes('iroh connection established')) row.dialMs = at;
            if (line.includes('probe: connect ok')) row.attachMs = at;
            if (/^[←→] \{/.test(line)) {
                direction = line[0];
                frame = line.slice(2);
                frameAt = at;
            } else if (frame) frame += `\n${line}`;
            // Probe frames are pretty-printed with a top-level closing brace.
            // Parsing every partial line makes large catalogs quadratic.
            if (!frame || line !== '}') return;
            let value;
            try { value = JSON.parse(frame); } catch { return; }
            frame = '';
            if (direction === '→') {
                outbound.set(value.id, frameAt);
                if (value.method === method) requestId = value.id;
            } else if (value.id != null) inbound.set(value.id, { at: frameAt, value });
        });
    }
    await new Promise(resolve => {
        child.on('error', error => { row.error = error.message; });
        child.on('close', code => { row.exitCode = code; resolve(); });
    });
    clearTimeout(timer);
    row.totalMs = performance.now() - started;
    const response = inbound.get(requestId);
    if (response && outbound.has(requestId)) {
        row.rpcMs = Math.max(0, response.at - outbound.get(requestId));
        row.responseMs = response.at;
        row.teardownMs = row.totalMs - response.at;
        row.ok = row.exitCode === 0 && !response.value.error && 'result' in response.value;
        if (response.value.error) row.error = response.value.error;
        const data = response.value.result?.data;
        if (Array.isArray(data)) row.items = data.length;
    }
    const initialize = inbound.get(1);
    if (initialize && outbound.has(1)) row.initializeMs = Math.max(0, initialize.at - outbound.get(1));
    row.evidence = `${agent}-${method.replaceAll('/', '-')}-${iteration}.log`;
    await writeFile(join(output, row.evidence), frames.join('\n') + '\n', { mode: 0o600 });
    return row;
}

function percentile(values, p) {
    values.sort((a, b) => a - b);
    return values.length ? Number(values[Math.ceil(values.length * p) - 1].toFixed(2)) : null;
}

try {
    // Sequential probes avoid mistaking a catalog storm for idle request latency.
    for (let iteration = 1; iteration <= repeats; iteration++) {
        for (const agent of agents) {
            for (const method of methods) {
                const row = await probe(agent, method, iteration);
                rows.push(row);
                await writeFile(join(output, 'requests.json'), JSON.stringify(rows, null, 2) + '\n');
                console.log(`${row.ok ? 'PASS' : 'FAIL'} ${agent} ${method} #${iteration}: rpc=${row.rpcMs?.toFixed(1) ?? '?'}ms total=${row.totalMs.toFixed(1)}ms`);
            }
        }
    }
} finally {
    await rm(identity, { recursive: true, force: true });
}
const summary = agents.flatMap(agent => methods.map(method => {
    const samples = rows.filter(row => row.agent === agent && row.method === method);
    const passed = samples.filter(row => row.ok);
    return { agent, method, passed: passed.length, failed: samples.length - passed.length,
        rpcP50Ms: percentile(passed.map(row => row.rpcMs), 0.5),
        rpcP95Ms: percentile(passed.map(row => row.rpcMs), 0.95),
        responseP50Ms: percentile(passed.map(row => row.responseMs), 0.5),
        totalP50Ms: percentile(passed.map(row => row.totalMs), 0.5) };
}));
await writeFile(join(output, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');
console.table(summary);
console.log(`Evidence: ${output}`);
process.exitCode = rows.some(row => !row.ok) ? 1 : 0;
