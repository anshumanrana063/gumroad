# frozen_string_literal: true

module ChurnTestHelpers
  def create_active_subscription(product:, price:, created_at: 60.days.ago, deactivated_at: nil)
    purchaser = create(:user)

    # Create subscription using factory (creates payment_option automatically)
    subscription = create(:subscription,
                          link: product,
                          user: purchaser,
                          price: price)

    # Update subscription with test data using update! (not update_columns which may be read-only)
    subscription.deactivated_at = deactivated_at
    subscription.created_at = created_at
    subscription.updated_at = created_at
    subscription.save!(validate: false, touch: false)

    # Create a minimal purchase directly in DB, bypassing all validations and callbacks
    # This is indexed in Elasticsearch and subscription fields are pulled via association
    purchase_attrs = {
      link_id: product.id,
      subscription_id: subscription.id,
      purchaser_id: purchaser.id,
      seller_id: product.user.id,
      created_at: created_at,
      updated_at: created_at,
      succeeded_at: created_at,
      flags: 4,  # Flag 3: is_original_subscription_purchase (2^2 = 4)
      purchase_state: "subscription_purchase_successful",
      price_cents: price.price_cents,
      displayed_price_cents: price.price_cents,
      total_transaction_cents: price.price_cents,
      shipping_cents: 0,
      tax_cents: 0,
      gumroad_tax_cents: 0,
      fee_cents: 0,
      email: purchaser.email,
      stripe_fingerprint: "test_fp",
      stripe_transaction_id: "test_txn",
      card_type: "visa",
      card_visual: "****4242",
      ip_address: "127.0.0.1",
      browser_guid: SecureRandom.uuid
    }

    # Insert directly into DB to completely bypass validations/callbacks
    Purchase.insert(purchase_attrs)

    subscription
  end

  def create_churned_subscription(product:, price:, created_at:, deactivated_at:)
    create_active_subscription(
      product: product,
      price: price,
      created_at: created_at,
      deactivated_at: deactivated_at
    )
  end

  def create_new_subscription(product:, price:, created_at:)
    create_active_subscription(
      product: product,
      price: price,
      created_at: created_at
    )
  end

  # Helper for system tests to verify churn metrics
  def expect_churn_metrics(churn_rate:, last_period_rate:, revenue_lost:, churned_users:)
    within_section("Churn rate") { expect(page).to have_text("#{churn_rate}%") }
    within_section("Last period churn rate") { expect(page).to have_text("#{last_period_rate}%") }
    within_section("Revenue lost") { expect(page).to have_text("$#{revenue_lost}") }
    within_section("Churned users") { expect(page).to have_text(churned_users.to_s) }
  end

  # Setup standard test scenario with known churn data
  # Returns hash with :active, :new, and :churned subscription arrays
  def setup_churn_scenario(monthly_product:, yearly_product:, monthly_price:, yearly_price:, base_date: "2023-12-01")
    # Create 2 active subscriptions (started before period)
    active_sub1 = create_active_subscription(
      product: monthly_product,
      price: monthly_price,
      created_at: "#{base_date} 12:00:00"
    )
    active_sub2 = create_active_subscription(
      product: monthly_product,
      price: monthly_price,
      created_at: "#{base_date} 12:00:00"
    )

    # Create 1 new subscription (started during period)
    new_sub = create_new_subscription(
      product: monthly_product,
      price: monthly_price,
      created_at: "2023-12-16 12:00:00"
    )

    # Create 2 churned subscriptions (1 monthly, 1 yearly)
    churned_sub1 = create_churned_subscription(
      product: monthly_product,
      price: monthly_price,
      created_at: "#{base_date} 12:00:00",
      deactivated_at: "2023-12-20 12:00:00"
    )
    churned_sub2 = create_churned_subscription(
      product: yearly_product,
      price: yearly_price,
      created_at: "#{base_date} 12:00:00",
      deactivated_at: "2023-12-25 12:00:00"
    )

    {
      active: [active_sub1, active_sub2],
      new: [new_sub],
      churned: [churned_sub1, churned_sub2]
    }
  end
end
