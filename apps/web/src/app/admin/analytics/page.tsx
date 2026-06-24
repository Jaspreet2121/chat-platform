import { BarChart3 } from "lucide-react";
import { ComingSoon } from "../_ComingSoon";

export default function AdminAnalyticsPage() {
  return (
    <ComingSoon
      title="Analytics"
      description="Total users, signups over time, messages per day, active conversations, and engagement metrics."
      icon={<BarChart3 className="h-6 w-6" aria-hidden />}
    />
  );
}
