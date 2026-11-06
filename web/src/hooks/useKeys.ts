import { useEffect, useRef } from "react";

/** Keys 1-4 switch tabs; Space runs the current tab's main action. Ignored while typing in a field. */
export function useKeys(onTab: (n: number) => void, onSpace: () => void): void {
  const tab = useRef(onTab);
  const space = useRef(onSpace);
  tab.current = onTab;
  space.current = onSpace;
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key >= "1" && e.key <= "4") {
        tab.current(Number(e.key));
      } else if (e.key === " ") {
        e.preventDefault();
        space.current();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
}
