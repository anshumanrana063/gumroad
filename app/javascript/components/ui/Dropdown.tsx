import * as React from "react";

import { classNames } from "$app/utils/classNames";

export const Dropdown = ({ children, className = "", ...props }: React.ComponentPropsWithoutRef<"div">) => (
  <div
    className={classNames(
      "relative mt-2 max-w-screen",
      "rounded border border-parent-border bg-background p-4",
      "before:absolute before:bottom-full before:left-3 before:content-['']",
      "before:border-l-8 before:border-l-transparent",
      "before:border-r-8 before:border-r-transparent",
      "before:border-b-8 before:border-b-parent-border",
      className,
    )}
    {...props}
  >
    {children}
  </div>
);
