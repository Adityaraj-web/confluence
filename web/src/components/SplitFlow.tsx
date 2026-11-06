import { useEffect, useLayoutEffect, useRef, useState } from "react";

export interface FlowData {
  usdcIn: string; // formatted, e.g. "1,000"
  aquaIn: string;
  poolIn: string;
  out: string; // formatted MUMB out, 3 decimals
  aquaShare: number; // 0..1, the thickness ratio
  /** The Aqua leg did not happen (hook skipped it). */
  aquaSkipped: boolean;
}

// Geometry (px). The streams are stacked at both ends (Aqua on top) and run in separate lanes in the middle.
// Thickness is proportional to the USDC amounts: the full stack is T tall.
const H = 232;
const T = 64;
const STACK_TOP = H / 2 - T / 2; // 84
const AQUA_LANE = 56;
const POOL_LANE = 176;
const LEFT_LABEL = 136; // room for "2,000 USDC" at 18px
const OUT_LABEL = 176; // room for "1,972.318 MUMB" at 18px
const FLAT = 16;

function ribbon(xa: number, xb: number, t: number, laneC: number, stackTop: number): string {
  // A closed path: top edge left to right, bottom edge right to left. Stack at xa..xa+FLAT, lane in the middle, stack again at the right.
  const sTop = stackTop;
  const sBot = stackTop + t;
  const lTop = laneC - t / 2;
  const lBot = laneC + t / 2;
  const cl = (xb - xa - 2 * FLAT) * 0.4; // curve length each side
  const x1 = xa + FLAT;
  const x2 = x1 + cl;
  const x3 = xb - FLAT - cl;
  const x4 = xb - FLAT;
  const m1 = (x1 + x2) / 2;
  const m2 = (x3 + x4) / 2;
  return [
    `M ${xa} ${sTop}`,
    `L ${x1} ${sTop}`,
    `C ${m1} ${sTop} ${m1} ${lTop} ${x2} ${lTop}`,
    `L ${x3} ${lTop}`,
    `C ${m2} ${lTop} ${m2} ${sTop} ${x4} ${sTop}`,
    `L ${xb} ${sTop}`,
    `L ${xb} ${sBot}`,
    `L ${x4} ${sBot}`,
    `C ${m2} ${sBot} ${m2} ${lBot} ${x3} ${lBot}`,
    `L ${x2} ${lBot}`,
    `C ${m1} ${lBot} ${m1} ${sBot} ${x1} ${sBot}`,
    `L ${xa} ${sBot}`,
    "Z",
  ].join(" ");
}

export function SplitFlow({ data }: { data: FlowData | null }) {
  const box = useRef<HTMLDivElement>(null);
  const [w, setW] = useState(952);
  useLayoutEffect(() => {
    if (box.current) setW(Math.max(640, Math.round(box.current.getBoundingClientRect().width)));
  }, []);
  useEffect(() => {
    if (!box.current) return;
    const ro = new ResizeObserver(([e]) => e && setW(Math.max(640, Math.round(e.contentRect.width))));
    ro.observe(box.current);
    return () => ro.disconnect();
  }, []);

  const idle = data === null;
  const share = idle ? 0.5 : data.aquaShare;
  let ta = T * share;
  let tp = T - ta;
  if (!idle && share > 0 && ta < 3) {
    ta = 3;
    tp = T - 3;
  }
  if (!idle && share < 1 && tp < 3) {
    tp = 3;
    ta = T - 3;
  }
  const xa = LEFT_LABEL;
  const xb = w - OUT_LABEL;
  const mid = (xa + xb) / 2;
  const opacity = idle ? 0.16 : 0.92;

  const desc = idle
    ? "Split flow, idle: the swap divides between Priya's Aqua strategy and the v4 pool curve and merges into the MUMB out."
    : `${data.usdcIn} USDC splits into ${data.aquaIn} USDC to Priya's Aqua strategy and ${data.poolIn} USDC to the v4 pool curve, and merges into ${data.out} MUMB.`;

  return (
    <div ref={box} className="w-full">
      <svg width={w} height={H} role="img" aria-label={desc} className="block overflow-visible">
        {(idle || ta > 0) && (
          <path d={ribbon(xa, xb, ta, AQUA_LANE, STACK_TOP)} fill="var(--aqua)" opacity={opacity} />
        )}
        {(idle || tp > 0) && (
          <path d={ribbon(xa, xb, tp, POOL_LANE, STACK_TOP + ta)} fill="var(--pool)" opacity={opacity} />
        )}

        {/* ends: same size as the lane labels (18px) */}
        {idle ? (
          <>
            <text x={0} y={H / 2 + 6} className="fill-muted text-body" opacity={0.5}>
              USDC
            </text>
            <text x={xb + 16} y={H / 2 + 6} className="fill-muted text-body" opacity={0.5}>
              MUMB
            </text>
            <text x={mid} y={H / 2 + 6} textAnchor="middle" className="fill-muted text-body">
              Press Space or Run both
            </text>
          </>
        ) : (
          <>
            <text x={0} y={H / 2 + 6} className="fill-fg text-body tabular-nums">
              {data.usdcIn} USDC
            </text>
            <text x={xb + 16} y={H / 2 + 6} className="fill-fg text-body tabular-nums">
              {data.out}
              <tspan className="fill-muted" dx="8">
                MUMB
              </tspan>
            </text>
          </>
        )}

        {/* lane labels: colour plus words, never colour alone */}
        <text x={mid} y={AQUA_LANE - ta / 2 - 12} textAnchor="middle" className="text-body tabular-nums" fill="var(--aqua)" opacity={idle ? 0.5 : 1}>
          {idle ? "Priya's Aqua strategy" : data.aquaSkipped ? `0 USDC → Priya's Aqua strategy (skipped)` : `${data.aquaIn} USDC → Priya's Aqua strategy`}
        </text>
        <text x={mid} y={POOL_LANE + tp / 2 + 28} textAnchor="middle" className="text-body tabular-nums" fill="var(--pool)" opacity={idle ? 0.5 : 1}>
          {idle ? "v4 pool curve" : `${data.poolIn} USDC → v4 pool curve`}
        </text>
      </svg>
    </div>
  );
}
