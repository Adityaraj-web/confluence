import { Check } from "../components/Check.tsx";
import { group, hundredthsText, moveHundredths, percent, priceMovePercent, roundTo, signedRound } from "../lib/format.ts";
import type { Header, RunFile } from "../lib/types.ts";

const DASH = "—";

function Chip({ children }: { children: React.ReactNode }) {
  return <span className="rounded-lg border border-line bg-surface px-16 py-8 text-body whitespace-nowrap">{children}</span>;
}

/** Priya's program as shipped to Aqua: every value from the header (feeE9, bandBps), in the order the program runs. */
function Program({ header }: { header: Header | null }) {
  if (!header) return <div className="h-40" />;
  const fee = `${(header.pool.feeE9 / 10_000_000).toFixed(2)}%`;
  return (
    <div className="flex items-center gap-16" aria-label="Priya's program">
      <Chip>Fee {fee}</Chip>
      <span className="text-muted" aria-hidden="true">→</span>
      <Chip>XYC curve</Chip>
      <span className="text-muted" aria-hidden="true">→</span>
      <Chip>Extruction: PoolPriceBand ±{header.pool.bandBps} bps</Chip>
    </div>
  );
}

type Row = { label: string; before: bigint | null; after: bigint | null; decimals: number; dp: number };

function BalanceTable({ rows }: { rows: Row[] }) {
  return (
    <div className="grid grid-cols-[112px_1fr_24px_1fr_104px] items-baseline gap-x-8">
      <span />
      <span className="h-32 text-right text-cap text-muted">before</span>
      <span />
      <span className="h-32 text-right text-cap text-muted">after</span>
      <span className="h-32 text-right text-cap text-muted">change</span>
      {rows.map((r) => {
        const has = r.before !== null && r.after !== null;
        return (
          <div key={r.label} className="contents">
            <span className="h-32 text-cap text-muted">{r.label}</span>
            <span className="h-32 text-right font-mono text-body tabular-nums text-muted">{has ? roundTo(r.before!, r.decimals, r.dp) : DASH}</span>
            <span className="h-32 text-center text-muted" aria-hidden="true">→</span>
            <span className="h-32 text-right font-mono text-body tabular-nums">{has ? roundTo(r.after!, r.decimals, r.dp) : DASH}</span>
            <span className="h-32 text-right font-mono text-body tabular-nums">
              {has ? signedRound(r.before!, r.after!, r.decimals, r.dp) : DASH}
            </span>
          </div>
        );
      })}
    </div>
  );
}

function MoveBar(props: { label: string; value: bigint | null; max: bigint; text: string | null; tone: "quiet" | "aqua" }) {
  const w = props.value !== null && props.max > 0n ? Number((props.value * 1000n) / props.max) / 10 : 0;
  return (
    <div className="flex h-32 items-center gap-16">
      <span className="w-[88px] shrink-0 text-cap text-muted">{props.label}</span>
      <div className="h-8 flex-1 rounded-lg bg-line/50">
        <div className={`h-8 rounded-lg ${props.tone === "aqua" ? "bg-aqua" : "bg-muted"}`} style={{ width: `${w}%` }} />
      </div>
      <span className="w-[64px] shrink-0 text-right font-mono text-body tabular-nums">{props.text ?? DASH}</span>
    </div>
  );
}

