import type { ProgrammerConnection } from "xgecu-web";

// A failed close still owns an SDK reference. Keep it beyond component lifetime
// and block new hardware work until the caller explicitly retries cleanup.
const pending = new Set<ProgrammerConnection>();
const closing = new Map<ProgrammerConnection, Promise<void>>();
const listeners = new Set<() => void>();

export function hasPendingProgrammerCloses(): boolean {
  return pending.size !== 0;
}

export function subscribeProgrammerCleanup(listener: () => void): () => void {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}

export function closeProgrammerConnection(
  connection: ProgrammerConnection,
  settled: Promise<unknown> = Promise.resolve(),
): Promise<void> {
  const existing = closing.get(connection);
  if (existing) return existing;
  pending.add(connection);
  const operation = settled.catch(() => undefined)
    .then(() => connection.close())
    .then(() => { pending.delete(connection); })
    .finally(() => {
      closing.delete(connection);
      for (const listener of listeners) listener();
    });
  closing.set(connection, operation);
  for (const listener of listeners) listener();
  return operation;
}

export async function retryProgrammerCloses(): Promise<void> {
  for (const connection of pending) await closeProgrammerConnection(connection);
}
