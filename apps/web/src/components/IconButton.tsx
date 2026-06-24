import { ButtonHTMLAttributes, forwardRef, ReactNode } from "react";
import { cn } from "@/lib/cn";

type Variant = "ghost" | "primary" | "danger";

export type IconButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: Variant;
  /** Accessible label — required since the button is icon-only. */
  label: string;
  children: ReactNode;
};

const variants: Record<Variant, string> = {
  ghost: "text-muted hover:bg-elevated hover:text-fg",
  primary: "bg-brand text-white hover:bg-brand-hover",
  danger: "text-muted hover:bg-danger/10 hover:text-danger"
};

export const IconButton = forwardRef<HTMLButtonElement, IconButtonProps>(function IconButton(
  { variant = "ghost", label, className, children, ...props },
  ref
) {
  return (
    <button
      ref={ref}
      aria-label={label}
      title={label}
      className={cn(
        "inline-flex h-10 w-10 items-center justify-center rounded-lg transition-all duration-150",
        "outline-none focus-visible:ring-2 focus-visible:ring-brand-ring disabled:cursor-not-allowed disabled:opacity-50",
        "active:scale-[0.96]",
        variants[variant],
        className
      )}
      {...props}
    >
      {children}
    </button>
  );
});
