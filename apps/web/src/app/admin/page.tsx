import Link from "next/link";
import { Activity, BarChart3, CheckCircle2, ShieldAlert } from "lucide-react";
import { Card } from "@/components";

const sections = [
  {
    href: "/admin/analytics",
    label: "Analytics",
    description: "Users, conversations, messages, and engagement over time.",
    icon: BarChart3
  },
  {
    href: "/admin/moderation",
    label: "Moderation",
    description: "Review reports, suspend users, and remove content.",
    icon: ShieldAlert
  },
  {
    href: "/admin/health",
    label: "Health",
    description: "Service status and infrastructure dependencies.",
    icon: Activity
  }
];

export default function AdminDashboardPage() {
  return (
    <div className="mx-auto max-w-4xl animate-fade-in">
      <div className="mb-6 flex items-center gap-3">
        <CheckCircle2 className="h-6 w-6 text-success" aria-hidden />
        <div>
          <h2 className="text-xl font-semibold text-fg">You&apos;re an admin</h2>
          <p className="text-sm text-muted">
            The admin foundation is live. Pick a section to get started — analytics, moderation, and
            health land in the next phases.
          </p>
        </div>
      </div>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {sections.map((section) => {
          const Icon = section.icon;
          return (
            <Link key={section.href} href={section.href}>
              <Card className="h-full p-5 transition-colors hover:border-border-strong">
                <div className="mb-3 flex h-10 w-10 items-center justify-center rounded-xl bg-elevated text-brand-hover">
                  <Icon className="h-5 w-5" aria-hidden />
                </div>
                <p className="text-sm font-semibold text-fg">{section.label}</p>
                <p className="mt-1 text-sm text-muted">{section.description}</p>
              </Card>
            </Link>
          );
        })}
      </div>
    </div>
  );
}
