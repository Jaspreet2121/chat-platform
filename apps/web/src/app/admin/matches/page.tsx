"use client";

import { MatchesPanel } from "@/app/admin/_MatchesPanel";

export default function AdminMatchesPage() {
  return (
    <div className="mx-auto max-w-4xl animate-fade-in">
      <h2 className="text-xl font-semibold text-fg">Matches</h2>
      <p className="mb-5 text-sm text-muted">
        Dating match history, for safety, abuse and legal work. Every view is recorded with your name
        and your reason. Locations are never shown here.
      </p>
      <MatchesPanel />
    </div>
  );
}
