import { useForm, usePage } from "@inertiajs/react";
import React from "react";

import { ProductEditInertiaLayout } from "$app/components/ProductEdit/InertiaLayout";
import { ProductTab } from "$app/components/ProductEdit/ProductTab";

export default function Index() {
  const props = usePage().props as any;

  const form = useForm({
    product: props.product,
    currency_type: props.currency_type,
  });

  return (
    <ProductEditInertiaLayout activeTab="product">
      <ProductTab
        form={form}
        // Pass other props as needed
        {...props}
      />
    </ProductEditInertiaLayout>
  );
}
