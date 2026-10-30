// Project-scoped adapter for godot-mcp-runtime. The upstream bridge sets NO_FOCUS
// in _ready(), after Windows has shown the initial window; apply it before launch.
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';
import childProcess from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const project = path.join(repo, 'game_dnf');
const packageRoot = process.env.DNF_GODOT_MCP_ROOT;
if (!packageRoot || !fs.existsSync(path.join(packageRoot, 'dist/index.js'))) {
  throw new Error('DNF_GODOT_MCP_ROOT must identify the installed godot-mcp-runtime package.');
}
process.env.GODOT_MCP_DISABLE_ELICITATION = 'true';
const upstreamSpawn = childProcess.spawn;
childProcess.spawn = function (command, args, options) {
  // Hide console helpers as well as Godot's console build. A GUI window still
  // needs the engine's no_focus setting below, which windowsHide cannot enforce.
  return upstreamSpawn.call(this, command, args, { ...options, windowsHide: true });
};
syncBuiltinESMExports();

function requireProject(candidate) {
  if (path.resolve(candidate).toLowerCase() !== project.toLowerCase()) {
    throw new Error('This MCP adapter serves this repository game_dnf project only.');
  }
}

function configureBackgroundOverride(original) {
  const values = new Map([
    ['window/size/no_focus', 'true'],
    ['window/size/borderless', 'true'],
    ['window/size/always_on_top', 'false'],
    ['window/size/mode', '0'],
    ['window/size/initial_position_type', '0'],
    ['window/size/initial_position', 'Vector2i(-32000, -32000)'],
  ]);
  const text = original?.toString('utf8') ?? '';
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const lines = text.split(/\r?\n/);
  // Godot treats absent config_version as a pre-3.x file and rewrites display
  // keys during loading. The override must use the same v5 schema as the project.
  const versionIndex = lines.findIndex(line => /^\s*config_version\s*=/.test(line));
  if (versionIndex < 0) lines.unshift('config_version=5', '');
  else lines[versionIndex] = 'config_version=5';
  let start = lines.findIndex(line => line.trim() === '[display]');
  if (start < 0) {
    if (lines.at(-1) !== '') lines.push('');
    lines.push('[display]');
    start = lines.length - 1;
  }
  let end = start + 1;
  while (end < lines.length && !/^\s*\[/.test(lines[end])) end++;
  for (let i = start + 1; i < end; i++) {
    const key = lines[i].match(/^\s*([^;#=]+?)\s*=/)?.[1];
    if (key && values.has(key)) {
      lines[i] = `${key}=${values.get(key)}`;
      values.delete(key);
    }
  }
  lines.splice(end, 0, ...[...values].map(([key, value]) => `${key}=${value}`));
  return Buffer.from(lines.join(eol) + eol, 'utf8');
}

const { GodotRunner } = await import(pathToFileURL(path.join(packageRoot, 'dist/utils/godot-runner.js')).href);
const runProject = GodotRunner.prototype.runProject;
const stopProject = GodotRunner.prototype.stopProject;
const priorProjectBytes = new Map();
GodotRunner.prototype.runProject = async function (candidate, scene, _background, bridgePort, profiling) {
  requireProject(candidate);
  const projectFile = path.join(project, 'project.godot');
  if (/^\s*config\/disable_project_settings_override\s*=\s*true\s*$/m.test(fs.readFileSync(projectFile, 'utf8'))) {
    throw new Error('The project disables override.cfg; cannot guarantee a background launch.');
  }
  const overrideFile = path.join(project, 'override.cfg');
  const original = fs.existsSync(overrideFile) ? fs.readFileSync(overrideFile) : null;
  const temporary = configureBackgroundOverride(original);
  priorProjectBytes.set(this, fs.readFileSync(projectFile));
  // Keep the recovery bytes local in case the server is externally terminated.
  const recoveryDir = path.join(project, '.mcp/godot-runtime/background');
  fs.mkdirSync(recoveryDir, { recursive: true });
  fs.writeFileSync(path.join(recoveryDir, 'project.godot.before'), priorProjectBytes.get(this));
  fs.writeFileSync(path.join(recoveryDir, 'override.before'), original ?? Buffer.alloc(0));
  fs.writeFileSync(path.join(recoveryDir, 'override.temporary'), temporary);
  fs.writeFileSync(path.join(recoveryDir, 'recovery.json'), JSON.stringify({ existed: original !== null, overrideFile }));
  fs.writeFileSync(overrideFile, temporary);
  try {
    // Default and explicit background:false both follow the user's background-only
    // preference. The upstream bridge also blocks physical input after _ready().
    const process = await runProject.call(this, candidate, scene, true, bridgePort, profiling);
    // Upstream runProject returns immediately after spawn. Keep the override
    // until _ready() has consumed it, rather than removing it before Godot starts.
    const readiness = await this.waitForBridge();
    if (!readiness.ready) {
      await this.stopProject();
      throw new Error(`Background bridge startup failed: ${readiness.error ?? 'timeout'}`);
    }
    return process;
  } finally {
    const current = fs.existsSync(overrideFile) ? fs.readFileSync(overrideFile) : null;
    if (current?.equals(temporary)) {
      if (original) fs.writeFileSync(overrideFile, original);
      else fs.unlinkSync(overrideFile);
      fs.unlinkSync(path.join(recoveryDir, 'recovery.json'));
    } else {
      console.error('[DNF_BACKGROUND] override.cfg changed concurrently; retained it and recovery bytes.');
    }
  }
};
GodotRunner.prototype.stopProject = async function (...args) {
  const result = await stopProject.apply(this, args);
  const original = priorProjectBytes.get(this);
  if (original) {
    const file = path.join(project, 'project.godot');
    const current = fs.readFileSync(file);
    const normalize = bytes => bytes.toString('utf8').replace(/\r\n/g, '\n').trimEnd();
    // Upstream cleanup normalizes CRLF and trailing whitespace. Restore only a
    // formatting-only change, preserving all substantive edits by other tasks.
    if (normalize(original) === normalize(current)) fs.writeFileSync(file, original);
    priorProjectBytes.delete(this);
  }
  return result;
};
await import(pathToFileURL(path.join(packageRoot, 'dist/index.js')).href);
