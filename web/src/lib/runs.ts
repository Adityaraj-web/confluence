// Reads web/public/runs/index.json (written by `pnpm --dir web run record`). Used for the amount chips in both modes
// and, in replay, for everything. Returns null when the file is not there.
import type { RunsIndex } from "./types.ts";

const base = () => import.meta.env.BASE_URL;

export async function loadIndex(): Promise<RunsIndex | null> {
  try {
    const r = await fetch(`${base()}runs/index.json`, { cache: "no-store" });
    return r.ok ? ((await r.json()) as RunsIndex) : null;
  } catch {
    return null;
  }
}

export async function loadJson<T>(name: string): Promise<T> {
  const r = await fetch(`${base()}runs/${name}`, { cache: "no-store" });
  if (!r.ok) throw new Error(`cannot load ${name} (${r.status})`);
  return (await r.json()) as T;
}
