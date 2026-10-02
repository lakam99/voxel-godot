import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

export const activeReceiptPath = projectPath => join(projectPath, 'artifacts/vt/install/active.json');
const dllNames = ['libvoxel.windows.editor.x86_64.dll', 'libvoxel.windows.template_release.x86_64.dll'];

export async function fileSha256(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

export async function inspectPatchedInstall(projectPath) {
  let receipt;
  try {
    receipt = JSON.parse(await readFile(activeReceiptPath(projectPath), 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw new Error(`Patched Voxel Tools install receipt is unreadable: ${error.message}`);
  }
  if (receipt.schema !== 'voxel-tools-mesh-preparation-install/v1') {
    throw new Error('Patched Voxel Tools install receipt has an unknown schema');
  }
  if (receipt.status !== 'installed') return { receipt, valid: false };
  if (receipt.lockSha256 !== await fileSha256(join(projectPath, 'native/voxel_tools/mesh_preparation.lock.json'))) {
    return { receipt, valid: false };
  }
  const bin = join(projectPath, 'addons/zylann.voxel/bin');
  if (receipt.patchedOutputs?.length !== dllNames.length) return { receipt, valid: false };
  for (const name of dllNames) {
    const item = receipt.patchedOutputs.find(candidate => candidate.name === name);
    if (!item) return { receipt, valid: false };
    try {
      if (await fileSha256(join(bin, name)) !== item.sha256) return { receipt, valid: false };
    } catch (error) {
      if (error.code === 'ENOENT') return { receipt, valid: false };
      throw error;
    }
  }
  return { receipt, valid: true };
}
