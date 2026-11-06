export function Placeholder({ name }: { name: string }) {
  return (
    <div className="flex h-full items-center justify-center p-24">
      <p className="text-body text-muted">{name} is built after the Swap checkpoint.</p>
    </div>
  );
}
