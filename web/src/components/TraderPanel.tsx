import type { Phase } from "../lib/types.ts";
import { group } from "../lib/format.ts";

export const PHASE_TEXT: Record<Phase, string> = {
  quoting: "Quoting…",
  "pool-only": "Pool-only swap…",
  confluence: "CONFLUENCE swap…",
};

export type RunView = "both" | "pool" | "split";

/** 280px trader panel: amount, presets, direction (text; the toggle is Tier 2), and the run buttons. */
export function TraderPanel(props: {
  amount: string;
  onAmount: (a: string) => void;
  presets: string[];
  free: boolean;
  valid: boolean;
  phase: Phase | null;
  onRun: (v: RunView) => void;
}) {
  const { amount, onAmount, presets, free, valid, phase, onRun } = props;
  const busy = phase !== null;
  const click = (v: RunView) => (e: React.MouseEvent<HTMLButtonElement>) => {
    e.currentTarget.blur();
    onRun(v);
  };
  return (
    <aside className="flex w-[280px] shrink-0 flex-col gap-24 border-r border-line p-24" aria-label="Trader">
      <div className="flex flex-col gap-8">
        <label htmlFor="amount" className="text-cap text-muted">
          Trader pays
        </label>
        {free ? (
          <div
            className={`flex items-baseline gap-8 rounded-lg border bg-surface px-16 py-16 ${
              valid ? "border-line focus-within:border-aqua" : "border-bad"
            }`}
          >
            <input
              id="amount"
              inputMode="decimal"
              autoComplete="off"
              spellCheck={false}
              value={amount}
              disabled={busy}
              onChange={(e) => onAmount(e.target.value.trim())}
              aria-invalid={!valid}
              className="min-w-0 flex-1 bg-transparent font-mono text-big tabular-nums outline-none"
            />
            <span className="text-cap text-muted">USDC</span>
          </div>
        ) : (
          <p className="rounded-lg border border-line bg-surface px-16 py-16 font-mono text-big tabular-nums">
            {group(amount)} <span className="text-cap text-muted">USDC</span>
          </p>
        )}
        <div className="flex gap-8">
          {presets.map((p) => (
            <button
              key={p}
              type="button"
              disabled={busy}
              aria-pressed={p === amount}
              onClick={(e) => {
                e.currentTarget.blur();
                onAmount(p);
              }}
              className={`h-40 flex-1 rounded-lg border font-mono text-cap tabular-nums transition-colors disabled:opacity-50 ${
                p === amount ? "border-aqua text-fg" : "border-line text-muted hover:border-muted hover:text-fg"
              }`}
            >
              {group(p)}
            </button>
          ))}
        </div>
      </div>

      <div className="flex items-baseline justify-between">
        <span className="text-cap text-muted">Direction</span>
        <span className="text-body">USDC → MUMB</span>
      </div>

      <div className="flex flex-col gap-8">
        <button
          type="button"
          disabled={busy || !valid}
          onClick={click("both")}
          className="h-48 rounded-lg bg-aqua text-body font-semibold text-bg transition-opacity hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {phase ? PHASE_TEXT[phase] : "Run both"}
        </button>
        <div className="flex justify-between">
          <button
            type="button"
            disabled={busy || !valid}
            onClick={click("pool")}
            className="h-40 px-8 text-body text-muted transition-colors hover:text-fg disabled:cursor-not-allowed disabled:opacity-50"
          >
            Pool only
          </button>
          <button
            type="button"
            disabled={busy || !valid}
            onClick={click("split")}
            className="h-40 px-8 text-body text-muted transition-colors hover:text-fg disabled:cursor-not-allowed disabled:opacity-50"
          >
            CONFLUENCE
          </button>
        </div>
      </div>

      <p className="mt-auto text-cap text-muted">
        <span className="font-mono">Space</span> runs · <span className="font-mono">1</span>–<span className="font-mono">3</span> screens
      </p>
    </aside>
  );
}
