import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const Dropdown = ({ children, className = "", ...props }: React.ComponentPropsWithoutRef<"div">) => (
  <div
    className={classNames(
      "relative mt-2 max-w-[calc(100vw-2*var(--spacer-4))] rounded border border-parent-border bg-background p-4 before:absolute before:bottom-full before:left-3 before:border-r-[length:var(--spacer-2)] before:border-b-[length:var(--spacer-2)] before:border-l-[length:var(--spacer-2)] before:border-r-transparent before:border-b-parent-border before:border-l-transparent before:content-['']",
      className,
    )}
    {...props}
  >
    {children}
  </div>
);
