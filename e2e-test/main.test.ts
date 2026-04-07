import { afterAll, beforeAll, describe, expect, it, setDefaultTimeout } from "bun:test";
import { stripVTControlCharacters } from "node:util";
import { ShellError, TEST_HOME, callAndCatch, cleanup, human, loadPackageJson, setupTestProject, type TestProject } from './helpers';

const VERSION_RX = /(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)/;
const SPEC_RX =
  /(?<name>(pnpm|npm|yarn))@(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)/;

setDefaultTimeout(30_000)

afterAll(async () => {
  await cleanup();
})

describe('setup and usage', () => {
  let installOutput: string;
  beforeAll(async () => {
    installOutput = await human('zig-out/bin/pmm3 setup', { skipRc: true, });
  });

  it("logs helpful install messages", async () => {
    expect(installOutput).toMatchInlineSnapshot(`
      "Added pmm3 shell hook to ~/.bashrc
      🎁  Setup complete
      Shims installed to ~/.pmm3/bin
      "
    `)
  });

  it("installs shims to path", async () => {
    for (const shim of ['yarn', 'pnpm', 'pnpx', 'npm', 'npx']) {
      expect((await human(`which ${shim}`))).toStartWith(TEST_HOME)
    }
  });

  describe('running shims', () => {
    it('runs default version when packageManager field is not set', async () => {
      const packageManagers = [
        'npm', 'yarn', 'pnpm'
      ]
      await Promise.all(packageManagers.map(async (pm) => {
        const testProject = await setupTestProject({
          subDir: `${pm}/no-spec`,
        });
        const result = await human(`${pm} -v`, { cwd: testProject.projectPath });
        const lines = result.trim().split('\n');
        expect(lines[0]).toMatch(new RegExp(`🎁  Setting ${pm} default to version ${VERSION_RX.source}`))
        expect(lines[1]).toMatch(new RegExp(`🎁  Installing ${pm}@${VERSION_RX.source}`))
        expect(lines[2]).toMatch(new RegExp(`${VERSION_RX.source}`))
      }))
    })

    it('runs the specified package manager version based on packageManager field', async () => {
      const versions = [
        { name: 'pnpm', version: '6.32.9' },
        { name: 'npm', version: '6.14.16' },
        { name: 'yarn', version: '1.10.1' },
      ];

      await Promise.all(versions.map(async ({ name, version }) => {
        const testProject = await setupTestProject({
          subDir: `${name}/${version}`,
          packageManager: `${name}@${version}`,
        });
        const result = await human(`${name} -v`, { cwd: testProject.projectPath, stdOutOnly: true });
        expect(result.trim()).toEqual(version);
      }))
    })

    it('honors yarn 2+ packageManager specs directly', async () => {
      const testProject = await setupTestProject({
        subDir: 'yarn/4.10.3',
        packageManager: 'yarn@4.10.3',
      });

      const result = await human('yarn -v', {
        cwd: testProject.projectPath,
        stdOutOnly: true,
      });

      expect(result.trim()).toEqual('4.10.3');
    })

    it('honors yarn packageManager specs with sha suffixes', async () => {
      const testProject = await setupTestProject({
        subDir: 'yarn/3.2.3-sha',
        packageManager: 'yarn@3.2.3+sha224.953c8233f7a92884eee2de69a1b92d1f2ec1655e66d08071ba9a02fa',
      });

      const result = await human('yarn -v', {
        cwd: testProject.projectPath,
        stdOutOnly: true,
      });

      expect(result.trim()).toEqual('3.2.3');
    })
  });

  describe('pmm update-local', () => {
    describe('when called in a directory without pm spec', () => {
      let testProject: TestProject;
      let error: ShellError;

      beforeAll(async () => {
        testProject = await setupTestProject({ subDir: 'not-configured' });
        error = await callAndCatch(() =>
          human(`pmm3 update-local`, {
            cwd: testProject.projectPath,
          })
        );
      });

      it('exits with error', () => {
        expect(
          stripVTControlCharacters(error.output.trim())
        ).toBe(`⚠️  Unable to find package.json with "packageManager" field`);
      });
    });

    describe('when called in a directory with pm spec', () => {
      let testProject: TestProject;

      beforeAll(async () => {
        testProject = await setupTestProject({
          subDir: 'configured',
          packageManager: 'npm@6.0.0',
        });

        await human(`pmm3 update-local`, {
          cwd: testProject.projectPath,
        });
      });

      it('update the packageManager field', async () => {
        const { packageManager } = await loadPackageJson(
          testProject.packageFilePath
        );

        const match = /^npm@(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)/.exec(
          packageManager
        )!;

        expect(Number(match.groups?.major)).toBeGreaterThan(6);
      });
    });
  });

  describe('pmm update-default', () => {
    let testProject: TestProject;
    let output: String;

    beforeAll(async () => {
      testProject = await setupTestProject({});
      output = await human(`pmm3 update-default`, {
        cwd: testProject.projectPath,
      });
    });

    it('updates the default packageManagers', async () => {
      expect(output).toMatch('🎁  Updating all package managers');
      expect(output).toMatch(
        new RegExp(`🎁  Setting pnpm default to version ${VERSION_RX.source}`)
      );
      expect(output).toMatch(
        new RegExp(`🎁  Setting npm default to version ${VERSION_RX.source}`)
      );
      expect(output).toMatch(
        new RegExp(`🎁  Setting yarn default to version ${VERSION_RX.source}`)
      );
    });
  });

  describe('pmm pin <manager> <path>', () => {
    describe('when called in a directory without pm spec', () => {
      let testProject: TestProject;
      let result: string;
      let yarnProject: TestProject;
      let yarnResult: string;

      beforeAll(async () => {
        testProject = await setupTestProject({ subDir: 'not-configured' });
        result = await human(`pmm3 pin pnpm .`, {
          cwd: testProject.projectPath,
        });

        yarnProject = await setupTestProject({ subDir: 'yarn/pin-latest' });
        yarnResult = await human(`pmm3 pin yarn .`, {
          cwd: yarnProject.projectPath,
        });
      });

      it('writes success message', () => {
        const messageRx = new RegExp(`🎁  Pinned ${SPEC_RX.source}`);
        expect(result).toMatch(messageRx);
        expect(messageRx.exec(result)?.groups?.name).toBe('pnpm');
        expect(
          Number(messageRx.exec(result)?.groups?.major)
        ).toBeGreaterThanOrEqual(7);
      });

      it('pins yarn using a modern latest release', () => {
        const messageRx = new RegExp(`🎁  Pinned ${SPEC_RX.source}`);
        expect(yarnResult).toMatch(messageRx);
        expect(messageRx.exec(yarnResult)?.groups?.name).toBe('yarn');
        expect(
          Number(messageRx.exec(yarnResult)?.groups?.major)
        ).toBeGreaterThanOrEqual(2);
      });

      it('writes packageManager field', async () => {
        const { packageManager } = await loadPackageJson(
          testProject.packageFilePath
        );

        const rx = new RegExp(`^${SPEC_RX.source}$`);
        const match = rx.exec(packageManager)!;

        expect(match.groups?.name).toBe('pnpm');
        expect(Number(match.groups?.major)).toBeGreaterThanOrEqual(7);
      });

      it('writes a modern yarn packageManager field', async () => {
        const { packageManager } = await loadPackageJson(
          yarnProject.packageFilePath
        );

        const match = /^yarn@(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$/.exec(packageManager)!;

        expect(Number(match.groups?.major)).toBeGreaterThanOrEqual(2);
      });
    });

    describe('when called in a directory without package', () => {
      let testProject: TestProject;
      let error: ShellError;

      beforeAll(async () => {
        testProject = await setupTestProject({ subDir: 'not-configured' });
        error = await callAndCatch(() =>
          human(`pmm3 pin pnpm ./some-random-subpath`, {
            cwd: testProject.projectPath,
          })
        );
      });

      it('exits with error', () => {
        expect(
          stripVTControlCharacters(error.output.trim())
        ).toMatchInlineSnapshot(
          `"⚠️  Sorry, "package.json" not found in ./some-random-subpath"`
        );
      });
    });
  });

  describe('in a yarn berry project with v1 packageManager spec', () => {
    let testProject: TestProject;
    let result: string;

    beforeAll(async () => {
      testProject = await setupTestProject({
        packageManager: 'yarn@1.22.22',
      });
      await human(`yarn set version 3.2.1`, {
        cwd: testProject.projectPath,
      });
      result = await human(`yarn -v`, {
        cwd: testProject.projectPath,
        stdOutOnly: true
      });
    });

    it('prints yarn berry version', () => {
      expect(result.trim()).toBe('3.2.1');
    });
  });


  describe('npx', () => {
    let result: string;

    beforeAll(async () => {
      const testProject = await setupTestProject({});
      result = await human(`npx -y cowsay@1.5.0 How good is pmm!`, {
        cwd: testProject.projectPath,
      });
    });

    it('runs the cowsay cli', () => {
      expect(result).toMatchInlineSnapshot(`
        " __________________
        < How good is pmm! >
         ------------------
                \\   ^__^
                 \\  (oo)\\_______
                    (__)\\       )\\/\\
                        ||----w |
                        ||     ||
        "
      `);
    });
  });

  describe('pnpx', () => {
    let result: string;

    beforeAll(async () => {
      const testProject = await setupTestProject({});
      result = await human(`pnpx cowsay@1.5.0 How good is pmm!`, {
        cwd: testProject.projectPath,
        stdOutOnly: true
      });
    });

    it('runs the cowsay cli', () => {
      expect(result).toMatchInlineSnapshot(`
        " __________________
        < How good is pmm! >
         ------------------
                \\   ^__^
                 \\  (oo)\\_______
                    (__)\\       )\\/\\
                        ||----w |
                        ||     ||
        "
      `);
    });
  });

  describe('when a package manager is called as a child process', () => {
    let result: string;

    beforeAll(async () => {
      const testProject = await setupTestProject({
        packageManager: 'pnpm@7.5.1',
        scripts: {
          'get-npm-version': 'npm --version',
        },
      });

      result = await human(`pnpm run get-npm-version`, {
        cwd: testProject.projectPath,
        stdOutOnly: true
      });
    });

    it('allows npm to be called', () => {
      expect(result.trim()).toMatch(/\d+\.\d+\.\d+/);
    });
  });

  describe('when a package manager exits with a non zero code', () => {
    let error: ShellError;

    beforeAll(async () => {
      const testProject = await setupTestProject({
        packageManager: 'pnpm@7.5.1',
        scripts: {
          'script-with-exit-code': 'exit 1',
        },
      });

      error = await callAndCatch(() => human(`pnpm run script-with-exit-code`, {
        cwd: testProject.projectPath,
      }))


    });

    it('exits with same code', () => {
      expect(error.exitCode).toEqual(1);
    });
  });


})

