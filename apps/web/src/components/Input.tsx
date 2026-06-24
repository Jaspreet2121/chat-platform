import { forwardRef, InputHTMLAttributes, ReactNode, useId } from "react";
import { cn } from "@/lib/cn";

export type InputProps = InputHTMLAttributes<HTMLInputElement> & {
  label?: string;
  hint?: ReactNode;
  leftIcon?: ReactNode;
};

export const Input = forwardRef<HTMLInputElement, InputProps>(function Input(
  { label, hint, leftIcon, className, id, ...props },
  ref
) {
  const generatedId = useId();
  const inputId = id ?? generatedId;

  return (
    <div className="space-y-1.5">
      {label && (
        <label htmlFor={inputId} className="block text-sm font-medium text-muted">
          {label}
        </label>
      )}
      <div className="relative">
        {leftIcon && (
          <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-faint">
            {leftIcon}
          </span>
        )}
        <input
          ref={ref}
          id={inputId}
          className={cn(
            "h-11 w-full rounded-lg border border-border bg-elevated px-3.5 text-fg placeholder:text-faint",
            "outline-none transition-colors duration-150",
            "focus:border-brand focus:ring-2 focus:ring-brand-ring",
            Boolean(leftIcon) && "pl-10",
            className
          )}
          {...props}
        />
      </div>
      {hint && <p className="text-xs text-faint">{hint}</p>}
    </div>
  );
});
