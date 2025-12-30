import { Link, useRouter } from "@inertiajs/react";
import React from "react";

import { useRoute } from "$app/utils/route";

type TabType = "product" | "content" | "share";

export function ProductEditInertiaLayout({ children, activeTab }: { children: React.ReactNode; activeTab: TabType }) {
  const router = useRouter();
  const props = usePage().props as any;

  const tabs = [
    { key: "product", label: "Product", route: "edit_link" },
    { key: "content", label: "Content", route: "edit_link_content" },
    { key: "share", label: "Share", route: "edit_link_share" },
  ];

  const navigateToTab = (tab: TabType) => {
    router.visit(useRoute(tabs.find((t) => t.key === tab)!.route, { id: props.id }), {
      preserveState: true,
      preserveScroll: true,
    });
  };

  return (
    <div>
      <nav>
        {tabs.map((tab) => (
          <button
            key={tab.key}
            onClick={() => navigateToTab(tab.key as TabType)}
            className={activeTab === tab.key ? "active" : ""}
            type="button"
          >
            {tab.label}
          </button>
        ))}
      </nav>
      {children}
    </div>
  );
}
