import React from "react";

/**
 * A titled run of settings rows with hairline dividers and no card — the
 * single-column look. Children are the ordinary `grouped` setting components.
 */
export const SimpleSection: React.FC<{
  title: string;
  children: React.ReactNode;
}> = ({ title, children }) => (
  <section className="w-full">
    <h2 className="text-xs font-semibold uppercase tracking-wide text-mid-gray px-4 mt-8 mb-1">
      {title}
    </h2>
    <div className="divide-y divide-text/10 border-y border-text/10">
      {children}
    </div>
  </section>
);
