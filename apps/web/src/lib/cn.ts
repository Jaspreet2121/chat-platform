/**
 * Tiny className joiner — filters falsy values and joins with spaces. Keeps the component
 * primitives dependency-free (no clsx/tailwind-merge needed for this app's scale).
 */
export function cn(...classes: Array<string | false | null | undefined>): string {
  return classes.filter(Boolean).join(" ");
}
