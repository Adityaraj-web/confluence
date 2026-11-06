import { Check } from "../components/Check.tsx";
import { useWidth } from "../hooks/useWidth.ts";
import { decodeBandExceeded } from "../lib/decode.ts";
import { group, hundredthsText, priceMovePercent, roundTo, signedHundredths } from "../lib/format.ts";
import type { GuardFile } from "../lib/types.ts";

const DASH = "—";
const H = 200;
const TRACK = 104;

/** What the axis draws, all derived from the raw skip reason bytes (decodeBandExceeded), never from the sentence. */
function axisFacts(g: GuardFile) {
  const band = decodeBandExceeded(g.hinted.skipped!);
  if (!band) return null;
  const fill = signedHundredths(band.exec - band.pool, band.pool); // hundredths of a percent, signed
  const bandPct = band.bandBps / 100;
  const markerPct = Number(fill) / 100;
  const range = Math.max(bandPct * 2, Math.ceil(Math.abs(markerPct) * 1.25));
  const outside = (fill < 0n ? -fill : fill) - BigInt(band.bandBps);
  return { band, fill, bandPct, markerPct, range, outside };
}

function Axis({ g }: { g: GuardFile | null }) {
  const [ref, w] = useWidth<HTMLDivElement>(904, 560);
  const facts = g ? axisFacts(g) : null;
  const padX = 40;
  const range = facts?.range ?? 4;
  const x = (pct: number) => padX + ((pct + range) / (2 * range)) * (w - 2 * padX);
  const x0 = x(0);
  const bandHalf = facts ? facts.bandPct : range / 2;
  const ticks: number[] = [];
  if (facts) for (let t = -range; t <= range + 1e-9; t += facts.bandPct) ticks.push(Math.round(t * 100) / 100);
  const tickText = (t: number) => `${t > 0 ? "+" : t < 0 ? "-" : ""}${Math.abs(t)}%`;
  const mx = facts ? x(facts.markerPct) : 0;
  const anchor = facts && mx > w - 240 ? "end" : facts && mx < 240 ? "start" : "middle"; // the longest caption is about 440px wide
  const fillText = facts ? `${facts.fill < 0n ? "-" : "+"}${hundredthsText(facts.fill)}` : "";

  return (
    <div ref={ref} className="w-full">
      <svg
        width={w}
        height={H}
        role="img"
        className="block overflow-visible"
        aria-label={
          facts
            ? `Priya's fill price is ${fillText} from the pool price, outside the plus or minus ${hundredthsText(BigInt(facts.band.bandBps))} band`
            : "Price axis: the pool price at zero with the allowed band around it"
        }
      >
        {/* the allowed band, shaded around the pool price */}
        <rect x={x(-bandHalf)} y={TRACK - 32} width={x(bandHalf) - x(-bandHalf)} height={64} rx={8} fill="var(--aqua)" opacity={facts ? 0.16 : 0.08} />
        <text x={x0} y={TRACK - 44} textAnchor="middle" className="text-cap" fill="var(--aqua)" opacity={facts ? 1 : 0.5}>
          {facts ? `±${hundredthsText(BigInt(facts.band.bandBps))} band` : "allowed band"}
        </text>

        {/* the axis */}
        <line x1={padX} x2={w - padX} y1={TRACK} y2={TRACK} stroke="var(--line)" strokeWidth={2} />
        {ticks.map((t) => (
          <g key={t}>
            <line x1={x(t)} x2={x(t)} y1={TRACK - 6} y2={TRACK + 6} stroke="var(--muted)" strokeWidth={1} />
            {t !== 0 && (
              <text x={x(t)} y={TRACK + 56} textAnchor="middle" className="text-cap tabular-nums" fill="var(--muted)">
                {tickText(t)}
              </text>
            )}
          </g>
        ))}

        {/* the pool price after the move, at 0 */}
        <line x1={x0} x2={x0} y1={TRACK - 28} y2={TRACK + 28} stroke="var(--fg)" strokeWidth={3} />
        <text x={x0} y={TRACK + 56} textAnchor="middle" className="text-cap" fill="var(--fg)">
          Pool price after the move · 0%
        </text>

        {/* Priya's fill: a red marker plus its words (never colour alone) */}
        {facts && (
          <g>
            <line x1={mx} x2={mx} y1={TRACK - 32} y2={TRACK + 32} stroke="var(--bad)" strokeWidth={4} />
            <path d={`M ${mx} ${TRACK - 44} l 8 8 h -16 z`} fill="var(--bad)" />
            <text x={mx} y={TRACK - 78} textAnchor={anchor} className="text-body tabular-nums" fill="var(--bad)">
              Priya would sell MUMB {hundredthsText(facts.fill)} {facts.fill >= 0n ? "cheaper" : "dearer"} than the pool
            </text>
            <text x={mx} y={TRACK - 56} textAnchor={anchor} className="text-cap tabular-nums" fill="var(--bad)">
              {fillText}
            </text>
            <text x={mx} y={TRACK + 80} textAnchor={anchor} className="text-cap tabular-nums" fill="var(--bad)">
              {hundredthsText(facts.outside)} beyond the ±{hundredthsText(BigInt(facts.band.bandBps))} band: refused
            </text>
          </g>
        )}
      </svg>
    </div>
  );
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex min-h-32 items-baseline justify-between gap-16">
      <dt className="text-cap text-muted">{label}</dt>
      <dd className="text-right font-mono text-body tabular-nums">{children}</dd>
    </div>
  );
}

