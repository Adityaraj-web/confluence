import { useCallback, useEffect, useRef, useState } from "react";
import { Banner, Toasts, type ToastItem } from "./components/Feedback.tsx";
import { TopBar, type TabId } from "./components/TopBar.tsx";
import { TraderPanel, type RunView } from "./components/TraderPanel.tsx";
import { DEMO_AMOUNT } from "./lib/constants.ts";
import { loadIndex } from "./lib/runs.ts";
import { amountInRaw } from "./lib/quoter.ts";
import type { DataSource, GuardFile, Header, Phase, RunsIndex } from "./lib/types.ts";
import type { LiveSource } from "./lib/sources/live.ts";
import { useKeys } from "./hooks/useKeys.ts";
import { connect } from "./source.ts";
import { Depth } from "./screens/Depth.tsx";
import { Guard } from "./screens/Guard.tsx";
import { Swap, type SwapResult } from "./screens/Swap.tsx";

const AMOUNT_RE = /^\d+(\.\d{1,6})?$/;

export default function App() {
  const [source, setSource] = useState<DataSource | null>(null);
  const [live, setLive] = useState<LiveSource | null>(null);
  const [refused, setRefused] = useState<string | null>(null);
  const [header, setHeader] = useState<Header | null>(null);
  const [index, setIndex] = useState<RunsIndex | null>(null);
  const [tab, setTab] = useState<TabId>(1);
  const [amount, setAmount] = useState(DEMO_AMOUNT);
  const [phase, setPhase] = useState<Phase | null>(null);
  const [result, setResult] = useState<SwapResult | null>(null);
  const [guard, setGuard] = useState<GuardFile | null>(null);
  const [guardRunning, setGuardRunning] = useState(false);
  const [deployState, setDeployState] = useState<"ok" | "mismatch" | "unchecked">("unchecked");
  const [toasts, setToasts] = useState<ToastItem[]>([]);
  const toastId = useRef(0);

  const toast = useCallback((text: string, tone: ToastItem["tone"] = "info") => {
    const id = ++toastId.current;
    setToasts((t) => [...t, { id, text, tone }]);
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), tone === "error" ? 8000 : 5000);
  }, []);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const [conn, idx] = await Promise.all([connect({ onToast: (m) => toast(m), onBusy: () => {} }), loadIndex()]);
      if (cancelled) return;
      setIndex(idx);
      setRefused(conn.refused);
      setLive(conn.live);
      setSource(conn.source);
      if (conn.live) setDeployState(conn.live.deployState());
      if (conn.source) {
        try {
          const h = await conn.source.header();
          if (!cancelled) setHeader(h);
        } catch (e) {
          toast(`cannot read the pool: ${e instanceof Error ? e.message : e}`, "error");
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [toast]);

  const valid = AMOUNT_RE.test(amount) && Number(amount) > 0;
  const presets = Array.from(new Set((index?.runs ?? []).map((r) => r.amount))).sort((a, b) => Number(a) - Number(b));
  const free = source ? source.amounts("usdc-to-mumb") === "any" : false;
  const blocked = deployState === "mismatch";

  const run = useCallback(
    async (view: RunView) => {
      if (!source || phase !== null || !valid) return;
      setPhase("quoting");
      try {
        const file = await source.compare({ dir: "usdc-to-mumb", amountIn: amountInRaw(amount, "usdc-to-mumb") }, undefined, setPhase);
        setResult({ file, view });
      } catch (e) {
        toast(e instanceof Error ? e.message : String(e), "error");
      } finally {
        setPhase(null);
        if (live) setDeployState(live.deployState());
      }
    },
    [source, phase, valid, amount, live, toast],
  );

  // The guard uses the recorded guard amount (1,000 USDC), not the Swap amount: its move size was measured for it (D-23).
  const guardAmount = index?.guard.amount ?? DEMO_AMOUNT;
  const runGuard = useCallback(async () => {
    if (!source || phase !== null || guardRunning) return;
    setGuardRunning(true);
    try {
      setGuard(await source.guard(amountInRaw(guardAmount, "usdc-to-mumb")));
    } catch (e) {
      toast(e instanceof Error ? e.message : String(e), "error");
    } finally {
      setGuardRunning(false);
      if (live) setDeployState(live.deployState());
    }
  }, [source, phase, guardRunning, guardAmount, live, toast]);

  useKeys(
    (n) => {
      if (n <= 3) setTab(n as TabId);
    },
    () => {
      if (tab === 1 || tab === 2) void run("both");
      else if (tab === 3) void runGuard();
    },
  );

  return (
    <div className="flex h-full flex-col">
      <TopBar header={header} kind={source?.kind ?? null} tab={tab} onTab={setTab} />
      {blocked && (
        <Banner
          tone="warn"
          action={{
            label: "Continue anyway",
            onClick: () => {
              live?.continueAnyway();
              setDeployState("unchecked");
            },
          }}
        >
          Chain is not at the deploy state: run <code className="font-mono">pnpm --dir scripts run demo:reset</code>
        </Banner>
      )}
      {!source && refused && <Banner tone="info">Live mode is off: {refused}</Banner>}
      <main className="flex min-h-0 flex-1">
        {tab === 1 && (
          <>
            <TraderPanel
              amount={amount}
              onAmount={setAmount}
              presets={presets}
              free={free}
              valid={valid}
              phase={phase}
              locked={guardRunning || !source}
              onRun={(v) => void run(v)}
            />
            <div className="min-w-0 flex-1">
              <Swap result={result} />
            </div>
          </>
        )}
        {tab === 2 && (
          <div className="min-w-0 flex-1">
            <Depth file={result?.file ?? null} header={header} running={phase !== null || guardRunning} disabled={!source} onRun={() => void run("both")} />
          </div>
        )}
        {tab === 3 && (
          <div className="min-w-0 flex-1">
            <Guard guard={guard} running={guardRunning} locked={phase !== null || !source} onRun={() => void runGuard()} />
          </div>
        )}
      </main>
      <Toasts items={toasts} />
    </div>
  );
}
