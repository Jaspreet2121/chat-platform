import { ReactNode } from "react";
import { Card } from "@/components";

/** Shared placeholder for admin sections that land in later phases. */
export function ComingSoon({
  title,
  description,
  icon
}: {
  title: string;
  description: string;
  icon: ReactNode;
}) {
  return (
    <div className="mx-auto max-w-3xl animate-fade-in">
      <h2 className="mb-4 text-xl font-semibold text-fg">{title}</h2>
      <Card className="flex flex-col items-center gap-3 p-12 text-center">
        <div className="flex h-12 w-12 items-center justify-center rounded-2xl bg-elevated text-muted">
          {icon}
        </div>
        <p className="text-sm font-medium text-fg">Coming soon</p>
        <p className="max-w-sm text-sm text-muted">{description}</p>
      </Card>
    </div>
  );
}
