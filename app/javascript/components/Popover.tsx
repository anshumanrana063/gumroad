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

  const hasButton = React.useMemo(() => ref.current?.querySelector("summary button") !== null, [open, trigger]);

  return (
    <Details
      className={classNames(
        "popover relative inline-block",
        "[&>summary]:grid-cols-[1fr] [&>summary]:before:content-none [&[open]>summary]:mb-0",
        className,
        {
          "after:absolute after:top-full after:left-1/2 after:z-30 after:-translate-x-1/2 after:border-r-[0.5rem] after:border-b-[0.5rem] after:border-l-[0.5rem] after:border-r-transparent after:border-b-[var(--color-parent-border)] after:border-l-transparent after:content-['']":
            open && position !== "top",
          "after:absolute after:bottom-full after:left-1/2 after:z-30 after:-translate-x-1/2 after:border-t-[0.5rem] after:border-r-[0.5rem] after:border-l-[0.5rem] after:border-t-[var(--color-parent-border)] after:border-r-transparent after:border-l-transparent after:content-['']":
            open && position === "top",
          "after:mb-1": open && position === "top" && hasButton,
        },
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
          "dropdown absolute z-30 w-max min-w-full",
          "rounded border border-border bg-background p-4",
          "max-w-[calc(100vw-2rem)] [--color:var(--contrast-filled)]",
          "[&>[role=menu]:only-child]:-m-4 [&>[role=menu]:only-child]:max-w-[calc(100%+2rem)] [&>[role=menu]:only-child]:border-0 [&>[role=menu]:only-child]:shadow-none",
          "[&>.stack:only-child]:-m-4 [&>.stack:only-child]:max-w-[calc(100%+2rem)] [&>.stack:only-child]:border-0 [&>.stack:only-child]:shadow-none",
          {
            "top-[calc(100%-0.0625rem)]": position !== "top",
            "top-auto bottom-[calc(100%+0.4375rem)]": position === "top",
            "-ml-1": hasButton,
            "mb-1": hasButton && position === "top",
            "shadow-[var(--shadow)]": position !== "top",
            "shadow-none": position === "top",
          },
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
