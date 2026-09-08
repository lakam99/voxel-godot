// Synthetic filesystem fault injection for watchdog CLI regression tests only.
// This preload is never loaded by production runners or the harmless child.
import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';

const target = process.env.OWNED_TEST_SUMMARY;
const marker = process.env.OWNED_TEST_FAULT_MARKER;
const mode = process.env.OWNED_TEST_FAULT;
let injected = false;
const link = fs.linkSync, unlink = fs.unlinkSync;
function inject(message) {
  injected = true;
  fs.writeFileSync(marker, mode);
  throw new Error(message);
}
fs.linkSync = function (source, destination) {
  if (!injected && mode === 'publication' && destination === target)
    inject('synthetic transient publication failure');
  return link(source, destination);
};
fs.unlinkSync = function (file) {
  if (!injected && mode === 'scratch' && String(file).startsWith(target + '.') &&
      String(file).endsWith('.tmp') && fs.existsSync(target))
    inject('synthetic temporary-file cleanup failure');
  return unlink(file);
};
syncBuiltinESMExports();
