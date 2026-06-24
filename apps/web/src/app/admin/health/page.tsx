import { Activity } from "lucide-react";
import { ComingSoon } from "../_ComingSoon";

export default function AdminHealthPage() {
  return (
    <ComingSoon
      title="Health"
      description="Live service status and dependency checks (Postgres, Kafka, MinIO, and the split services)."
      icon={<Activity className="h-6 w-6" aria-hidden />}
    />
  );
}
