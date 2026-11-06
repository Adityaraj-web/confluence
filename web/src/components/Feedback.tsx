export interface ToastItem {
  id: number;
  text: string;
  tone: "info" | "error";
}

export function Toasts({ items }: { items: ToastItem[] }) {
  return (
    <div className="pointer-events-none fixed bottom-24 left-24 z-10 flex flex-col gap-8" role="status" aria-live="polite">
      {items.map((t) => (
        <p
          key={t.id}
          className={`max-w-[560px] rounded-lg border bg-surface px-16 py-8 text-cap ${
            t.tone === "error" ? "border-bad text-fg" : "border-line text-muted"
          }`}
        >
          {t.text}
        </p>
      ))}
    </div>
  );
}

/** A full-width notice under the tabs: the chain is off the deploy state, or live mode was refused. */
export function Banner(props: { tone: "warn" | "info"; children: React.ReactNode; action?: { label: string; onClick: () => void } }) {
  return (
    <div
      className={`flex shrink-0 items-center gap-16 border-b px-24 py-8 text-cap ${
        props.tone === "warn" ? "border-bad/50 bg-bad/10" : "border-line bg-surface"
      }`}
    >
      <p className="min-w-0 flex-1">{props.children}</p>
      {props.action && (
        <button
          type="button"
          onClick={props.action.onClick}
          className="shrink-0 rounded-lg border border-line px-16 py-8 text-cap hover:border-muted"
        >
          {props.action.label}
        </button>
      )}
    </div>
  );
}