export function Depth(props: { file: RunFile | null; header: Header | null; running: boolean; disabled?: boolean; onRun: () => void }) {
  const { file: f, header, running, disabled = false, onRun } = props;
  const s = f?.split ?? null;
  const p = f?.poolOnly ?? null;

  const rows: Row[] = [
    { label: "Wallet MUMB", before: s && BigInt(s.before.priyaMumb), after: s && BigInt(s.after.priyaMumb), decimals: 18, dp: 3 },
    { label: "Wallet USDC", before: s && BigInt(s.before.priyaUsdc), after: s && BigInt(s.after.priyaUsdc), decimals: 6, dp: 2 },
    { label: "Aqua MUMB", before: s && BigInt(s.before.aquaMumb), after: s && BigInt(s.after.aquaMumb), decimals: 18, dp: 3 },
    { label: "Aqua USDC", before: s && BigInt(s.before.aquaUsdc), after: s && BigInt(s.after.aquaUsdc), decimals: 6, dp: 2 },
  ];

  const fill = s?.fill ?? null;
  const walletShare = s && fill ? percent(BigInt(fill.amountOut), BigInt(s.before.priyaMumb)) : null;

  const unchanged = s && p ? p.before.liquidity === p.after.liquidity && s.before.liquidity === s.after.liquidity : null;
  const moveP = p ? moveHundredths(BigInt(p.before.sqrtPrice), BigInt(p.after.sqrtPrice)) : null;
  const moveS = s ? moveHundredths(BigInt(s.before.sqrtPrice), BigInt(s.after.sqrtPrice)) : null;
  const max = moveP !== null && moveS !== null ? (moveP > moveS ? moveP : moveS) : 0n;

  return (
    <div className="flex h-full flex-col gap-24 overflow-y-auto p-24">
      <div className="flex items-center justify-between gap-16">
        <p className="text-body text-muted">
          {f ? (
            <>
              Depth for <span className="font-mono tabular-nums text-fg">{group(fmtUsdcIn(f))}</span> USDC · the CONFLUENCE run against the pool alone
            </>
          ) : (
            "Press Space or Run both"
          )}
        </p>
        <button
          type="button"
          disabled={running || disabled}
          onClick={(e) => {
            e.currentTarget.blur();
            onRun();
          }}
          className="h-40 rounded-lg border border-line px-16 text-body text-muted transition-colors hover:border-muted hover:text-fg disabled:cursor-not-allowed disabled:opacity-50"
        >
          {running ? "Running…" : "Run both"}
        </button>
      </div>

      <Program header={header} />

      {/* Grid sum at 1280: 952 = 576 + 16 + 360. */}
      <div className="grid grid-cols-[1fr_360px] gap-16">
        <section aria-label="Priya's balances" className="rounded-lg border border-line bg-surface p-24">
          <h2 className="text-cap font-medium">Priya's balances</h2>
          <div className="mt-16">
            <BalanceTable rows={rows} />
          </div>
          <p className="mt-16 text-cap text-muted">
            {fill && s ? (
              <>
                Aqua leg: {group(roundTo(BigInt(fill.amountIn), 6, 0))} USDC in, {roundTo(BigInt(fill.amountOut), 18, 3)} MUMB out · {walletShare} of her wallet MUMB
              </>
            ) : (
              DASH
            )}
          </p>
        </section>

        <section aria-label="The pool" className="rounded-lg border border-line p-24">
          <h2 className="text-cap font-medium">The pool</h2>
          <div className="mt-16">
            <p className="text-cap text-muted">In-range liquidity</p>
            <div className="flex h-32 items-baseline justify-between">
              <span className="text-cap text-muted">before</span>
              <span className="font-mono text-body tabular-nums">{s ? group(s.before.liquidity) : DASH}</span>
            </div>
            <div className="flex h-32 items-baseline justify-between">
              <span className="text-cap text-muted">after</span>
              <span className="font-mono text-body tabular-nums">{s ? group(s.after.liquidity) : DASH}</span>
            </div>
            <p className={`flex h-32 items-center gap-8 text-body ${unchanged === false ? "text-bad" : unchanged ? "text-ok" : "text-muted"}`}>
              {unchanged ? <Check /> : null}
              {unchanged === null ? DASH : unchanged ? "Unchanged in both runs" : "Changed"}
            </p>
          </div>
          <div className="mt-16">
            <p className="text-cap text-muted">Pool price move</p>
            <MoveBar label="Pool alone" value={moveP} max={max} text={p ? priceMovePercent(BigInt(p.before.sqrtPrice), BigInt(p.after.sqrtPrice)) : null} tone="quiet" />
            <MoveBar label="CONFLUENCE" value={moveS} max={max} text={s ? hundredthsText(moveS!) : null} tone="aqua" />
          </div>
        </section>
      </div>
    </div>
  );
}

const fmtUsdcIn = (f: RunFile) => fmtMumbSafe(f.request.amountIn);
// amountIn is USDC base units (6 decimals): turn it into a decimal string without floats.
function fmtMumbSafe(units: string): string {
  const v = BigInt(units);
  const whole = v / 1_000_000n;
  const frac = (v % 1_000_000n).toString().padStart(6, "0").replace(/0+$/, "");
  return frac ? `${whole}.${frac}` : `${whole}`;
}
