import {readFile, readdir} from 'node:fs/promises';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {Pool} from 'pg';
import {loadConfig} from '../config.js';

const here = dirname(fileURLToPath(import.meta.url));
const migrationDir = join(here, '../../migrations');

interface Migration {
  name: string;
  upPath: string;
  downPath: string;
}

async function discover(): Promise<Migration[]> {
  const files = await readdir(migrationDir);
  const ups = files.filter((name) => name.endsWith('.up.sql')).sort();
  return ups.map((up) => {
    const name = up.slice(0, -'.up.sql'.length);
    return {
      name,
      upPath: join(migrationDir, up),
      downPath: join(migrationDir, `${name}.down.sql`),
    };
  });
}

async function ensureLedger(pool: Pool): Promise<void> {
  await pool.query(`
    create table if not exists schema_migrations (
      name text primary key,
      applied_at timestamptz not null default now()
    )
  `);
}

async function applied(pool: Pool): Promise<string[]> {
  const result = await pool.query<{name: string}>('select name from schema_migrations order by name');
  return result.rows.map((row) => row.name);
}

async function up(pool: Pool): Promise<void> {
  await ensureLedger(pool);
  const known = new Set(await applied(pool));
  for (const migration of await discover()) {
    if (known.has(migration.name)) continue;
    const sql = await readFile(migration.upPath, 'utf8');
    const client = await pool.connect();
    try {
      await client.query('begin');
      await client.query(sql);
      await client.query('insert into schema_migrations (name) values ($1)', [migration.name]);
      await client.query('commit');
      console.log(`applied ${migration.name}`);
    } catch (error) {
      await client.query('rollback');
      throw error;
    } finally {
      client.release();
    }
  }
}

async function down(pool: Pool): Promise<void> {
  await ensureLedger(pool);
  const migrations = await discover();
  const known = await applied(pool);
  const last = known.at(-1);
  if (!last) return;
  const migration = migrations.find((item) => item.name === last);
  if (!migration) throw new Error(`Missing down migration for ${last}`);
  const sql = await readFile(migration.downPath, 'utf8');
  const client = await pool.connect();
  try {
    await client.query('begin');
    await client.query(sql);
    await client.query('delete from schema_migrations where name = $1', [last]);
    await client.query('commit');
    console.log(`reverted ${last}`);
  } catch (error) {
    await client.query('rollback');
    throw error;
  } finally {
    client.release();
  }
}

async function status(pool: Pool): Promise<void> {
  await ensureLedger(pool);
  const known = new Set(await applied(pool));
  for (const migration of await discover()) {
    console.log(`${known.has(migration.name) ? '[x]' : '[ ]'} ${migration.name}`);
  }
}

const command = process.argv[2] ?? 'up';
const pool = new Pool({connectionString: loadConfig().databaseUrl});
try {
  if (command === 'up') await up(pool);
  else if (command === 'down') await down(pool);
  else if (command === 'status') await status(pool);
  else throw new Error(`Unknown migration command: ${command}`);
} finally {
  await pool.end();
}
