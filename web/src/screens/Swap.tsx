import type { RunFile, RunJson } from "../lib/types.ts";
import { avgPrice, fmtMumb, fmtUsdc, formatGain, group, priceMovePercent, roundTo } from "../lib/format.ts";
import { SplitFlow, type FlowData } from "../components/SplitFlow.tsx";
import type { RunView } from "../components/TraderPanel.tsx";

export interface SwapResult {
  file: RunFile;
  view: RunView;
}

const DASH = "—";

/** One result card. Same rows in the same order on both cards so they compare at a glance. */
function ResultCard(props: { title: string; bright: boolean; run: RunJson | null }) {
  const { title, bright, run } = props;
  const out = run ? BigInt(run.mumbOut) : null;
  const full = out === null ? null : fmtMumb(out);
  const avg = run ? avgPrice(BigInt(run.usdcIn), BigInt(run.mumbOut), 6, 18) : null;
  const move = run ? priceMovePercent(BigInt(run.before.sqrtPrice), BigInt(run.after.sqrtPrice)) : null;
  return (
    <section
      aria-label={title}
      className={
        bright
          ? "flex flex-col rounded-lg border border-line border-t-2 border-t-aqua bg-surface p-24 shadow-[0_0_40px_-8px_rgb(45_212_191/0.28)]"
          : "flex flex-col rounded-lg border border-line p-24"
      }
    >
      <div className="flex items-baseline justify-between">
        <h2 className={`text-cap font-medium ${bright ? "text-fg" : "text-muted"}`}>{title}</h2>
        <span className="text-cap text-muted">MUMB out</span>
      </div>
      <p className={`mt-8 font-mono text-hero tabular-nums ${bright ? "text-fg" : "text-muted"}`}>
        {out === null ? DASH : roundTo(out, 18, 3)}
      </p>
      <p className="mt-4 h-20 truncate font-mono text-cap tabular-nums text-muted">{full ?? ""}</p>
      <dl className="mt-16">
        <Row label="avg price" value={avg} unit="USDC per MUMB" />
        <Row label="pool price move" value={move} />
      </dl>
    </section>
  );
}

function Row({ label, value, unit }: { label: string; value: string | null; unit?: string }) {
  return (
    <div className="flex h-32 items-baseline justify-between">
      <dt className="text-cap text-muted">{label}</dt>
      <dd className="font-mono text-body tabular-nums">
        {value ?? DASH}
        {value && unit && <span className="ml-8 font-sans text-cap text-muted">{unit}</span>}
      </dd>
    </div>
  );
}

function DeltaPill({ gain }: { gain: { abs: bigint; bps: string; sign: "+" | "-" } | null }) {
  const good = gain?.sign === "+";
  const tone = gain === null ? "border-line text-muted" : good ? "border-ok/40 bg-ok/10 text-ok" : "border-bad/40 bg-bad/10 text-bad";
  return (
    <div className="flex items-center">
      <div className={`flex w-full flex-col items-center gap-4 rounded-lg border px-16 py-16 ${tone}`} aria-label="Gain against the pool alone">
        <p className="font-mono text-big tabular-nums">
          {gain ? `${gain.sign}${roundTo(gain.abs, 18, 3)}` : DASH}
          {gain && <span className="ml-8 font-sans text-body">MUMB</span>}
        </p>
        <p className="font-mono text-body tabular-nums">{gain ? `${gain.bps} bps` : "gain vs pool"}</p>
      </div>
    </div>
  );
}

export function Swap({ result }: { result: SwapResult | null }) {
  const f = result?.file ?? null;
  const view = result?.view ?? "both";
  const showPool = view !== "split";
  const showSplit = view !== "pool";

  let gain: { abs: bigint; bps: string; sign: "+" | "-" } | null = null;
  if (f && view === "both") {
    const g = formatGain(BigInt(f.poolOnly.mumbOut), BigInt(f.split.mumbOut));
    const d = BigInt(f.split.mumbOut) - BigInt(f.poolOnly.mumbOut);
    gain = { abs: d < 0n ? -d : d, bps: g.bps, sign: g.sign };
  }

  let flow: FlowData | null = null;
  if (f) {
    const run = view === "pool" ? f.poolOnly : f.split;
    const usdcIn = BigInt(run.usdcIn);
    const aquaIn = run.fill ? BigInt(run.fill.amountIn) : 0n;
    flow = {
      usdcIn: group(fmtUsdc(usdcIn)),
      aquaIn: group(fmtUsdc(aquaIn)),
      poolIn: group(fmtUsdc(usdcIn - aquaIn)),
      out: roundTo(BigInt(run.mumbOut), 18, 3),
      aquaShare: Number((aquaIn * 1_000_000n) / usdcIn) / 1e6,
      aquaSkipped: view !== "pool" && run.fill === undefined,
    };
  }

  // Grid sum at 1280: main 1000 - 2x24 padding = 952 = 356 + 16 + 208 + 16 + 356.
  return (
    <div className="flex h-full flex-col gap-24 overflow-y-auto p-24">
      <div className="grid grid-cols-[1fr_208px_1fr] gap-16">
        <ResultCard title="Pool alone" bright={false} run={showPool && f ? f.poolOnly : null} />
        <DeltaPill gain={gain} />
        <ResultCard title="CONFLUENCE" bright run={showSplit && f ? f.split : null} />
      </div>

      <div className="flex flex-col gap-8">
        <p className="h-24 text-body text-muted">
          {f ? (
            view === "pool" ? (
              "Pool-only swap: the whole amount fills against the v4 pool curve."
            ) : (
              <>
                Quoter picked <span className="font-mono tabular-nums text-fg">{(f.quote.aquaShare * 100).toFixed(2)}%</span> via Aqua
                {" · "}
                <span className="font-mono tabular-nums">{f.quote.points.length}</span> points simulated
                {f.split.skipReason ? ` · Aqua leg skipped: ${f.split.skipReason}` : ""}
              </>
            )
          ) : (
            "Press Space or Run both"
          )}
        </p>
        <SplitFlow data={flow} />
      </div>
    </div>
  );
}
