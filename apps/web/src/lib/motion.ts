import type { Transition, Variants } from "framer-motion";

// Motion tokens — the single rhythm every framer-motion animation in the app shares (durations in
// seconds per framer's API). Transform/opacity ONLY, so nothing triggers layout/CLS. Reduced motion is
// handled globally by <MotionConfig reducedMotion="user"> (framer keeps opacity, drops transforms) plus
// the CSS prefers-reduced-motion block in globals.css.
export const DURATION = {
  fast: 0.15, // micro states
  base: 0.22, // standard entrance
  slow: 0.3 // largest reveal / staggered container budget
} as const;

// Easings: standard = Linear-style crisp; out = decelerate (entrances); in = accelerate (exits).
export const EASE = {
  standard: [0.2, 0, 0, 1] as [number, number, number, number],
  out: [0.16, 1, 0.3, 1] as [number, number, number, number],
  in: [0.4, 0, 1, 1] as [number, number, number, number]
};

// Spring for pop-from-trigger surfaces (the "+" menu). Calm, minimal overshoot.
export const SPRING: Transition = { type: "spring", stiffness: 460, damping: 32, mass: 0.9 };

// Staggered entrance for a list/section — total stays under ~300ms for a screenful (35ms/item).
export const staggerContainer: Variants = {
  hidden: {},
  show: { transition: { staggerChildren: 0.035, delayChildren: 0.02 } }
};

// A child that rises + fades in (deeper-from-below = entering, per MD hierarchy motion).
export const riseItem: Variants = {
  hidden: { opacity: 0, y: 8 },
  show: { opacity: 1, y: 0, transition: { duration: DURATION.base, ease: EASE.out } }
};

// A child that only fades (used where vertical movement would fight fixed geometry).
export const fadeItem: Variants = {
  hidden: { opacity: 0 },
  show: { opacity: 1, transition: { duration: DURATION.base, ease: EASE.out } }
};

// Popover / menu: springs open from its trigger, exits faster than it enters.
export const popMenu: Variants = {
  hidden: { opacity: 0, scale: 0.96, y: -4 },
  show: { opacity: 1, scale: 1, y: 0, transition: SPRING },
  exit: { opacity: 0, scale: 0.98, y: -2, transition: { duration: DURATION.fast, ease: EASE.in } }
};
