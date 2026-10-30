// Project-scoped adapter for godot-mcp-runtime 3.8.1.
// Launch through start_dnf_mcp_background.py: a private desktop isolates windows
// from the user's desktop before either Node or Godot creates a native window.
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
const installed = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'), 'utf8'));
if (installed.version !== '3.8.1') throw new Error('This adapter requires godot-mcp-runtime 3.8.1.');
if (process.env.DNF_PRIVATE_DESKTOP !== '1') {
  throw new Error('Launch through start_dnf_mcp_background.py to preserve desktop isolation.');
}
process.env.GODOT_MCP_DISABLE_ELICITATION = 'true';
const upstreamSpawn = childProcess.spawn;
childProcess.spawn = function (command, args, options) {
  return upstreamSpawn.call(this, command, args, { ...options, windowsHide: true });
};
syncBuiltinESMExports();

const { GodotRunner } = await import(pathToFileURL(path.join(packageRoot, 'dist/utils/godot-runner.js')).href);
const runProject = GodotRunner.prototype.runProject;
const stopProject = GodotRunner.prototype.stopProject;
const priorProjectBytes = new Map();
GodotRunner.prototype.runProject = async function (candidate, scene, _background, bridgePort, profiling) {
  if (path.resolve(candidate).toLowerCase() !== project.toLowerCase()) {
    throw new Error('This MCP adapter serves this repository game_dnf project only.');
  }
  const projectFile = path.join(project, 'project.godot');
  priorProjectBytes.set(this, fs.readFileSync(projectFile));
  return runProject.call(this, candidate, scene, true, bridgePort, profiling);
};
GodotRunner.prototype.stopProject = async function (...args) {
  const result = await stopProject.apply(this, args);
  const original = priorProjectBytes.get(this);
  if (original) {
    const file = path.join(project, 'project.godot');
    const current = fs.readFileSync(file);
    const normalize = bytes => bytes.toString('utf8').replace(/\r\n/g, '\n').trimEnd();
    // Upstream cleanup normalizes line endings. Restore only formatting changes;
    // substantive edits made by another task must remain intact.
    if (normalize(original) === normalize(current)) fs.writeFileSync(file, original);
    priorProjectBytes.delete(this);
  }
  return result;
};
await import(pathToFileURL(path.join(packageRoot, 'dist/index.js')).href);
