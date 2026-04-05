import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import exec from 'nanoexec';
import { $ } from 'bun';
import { mkdtempSync } from 'node:fs';

export const TEST_HOME = mkdtempSync(path.join(os.tmpdir(), 'pmm3-'));
export const BASH_RC_FILE = path.resolve(TEST_HOME, `.bashrc`);

export const NPMRC_PATH = path.resolve(TEST_HOME, '.npmrc');
export const PMM_DIR = path.resolve(TEST_HOME, '.pmm3');
export const PMM_BIN_PATH = path.resolve(PMM_DIR, 'bin');

export const WORKSPACE_PATH = path.resolve(TEST_HOME, 'test-workspace/');
export const NODEJS_PATH_PROMISE = $`dirname "$(which node)"`.text()

export type TestProject = Awaited<ReturnType<typeof setupTestProject>>;


let testProjectCount = 0;

export async function setupTestProject({
  subDir = `test-project-${testProjectCount++}`,
  packageManager,
  scripts = {},
}: {
  subDir?: string;
  packageManager?: string;
  scripts?: Record<string, string>;
}) {
  const projectPath = path.resolve(WORKSPACE_PATH, subDir);
  const packageFilePath = path.resolve(projectPath, 'package.json');
  await fs.mkdir(projectPath, { recursive: true });
  await fs.writeFile(
    packageFilePath,
    JSON.stringify({ packageManager: packageManager, scripts })
  );
  return { projectPath, packageFilePath };
}

export async function human(
  shellCmd: string,
  { log = false, cwd = process.cwd(), skipRc = false, stdOutOnly = false } = {}
) {

  const prefix = skipRc ? '' : `source ${BASH_RC_FILE} && `;
  const cmd = exec(`${prefix}${shellCmd}`, {
    shell: '/bin/bash',
    cwd: cwd,
    env: { HOME: TEST_HOME, PATH: `${(await NODEJS_PATH_PROMISE).trim()}:/usr/local/bin:/bin:/usr/bin` },
  });


  let output = '';

  cmd.process.stdout?.on('data', (data) => {
    output += data
    if (log) {
      process.stdout.write(data)
    }
  });

  cmd.process.stderr?.on('data', (data) => {
    if (!stdOutOnly) {
      output += data
    }
    if (log) {
      process.stderr.write(data)
    }
  });

  const result = await cmd;

  if (!result.ok) {
    throw new ShellError(shellCmd, cwd, output, result.code);
  }

  return output;
}

export class ShellError extends Error {
  output: string;
  exitCode: number | null;
  constructor(shellCmd: string, cwd: string, output: string, exitCode: number | null) {
    super(
      `Error running shell command\n cmd: ${shellCmd}\n cwd: ${cwd} output: ${output}`
    );
    this.output = output;
    this.exitCode = exitCode
  }
}




export async function resetBashRc() {
  await fs.writeFile(BASH_RC_FILE, '', 'utf8');
}

export async function cleanup() {
  await fs.rm(TEST_HOME, { recursive: true, force: true }).catch(() => {
    /* ignore */
  });
}

export async function callAndCatch(fn: (...args: any[]) => Promise<any>) {
  try {
    await fn();
  } catch (error: any) {
    return error;
  }
  throw new Error(`expected ${fn.name} to reject`);
}

export async function loadPackageJson(packagePath: string) {
  const content = await fs.readFile(packagePath, 'utf8');
  return JSON.parse(content);
}