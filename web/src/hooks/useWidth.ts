import { useEffect, useLayoutEffect, useRef, useState } from "react";

/** The measured width of an element, so SVGs can be drawn in real pixels (text stays 14/18px at any window size). */
export function useWidth<T extends HTMLElement>(initial: number, min = 480) {
  const ref = useRef<T>(null);
  const [w, setW] = useState(initial);
  useLayoutEffect(() => {
    if (ref.current) setW(Math.max(min, Math.round(ref.current.getBoundingClientRect().width)));
  }, [min]);
  useEffect(() => {
    if (!ref.current) return;
    const ro = new ResizeObserver(([e]) => e && setW(Math.max(min, Math.round(e.contentRect.width))));
    ro.observe(ref.current);
    return () => ro.disconnect();
  }, [min]);
  return [ref, w] as const;
}
