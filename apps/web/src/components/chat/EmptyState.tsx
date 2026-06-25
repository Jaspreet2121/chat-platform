import { ReactNode } from "react";

export type EmptyStateProps = {
  icon?: ReactNode;
  title: string;
  hint?: string;
};

export function EmptyState({ icon, title, hint }: EmptyStateProps) {
  return (
    <div className="flex h-full min-h-40 flex-col items-center justify-center px-6 text-center animate-fade-in">
      {icon && (
        <div className="mb-3 flex h-14 w-14 items-center justify-center rounded-2xl bg-brand-subtle/40 text-brand-hover ring-1 ring-brand/20 shadow-glow-sm">
          {icon}
        </div>
      )}
      <p className="text-sm font-medium text-fg">{title}</p>
      {hint && <p className="mt-1 max-w-xs text-sm text-muted">{hint}</p>}
    </div>
  );
}