function Result({ g }: { g: GuardFile | null }) {
  const facts = g ? axisFacts(g) : null;
  const out = g ? BigInt(g.hinted.mumbOut) : null;
  const h = g?.hinted;
  const untouched =
    h && h.before.priyaMumb === h.after.priyaMumb && h.before.priyaUsdc === h.after.priyaUsdc && h.before.aquaMumb === h.after.aquaMumb && h.before.aquaUsdc === h.after.aquaUsdc;
  const skipped = h && h.fill === undefined && h.skipped !== undefined;
  return (
    <section aria-label="Guard result" className={`grid grid-cols-[1fr_1fr] gap-24 rounded-lg border border-line border-t-2 bg-surface p-24 ${g ? "border-t-ok" : "border-t-line"}`}>
      <div>
        <h2 className={`flex items-center gap-8 text-cap font-medium ${g ? "text-ok" : "text-muted"}`}>
          {g && <Check />}
          {g ? "Swap succeeded" : "Swap"}
        </h2>
        <p className="mt-8 font-mono text-hero tabular-nums">{out === null ? DASH : roundTo(out, 18, 3)}</p>
        <p className="mt-4 text-cap text-muted">{g ? "MUMB, all from the pool alone" : "MUMB out"}</p>
        <p className="mt-4 h-20 truncate font-mono text-cap tabular-nums text-muted">{g ? `${g.hinted.mumbOut}` : ""}</p>
      </div>
      <dl className="self-center">
        <Row label="Aqua leg">
          {g ? (skipped ? (facts ? "Skipped: PoolPriceBandExceeded" : `Skipped: ${g.hinted.skipReason}`) : "Not skipped") : DASH}
        </Row>
        <Row label="Fill vs pool price">
          {facts ? `${facts.fill < 0n ? "-" : "+"}${hundredthsText(facts.fill)} (band ±${hundredthsText(BigInt(facts.band.bandBps))})` : DASH}
        </Row>
        <Row label="Pool moved">
          {g ? `${priceMovePercent(BigInt(g.move.sqrtBefore), BigInt(g.move.sqrtAfter))} by ${group(roundTo(BigInt(g.move.amountIn), 6, 0))} USDC` : DASH}
        </Row>
        <Row label="Priya's balances">
          {g ? (
            untouched ? (
              <span className="inline-flex items-center gap-8 text-ok">
                <Check />
                Untouched
              </span>
            ) : (
              <span className="text-bad">Changed</span>
            )
          ) : (
            DASH
          )}
        </Row>
      </dl>
    </section>
  );
}

export function Guard(props: { guard: GuardFile | null; running: boolean; locked: boolean; onRun: () => void }) {
  const { guard: g, running, locked, onRun } = props;
  return (
    <div className="flex h-full flex-col gap-24 overflow-y-auto p-24">
      <div className="flex items-center gap-24">
        <button
          type="button"
          disabled={running || locked}
          onClick={(e) => {
            e.currentTarget.blur();
            onRun();
          }}
          className="h-48 shrink-0 rounded-lg bg-aqua px-24 text-body font-semibold text-bg transition-opacity hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {running ? "Moving the pool…" : "Move the pool, then retry the same hint"}
        </button>
        <p className="min-w-0 text-body text-muted">
          {g
            ? `A ${group(roundTo(BigInt(g.move.amountIn), 6, 0))} USDC pool-only trade moved the pool; the hint the quoter picked before the move went to Aqua again.`
            : "Press Space or the button: a pool-only trade moves the price, then the hint quoted before the move is retried."}
        </p>
      </div>

      <section aria-label="Price axis" className="rounded-lg border border-line p-24">
        <h2 className="text-cap font-medium">
          Priya's fill price against the pool price <span className="font-normal text-muted">(MUMB per USDC)</span>
        </h2>
        <div className="mt-8">
          <Axis g={g} />
        </div>
      </section>

      <Result g={g} />
    </div>
  );
}
