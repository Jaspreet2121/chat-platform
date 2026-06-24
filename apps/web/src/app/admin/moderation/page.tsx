import { ShieldAlert } from "lucide-react";
import { ComingSoon } from "../_ComingSoon";

export default function AdminModerationPage() {
  return (
    <ComingSoon
      title="Moderation"
      description="Review user reports, suspend or ban users, and remove content — backed by the dormant moderation tables."
      icon={<ShieldAlert className="h-6 w-6" aria-hidden />}
    />
  );
}
