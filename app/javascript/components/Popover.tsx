import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Details } from "$app/components/Details";
import { useGlobalEventListener } from "$app/components/useGlobalEventListener";
import { useOnOutsideClick } from "$app/components/useOnOutsideClick";

export type Props = {
  trigger: React.ReactNode;
  children: React.ReactNode | ((close: () => void) => React.ReactNode);
  className?: string;
  open?: boolean;
  onToggle?: (open: boolean) => void;
  style?: React.CSSProperties;
  position?: "top" | "bottom" | undefined;
  "aria-label"?: string;
  disabled?: boolean;
};

export const Popover = ({
  trigger,
  children,
  className,
  open: openProp,
  onToggle,
  style,
  position,
  "aria-label": ariaLabel,
  disabled,
}: Props) => {
  const [open, setOpen] = React.useState(openProp ?? false);
  const ref = React.useRef<HTMLElement | null>(null);

  if (openProp !== undefined && open !== openProp) setOpen(openProp);

  const toggle = (newOpen: boolean) => {
    if (openProp === undefined) setOpen(newOpen);
    if (newOpen !== open) onToggle?.(newOpen);
  };

  useOnOutsideClick([ref.current], () => toggle(false));
  useGlobalEventListener("keydown", (evt) => {
    if (evt.key === "Escape") {
      toggle(false);
    }
  });
  const dropoverPosition = useDropdownPosition(ref);
  React.useEffect(() => {
    if (!open) return;
    const focusElement = ref.current?.querySelector("[autofocus]");
    if (focusElement instanceof HTMLElement) focusElement.focus();
  }, [open]);

  const hasSummaryButton = React.useMemo(() => ref.current?.querySelector("summary button") !== null, [open, trigger]);

  return (
    <Details
      className={classNames(
        "popover relative inline-block",
        open && [
          "after:content-['']",
          "after:absolute after:top-full after:left-1/2 after:z-30 after:-translate-x-1/2",
          "after:border-r-8 after:border-b-8 after:border-l-8",
          "after:border-r-transparent after:border-b-[rgb(var(--parent-color)/var(--border-alpha))] after:border-l-transparent",
        ],
        position === "top" && "after:top-auto after:bottom-full after:border after:border-t after:border-b-0",
        hasSummaryButton && position === "top" && "after:mb-1",
        className,
      )}
      summary={trigger}
      summaryProps={{
        inert: disabled,
        "aria-label": ariaLabel,
        "aria-haspopup": true,
        "aria-expanded": open,
      }}
      open={open}
      onToggle={toggle}
      ref={(el) => (ref.current = el)}
      style={style}
    >
      <div
        className={classNames(
          "dropdown absolute top-14 z-30 w-max min-w-full rounded border border-border bg-background shadow [--color:var(--contrast-filled)]",
          hasSummaryButton && "ml-1",
          hasSummaryButton && position === "top" && "mb-1",
          position === "top" && "top-auto bottom-16 shadow-none",
          "[&>[role='menu']:only-child]:border-none [&>[role='menu']:only-child]:shadow-none",
          "[&>.stack:only-child]:border-none [&>.stack:only-child]:shadow-none",
        )}
        style={dropoverPosition}
      >
        {children instanceof Function ? children(() => toggle(false)) : children}
      </div>
    </Details>
  );
};

export const useDropdownPosition = (ref: React.RefObject<HTMLElement>) => {
  const [space, setSpace] = React.useState(0);
  const [maxWidth, setMaxWidth] = React.useState(0);
  React.useEffect(() => {
    const calculateSpace = () => {
      if (!ref.current?.parentElement) return;
      let scrollContainer = ref.current.parentElement;
      while (getComputedStyle(scrollContainer).overflow === "visible" && scrollContainer.parentElement !== null) {
        scrollContainer = scrollContainer.parentElement;
      }
      setSpace(
        scrollContainer.clientWidth -
          (ref.current.getBoundingClientRect().left - scrollContainer.getBoundingClientRect().left),
      );
      setMaxWidth(scrollContainer.clientWidth);
    };
    calculateSpace();
    window.addEventListener("resize", calculateSpace);

    return () => window.removeEventListener("resize", calculateSpace);
  });

  return {
    translate: `min(${space}px - 100% - var(--spacer-4), 0px)`,
    maxWidth: `calc(${maxWidth}px - 2 * var(--spacer-4))`,
  };
};
