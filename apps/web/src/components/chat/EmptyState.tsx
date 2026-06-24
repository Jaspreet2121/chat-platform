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
        <div className="mb-3 flex h-12 w-12 items-center justify-center rounded-2xl bg-elevated text-muted">
          {icon}
        </div>
      )}
      <p className="text-sm font-medium text-fg">{title}</p>
      {hint && <p className="mt-1 max-w-xs text-sm text-muted">{hint}</p>}
    </div>
  );
}
