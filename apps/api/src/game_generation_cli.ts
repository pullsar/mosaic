import {mkdir, writeFile} from 'node:fs/promises';
import {dirname, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

import {
  generateOneMoveMatchstickDrafts,
  type OneMoveGenerationRequest,
} from './game_generation.js';

export interface OneMoveGenerationCliRequest extends OneMoveGenerationRequest {
  readonly outputPath: string;
}

export function parseOneMoveGenerationCliArgs(
  args: readonly string[],
): OneMoveGenerationCliRequest {
  let seed: number | undefined;
  let count: number | undefined;
  let themePreference: string | undefined;
  let outputPath: string | undefined;
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    const value = args[index + 1];
    if (value === undefined) throw new Error(`missing value for ${flag}`);
    switch (flag) {
      case '--seed':
        seed = Number(value);
        break;
      case '--count':
        count = Number(value);
        break;
      case '--theme':
        themePreference = value;
        break;
      case '--output':
        outputPath = value;
        break;
      default:
        throw new Error(`unknown option: ${flag}`);
    }
    index += 1;
  }
  if (seed === undefined || count === undefined || outputPath === undefined) {
    throw new Error('seed, count, and output are required');
  }
  if (outputPath.trim().length === 0) throw new Error('output must not be empty');
  return Object.freeze({
    seed,
    count,
    outputPath: resolve(outputPath),
    ...(themePreference === undefined ? {} : {themePreference}),
  });
}

export async function writeOneMoveGenerationDrafts(
  request: OneMoveGenerationCliRequest,
): Promise<string> {
  const outputPath = resolve(request.outputPath);
  await mkdir(dirname(outputPath), {recursive: true});
  const result = generateOneMoveMatchstickDrafts(request);
  await writeFile(outputPath, `${JSON.stringify(result, null, 2)}\n`, {
    encoding: 'utf8',
    flag: 'wx',
  });
  return outputPath;
}

async function main(): Promise<void> {
  const request = parseOneMoveGenerationCliArgs(process.argv.slice(2));
  const outputPath = await writeOneMoveGenerationDrafts(request);
  process.stdout.write(`${outputPath}\n`);
}

const invokedPath = process.argv[1];
if (invokedPath !== undefined && import.meta.url === pathToFileURL(invokedPath).href) {
  void main().catch((error: unknown) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
