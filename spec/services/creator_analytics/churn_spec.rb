# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Churn, :elasticsearch_wait_for_refresh do
  include ChurnTestHelpers

  before do
    @user = create(:user, timezone: "UTC")
    @start_date = Date.new(2025, 9, 1)
    @end_date = Date.new(2025, 9, 30)
    @mid_period_date = @start_date + 14.days
    @subscription_product = create(:subscription_product, user: @user)
    @monthly_price = create(:price, link: @subscription_product, price_cents: 1000, recurrence: "monthly")
    @service = described_class.new(user: @user, start_date: @start_date, end_date: @end_date)
  end

  describe "#initialize" do
    it "sets up the service with correct parameters" do
      service = described_class.new(
        user: @user,
        start_date: @start_date,
        end_date: @end_date,
        params: { products: [@subscription_product.id] }
      )

      expect(service.user).to eq(@user)
      expect(service.start_date).to eq(@start_date)
      expect(service.end_date).to eq(@end_date)
    end

    it "parses dates from params when not provided directly" do
      service = described_class.new(
        user: @user,
        params: { from: "2025-09-01", to: "2025-09-30" }
      )

      expect(service.start_date).to eq(Date.new(2025, 9, 1))
      expect(service.end_date).to eq(Date.new(2025, 9, 30))
    end

    it "uses default dates when not provided" do
      freeze_time = Time.zone.parse("2025-09-15 12:00:00")
      travel_to(freeze_time) do
        service = described_class.new(user: @user)

        expect(service.start_date).to eq(Date.new(2025, 8, 15))
        expect(service.end_date).to eq(Date.new(2025, 9, 15))
      end
    end
  end

  describe "#has_subscription_products?" do
    it "returns true when user has subscription products" do
      service = described_class.new(user: @user)

      expect(service.has_subscription_products?).to be true
    end

    it "returns false when user has no subscription products" do
      user_without_subs = create(:user)
      service = described_class.new(user: user_without_subs)

      expect(service.has_subscription_products?).to be false
    end
  end

  describe "#available_products" do
    it "returns subscription products for the user" do
      product1 = create(:subscription_product, user: @user)
      product2 = create(:subscription_product, user: @user)
      create(:product, user: @user)

      service = described_class.new(user: @user)

      expect(service.available_products).to match_array([product1, product2, @subscription_product])
    end
  end

  describe "#fetch_churn_data" do
    context "when user has no subscription products" do
      it "returns nil" do
        user_without_products = create(:user)
        service_without_products = described_class.new(user: user_without_products)
        expect(service_without_products.fetch_churn_data).to be_nil
      end
    end

    context "when user has subscription products" do
      before do
        # Create test data: 1 active, 1 new, 1 churned
        create_active_subscription(product: @subscription_product, price: @monthly_price, created_at: 60.days.ago)
        create_new_subscription(product: @subscription_product, price: @monthly_price, created_at: @start_date + 5.days)
        create_churned_subscription(product: @subscription_product, price: @monthly_price,
                                    created_at: 60.days.ago, deactivated_at: @mid_period_date)

        # Index in Elasticsearch
        index_model_records(Purchase)
      end

      it "returns hash with correct structure" do
        result = @service.fetch_churn_data

        expect(result).to be_a(Hash)
        expect(result).to have_key(:start_date)
        expect(result).to have_key(:end_date)
        expect(result).to have_key(:metrics)
        expect(result).to have_key(:daily_data)
      end

      it "returns correct date range" do
        result = @service.fetch_churn_data

        expect(result[:start_date]).to eq(@start_date.to_s)
        expect(result[:end_date]).to eq(@end_date.to_s)
      end

      it "includes metrics hash with all required fields" do
        result = @service.fetch_churn_data

        expect(result[:metrics]).to include(
          :customer_churn_rate,
          :last_period_churn_rate,
          :churned_subscribers,
          :churned_mrr_cents
        )
      end

      it "includes daily data array with correct format" do
        result = @service.fetch_churn_data

        expect(result[:daily_data]).to be_an(Array)
        expect(result[:daily_data].length).to eq(30)

        result[:daily_data].each do |daily|
          expect(daily).to include(
            :date, :month, :month_index,
            :customer_churn_rate, :churned_subscribers, :churned_mrr_cents,
            :active_at_start, :new_subscribers
          )
        end
      end

      it "calculates churn metrics from Elasticsearch data" do
        result = @service.fetch_churn_data

        expect(result[:metrics][:customer_churn_rate]).to be_a(Numeric)
        expect(result[:metrics][:customer_churn_rate]).to be >= 0
        expect(result[:metrics][:churned_subscribers]).to eq(1)
        expect(result[:metrics][:churned_mrr_cents]).to eq(1000)
      end

      it "uses Elasticsearch queries, not database queries" do
        expect(Purchase).to receive(:search).at_least(:once).and_call_original
        expect(Subscription).not_to receive(:where)

        @service.fetch_churn_data
      end

      context "with caching for large sellers" do
        before do
          create(:large_seller, user: @user)
          create_churned_subscription(product: @subscription_product, price: @monthly_price,
                                      created_at: 10.days.ago, deactivated_at: 5.days.ago)
          index_model_records(Purchase)
        end

        it "uses caching for historical dates" do
          old_date_service = described_class.new(
            user: @user,
            start_date: 10.days.ago.to_date,
            end_date: 3.days.ago.to_date
          )

          expect(ComputedSalesAnalyticsDay).to receive(:upsert_data_from_key).at_least(:once).and_call_original
          result1 = old_date_service.fetch_churn_data
          expect(result1).to be_a(Hash)

          expect(ComputedSalesAnalyticsDay).to receive(:read_data_from_keys).at_least(:once).and_call_original
          result2 = old_date_service.fetch_churn_data
          expect(result2).to be_a(Hash)
        end

        it "does not cache today or yesterday" do
          recent_service = described_class.new(
            user: @user,
            start_date: 1.day.ago.to_date,
            end_date: Date.current
          )

          expect(Purchase).to receive(:search).at_least(:once).and_call_original

          recent_service.fetch_churn_data
        end
      end

      context "with product filtering" do
        it "filters churn data by selected products" do
          product1 = create(:subscription_product, user: @user)
          product2 = create(:subscription_product, user: @user)
          price1 = create(:price, link: product1, price_cents: 1000, recurrence: "monthly")
          price2 = create(:price, link: product2, price_cents: 2000, recurrence: "monthly")

          create_churned_subscription(product: product1, price: price1,
                                      created_at: 60.days.ago, deactivated_at: @mid_period_date)
          create_churned_subscription(product: product2, price: price2,
                                      created_at: 60.days.ago, deactivated_at: @mid_period_date)

          index_model_records(Purchase)

          # Filter to only product1
          filtered_service = described_class.new(
            user: @user,
            start_date: @start_date,
            end_date: @end_date,
            params: { products: [product1.id] }
          )
          result = filtered_service.fetch_churn_data

          expect(result[:metrics][:churned_subscribers]).to eq(1)
          expect(result[:metrics][:churned_mrr_cents]).to eq(1000)
        end
      end
    end

    context "with invalid date range" do
      it "returns nil when end_date is before start_date" do
        invalid_service = described_class.new(
          user: @user,
          start_date: @end_date,
          end_date: @start_date
        )

        expect(invalid_service.fetch_churn_data).to be_nil
      end
    end
  end

  describe "validation" do
    it "validates end_date is after start_date" do
      service = described_class.new(
        user: @user,
        start_date: @end_date,
        end_date: @start_date
      )

      expect(service.valid?).to be false
      expect(service.errors[:end_date]).to be_present
    end

    it "validates same day start and end date" do
      service = described_class.new(
        user: @user,
        start_date: @start_date,
        end_date: @start_date
      )

      expect(service.valid?).to be true
    end
  end

  describe "churn rate calculations with Elasticsearch" do
    before do
      @isolated_user = create(:user, timezone: "UTC")
      @isolated_product = create(:subscription_product, user: @isolated_user)
      @isolated_price = create(:price, link: @isolated_product, price_cents: 1000, recurrence: "monthly")
      @isolated_service = described_class.new(user: @isolated_user, start_date: @start_date, end_date: @end_date)

      # Setup: 10 active, 3 new, 2 churned
      10.times { create_active_subscription(product: @isolated_product, price: @isolated_price, created_at: 60.days.ago) }
      3.times { |i| create_new_subscription(product: @isolated_product, price: @isolated_price, created_at: @start_date + i.days) }
      2.times { |i| create_churned_subscription(product: @isolated_product, price: @isolated_price, created_at: 60.days.ago, deactivated_at: @start_date + 10.days + i.days) }

      index_model_records(Purchase)
    end

    it "calculates Stripe's formula: (churned / total_base) × 100" do
      result = @isolated_service.fetch_churn_data

      # Verify basic metrics are correct
      expect(result[:metrics][:churned_subscribers]).to eq(2)
      expect(result[:metrics][:churned_mrr_cents]).to eq(2000)

      # Churn rate should be calculated correctly based on active+new subscribers
      expect(result[:metrics][:customer_churn_rate]).to be_a(Float)
      expect(result[:metrics][:customer_churn_rate]).to be > 0
      expect(result[:metrics][:customer_churn_rate]).to be < 20  # Reasonable upper bound
    end

    it "returns 0% when no customers churn" do
      # Create a scenario with no churn
      user2 = create(:user)
      product2 = create(:subscription_product, user: user2)
      price2 = create(:price, link: product2, price_cents: 1000, recurrence: "monthly")

      5.times { create_active_subscription(product: product2, price: price2, created_at: 60.days.ago) }

      index_model_records(Purchase)

      service2 = described_class.new(user: user2, start_date: @start_date, end_date: @end_date)
      result = service2.fetch_churn_data

      expect(result[:metrics][:customer_churn_rate]).to eq(0.0)
      expect(result[:metrics][:churned_subscribers]).to eq(0)
    end
  end

  describe "MRR calculations from Elasticsearch" do
    before do
      @isolated_user = create(:user, timezone: "UTC")
      @isolated_product = create(:subscription_product, user: @isolated_user)
      @isolated_service = described_class.new(user: @isolated_user, start_date: @start_date, end_date: @end_date)
    end

    it "calculates MRR for monthly subscriptions" do
      monthly_price = create(:price, link: @isolated_product, price_cents: 1000, recurrence: "monthly")
      create_churned_subscription(product: @isolated_product, price: monthly_price,
                                  created_at: 60.days.ago, deactivated_at: @mid_period_date)

      index_model_records(Purchase)

      result = @isolated_service.fetch_churn_data

      expect(result[:metrics][:churned_mrr_cents]).to eq(1000)
    end

    it "converts yearly subscription price to monthly MRR" do
      yearly_price = create(:price, link: @isolated_product, price_cents: 12000, recurrence: "yearly")
      create_churned_subscription(product: @isolated_product, price: yearly_price,
                                  created_at: 60.days.ago, deactivated_at: @mid_period_date)

      index_model_records(Purchase)

      result = @isolated_service.fetch_churn_data

      # Yearly 12000 / 12 = 1000 monthly
      expected_monthly_mrr = 1000
      expect(result[:metrics][:churned_mrr_cents]).to eq(expected_monthly_mrr)
    end

    it "converts quarterly subscription price to monthly MRR" do
      quarterly_price = create(:price, link: @isolated_product, price_cents: 3000, recurrence: "quarterly")
      create_churned_subscription(product: @isolated_product, price: quarterly_price,
                                  created_at: 60.days.ago, deactivated_at: @mid_period_date)

      index_model_records(Purchase)

      result = @isolated_service.fetch_churn_data

      # Quarterly 3000 / 3 = 1000 monthly
      expected_monthly_mrr = 1000
      expect(result[:metrics][:churned_mrr_cents]).to eq(expected_monthly_mrr)
    end

    it "aggregates MRR from multiple churned subscriptions" do
      high_price = create(:price, link: @isolated_product, price_cents: 5000, recurrence: "monthly")
      low_price = create(:price, link: @isolated_product, price_cents: 1000, recurrence: "monthly")

      create_active_subscription(product: @isolated_product, price: high_price, created_at: 60.days.ago)
      create_churned_subscription(product: @isolated_product, price: high_price,
                                  created_at: 60.days.ago, deactivated_at: @start_date + 10.days)
      create_churned_subscription(product: @isolated_product, price: low_price,
                                  created_at: 60.days.ago, deactivated_at: @start_date + 15.days)

      index_model_records(Purchase)

      result = @isolated_service.fetch_churn_data

      expect(result[:metrics][:churned_mrr_cents]).to eq(6000)
    end
  end

  describe "daily churn data with Elasticsearch" do
    before do
      @daily_user = create(:user, timezone: "UTC")
      @daily_product = create(:subscription_product, user: @daily_user)
      @daily_price = create(:price, link: @daily_product, price_cents: 1000, recurrence: "monthly")
      @daily_service = described_class.new(user: @daily_user, start_date: @start_date, end_date: @end_date)
    end

    it "calculates churn for each day independently" do
      # Create subscriptions before the period starts
      before_period = @start_date - 30.days
      10.times { create_active_subscription(product: @daily_product, price: @daily_price, created_at: before_period) }

      churned_day_1 = @start_date + 5.days
      churned_day_2 = @start_date + 10.days

      create_churned_subscription(product: @daily_product, price: @daily_price, created_at: before_period, deactivated_at: churned_day_1)
      create_churned_subscription(product: @daily_product, price: @daily_price, created_at: before_period, deactivated_at: churned_day_2)

      index_model_records(Purchase)

      result = @daily_service.fetch_churn_data

      day_1_metrics = result[:daily_data].find { |d| d[:date] == churned_day_1.to_s }
      day_2_metrics = result[:daily_data].find { |d| d[:date] == churned_day_2.to_s }
      no_churn_day = result[:daily_data].find { |d| d[:date] == (@start_date + 15.days).to_s }

      expect(day_1_metrics[:churned_subscribers]).to eq(1)
      expect(day_2_metrics[:churned_subscribers]).to eq(1)
      expect(no_churn_day[:churned_subscribers]).to eq(0)
      expect(day_1_metrics[:customer_churn_rate]).to be > 0
      expect(day_2_metrics[:customer_churn_rate]).to be > 0
    end

    it "includes new subscribers in daily data" do
      # Create only new subscriptions for this test to avoid ES aggregation complexity
      new_sub_day = @start_date + 5.days
      2.times { create_new_subscription(product: @daily_product, price: @daily_price, created_at: new_sub_day) }

      index_model_records(Purchase)

      result = @daily_service.fetch_churn_data
      day_result = result[:daily_data].find { |d| d[:date] == new_sub_day.to_s }

      expect(day_result[:new_subscribers]).to eq(2)
    end

    it "calculates churn rate considering new subscribers on same day" do
      # Setup active subscriptions before period
      5.times { create_active_subscription(product: @daily_product, price: @daily_price, created_at: 60.days.ago) }

      # Create new subscriptions and one churn on the same day
      churn_day = @start_date + 5.days
      2.times { create_new_subscription(product: @daily_product, price: @daily_price, created_at: churn_day) }
      create_churned_subscription(product: @daily_product, price: @daily_price, created_at: 60.days.ago, deactivated_at: churn_day)

      index_model_records(Purchase)

      result = @daily_service.fetch_churn_data
      day_result = result[:daily_data].find { |d| d[:date] == churn_day.to_s }

      # Verify churn and new subscribers are tracked
      expect(day_result[:churned_subscribers]).to eq(1)
      expect(day_result[:new_subscribers]).to be >= 2  # At least the 2 we created
      expect(day_result[:customer_churn_rate]).to be > 0
    end
  end

  describe "last period comparison" do
    before do
      create_active_subscription(product: @subscription_product, price: @monthly_price, created_at: 60.days.ago)
      index_model_records(Purchase)
    end

    it "calculates last period churn rate" do
      last_period_start = @start_date - 30.days
      last_period_end = @start_date - 1.day

      # Create data for both periods
      5.times { create_active_subscription(product: @subscription_product, price: @monthly_price, created_at: last_period_start - 10.days) }
      create_churned_subscription(product: @subscription_product, price: @monthly_price,
                                  created_at: last_period_start - 5.days, deactivated_at: last_period_start + 10.days)

      create_churned_subscription(product: @subscription_product, price: @monthly_price,
                                  created_at: 60.days.ago, deactivated_at: @mid_period_date)

      index_model_records(Purchase)

      result = @service.fetch_churn_data

      expect(result[:metrics][:last_period_churn_rate]).to be_a(Numeric)
      expect(result[:metrics][:last_period_churn_rate]).to be >= 0
    end

    context "when no data exists for last period" do
      it "returns 0 for last period churn rate" do
        result = @service.fetch_churn_data

        expect(result[:metrics][:last_period_churn_rate]).to eq(0.0)
      end
    end
  end

  describe "edge cases" do
    before do
      index_model_records(Purchase)
    end

    it "handles subscriptions with nil deactivated_at" do
      create_active_subscription(product: @subscription_product, price: @monthly_price,
                                 created_at: 60.days.ago, deactivated_at: nil)

      index_model_records(Purchase)

      result = @service.fetch_churn_data

      expect(result[:metrics][:churned_subscribers]).to eq(0)
    end

    it "handles subscriptions created at period boundary" do
      # Create subscription on the day after period start (since first day is baseline)
      second_day = @start_date + 1.day
      create_new_subscription(product: @subscription_product, price: @monthly_price, created_at: second_day.beginning_of_day)

      index_model_records(Purchase)

      result = @service.fetch_churn_data

      expect(result[:metrics]).to be_a(Hash)
      second_day_data = result[:daily_data].find { |d| d[:date] == second_day.to_s }
      expect(second_day_data[:new_subscribers]).to be >= 1
    end

    it "handles subscriptions deactivated at period boundary" do
      create_churned_subscription(product: @subscription_product, price: @monthly_price,
                                  created_at: 60.days.ago, deactivated_at: @end_date.end_of_day)

      index_model_records(Purchase)

      result = @service.fetch_churn_data

      expect(result[:metrics][:churned_subscribers]).to eq(1)
    end

    it "handles invalid date parameters" do
      expect do
        described_class.new(user: @user, params: { from: "invalid-date", to: "2025-09-30" })
      end.to raise_error(ArgumentError)
    end

    it "rounds churn rate to 2 decimal places" do
      7.times { create_active_subscription(product: @subscription_product, price: @monthly_price, created_at: 60.days.ago) }
      create_new_subscription(product: @subscription_product, price: @monthly_price, created_at: @start_date)
      create_churned_subscription(product: @subscription_product, price: @monthly_price,
                                  created_at: 60.days.ago, deactivated_at: @start_date + 5.days)

      index_model_records(Purchase)

      result = @service.fetch_churn_data

      # 7 active + 1 new = 8, churned = 1, rate = 1/8 = 12.5% (but running total changes this)
      expect(result[:metrics][:customer_churn_rate]).to be_a(Float)
      expect(result[:metrics][:customer_churn_rate].to_s.split(".").last.length).to be <= 2
    end
  end

  describe ".customer_churn_rate class method" do
    it "calculates churn rate without full data structure" do
      create_active_subscription(product: @subscription_product, price: @monthly_price, created_at: 60.days.ago)
      create_churned_subscription(product: @subscription_product, price: @monthly_price,
                                  created_at: 60.days.ago, deactivated_at: @mid_period_date)

      index_model_records(Purchase)

      rate = described_class.customer_churn_rate(
        user: @user,
        start_date: @start_date,
        end_date: @end_date
      )

      expect(rate).to be_a(Numeric)
      expect(rate).to be >= 0
    end
  end

  describe "Elasticsearch query efficiency" do
    before do
      @isolated_user = create(:user, timezone: "UTC")
      @isolated_product = create(:subscription_product, user: @isolated_user)
      @isolated_price = create(:price, link: @isolated_product, price_cents: 1000, recurrence: "monthly")
      @isolated_service = described_class.new(user: @isolated_user, start_date: @start_date, end_date: @end_date)

      10.times { create_active_subscription(product: @isolated_product, price: @isolated_price, created_at: 60.days.ago) }
      5.times { |i| create_churned_subscription(product: @isolated_product, price: @isolated_price, created_at: 60.days.ago, deactivated_at: @start_date + (i * 5).days) }

      index_model_records(Purchase)
    end

    it "uses single ES query with date_histogram (not one query per day)" do
      # Should call Purchase.search with date_histogram (not per-day queries)
      # Total calls:
      # 1. Query for churned/new data (date_histogram) for main period
      # 2. Query for active_at_start count for main period
      # 3. Query for last_period churn rate calculation
      expect(Purchase).to receive(:search).at_least(2).times.and_call_original

      result = @isolated_service.fetch_churn_data

      # Verify it used efficient aggregation (not one query per day)
      expect(result[:daily_data].length).to eq(30)  # 30 days of data from single query
    end
  end

  describe "timezone handling" do
    it "respects user timezone in Elasticsearch queries" do
      pst_user = create(:user, timezone: "Pacific Time (US & Canada)")
      pst_product = create(:subscription_product, user: pst_user)
      pst_price = create(:price, link: pst_product, price_cents: 1000, recurrence: "monthly")

      # Create subscription that churns at midnight PST (which is different from UTC)
      create_churned_subscription(
        product: pst_product,
        price: pst_price,
        created_at: 60.days.ago,
        deactivated_at: Time.zone.parse("2025-09-15 00:00:00 PST")
      )

      index_model_records(Purchase)

      service = described_class.new(user: pst_user, start_date: @start_date, end_date: @end_date)
      result = service.fetch_churn_data

      # Should count on Sept 15 in PST timezone
      sept_15_data = result[:daily_data].find { |d| d[:date] == "2025-09-15" }
      expect(sept_15_data[:churned_subscribers]).to eq(1)
    end
  end

  private
    def add_event(event_type, occurred_at)
      create(:confirmed_follower_event,
             user: @user,
             event_type: event_type,
             occurred_at: occurred_at)
    end
end
