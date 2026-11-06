import type { Header } from "../lib/types.ts";
import { trunc } from "../lib/format.ts";

export type TabId = 1 | 2 | 3 | 4;
const TABS: { id: TabId; label: string; enabled: boolean }[] = [
  { id: 1, label: "Swap", enabled: true },
  { id: 2, label: "Depth", enabled: true },
  { id: 3, label: "Guard", enabled: true },
  { id: 4, label: "How it works", enabled: false },
];

/** Two overlapping rings, one per stream (Aqua teal, pool amber): the product's mark. */
function Mark() {
  return (
    <svg width="32" height="32" viewBox="0 0 32 32" fill="none" aria-hidden="true">
      <circle cx="12" cy="16" r="8" stroke="var(--aqua)" strokeWidth="3" />
      <circle cx="20" cy="16" r="8" stroke="var(--pool)" strokeWidth="3" />
    </svg>
  );
}

export function TopBar(props: {
  header: Header | null;
  kind: "live" | "replay" | null;
  tab: TabId;
  onTab: (t: TabId) => void;
}) {
  const { header: h, kind, tab, onTab } = props;
  return (
    <header className="shrink-0 border-b border-line">
      <div className="flex h-64 items-center gap-24 px-24">
        <div className="flex items-center gap-8">
          <Mark />
          <span className="text-body font-semibold">CONFLUENCE</span>
        </div>
        <p className="min-w-0 flex-1 truncate text-body text-muted">
          {h ? (
            <>
              MUMB/USDC · fee {(h.pool.fee / 10_000).toFixed(2)}% · 1 MUMB ={" "}
              <span className="font-mono tabular-nums">{trunc(h.usdcPerMumb, 4)}</span> USDC · band ±
              {(h.pool.bandBps / 100).toFixed(2)}%
            </>
          ) : (
            "MUMB/USDC"
          )}
        </p>
        <Badge kind={kind} block={h?.forkBlock ?? null} />
      </div>
      <nav className="flex h-48 items-end gap-32 px-24" aria-label="Screens">
        {TABS.map((t) => {
          const active = t.id === tab;
          return (
            <button
              key={t.id}
              type="button"
              disabled={!t.enabled}
              aria-current={active ? "page" : undefined}
              onClick={(e) => {
                e.currentTarget.blur();
                onTab(t.id);
              }}
              className={`-mb-px flex h-48 items-center gap-8 border-b-2 text-body transition-colors ${
                active ? "border-aqua text-fg" : "border-transparent text-muted hover:text-fg"
              } disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:text-muted`}
            >
              <span className="font-mono text-cap text-muted">{t.id}</span>
              {t.label}
            </button>
          );
        })}
      </nav>
    </header>
  );
}

function Badge({ kind, block }: { kind: "live" | "replay" | null; block: number | null }) {
  if (!kind) return <span className="rounded-lg border border-line px-16 py-8 text-cap text-muted">No data source</span>;
  const live = kind === "live";
  return (
    <span className="flex items-center gap-8 rounded-lg border border-line px-16 py-8 text-cap">
      <span
        aria-hidden="true"
        className={`size-8 rounded-full ${live ? "bg-ok" : "border border-muted"}`}
      />
      <span className="font-medium">{live ? "LIVE" : "REPLAY"}</span>
      <span className="text-muted">
        {live ? "anvil fork " : "recorded from a mainnet fork at block "}
        <span className="font-mono tabular-nums">{block ?? "—"}</span>
      </span>
    </span>
  );
}
