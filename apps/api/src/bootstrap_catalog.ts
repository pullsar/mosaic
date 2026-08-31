import {Pool} from 'pg';
import {loadConfig} from './config.js';
import {
  applyProductionCatalog,
  verifyProductionCatalog,
} from './production_catalog.js';

const mode = process.argv[2];
if (mode !== 'apply' && mode !== 'verify') {
  console.error('Usage: bootstrap_catalog.js {apply|verify}');
  process.exit(64);
}

const pool = new Pool({connectionString: loadConfig().databaseUrl});
try {
  const status =
    mode === 'apply'
      ? await applyProductionCatalog(pool)
      : await verifyProductionCatalog(pool);
  console.log(JSON.stringify(status));
} finally {
  await pool.end();
}
