// Live ownership consumers compare against Windows GetTickCount64, never the
// Node process-relative performance clock. Keep the native uint64 as a string.
export function requireOwnedWindowsTick(value) {
  if (typeof value !== 'string' || !/^[0-9]{1,20}$/.test(value) ||
      BigInt(value) > 0xffffffffffffffffn)
    throw new Error('Live ownership requires a valid Windows GetTickCount64 timestamp.');
  return value;
}
