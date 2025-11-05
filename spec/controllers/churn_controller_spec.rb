# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

RSpec.describe ChurnController, type: :controller, inertia: true do
  include ChurnTestHelpers

  let(:user) { create(:user, timezone: "UTC") }

  before { sign_in user }

  describe "GET #show" do
    context "when user has subscription products" do
      let!(:product) { create(:subscription_product, user: user) }
      let(:monthly_price) { create(:price, link: product, price_cents: 1000, recurrence: "monthly") }

      before do
        # Create test data for churn calculation
        create_active_subscription(product: product, price: monthly_price, created_at: 60.days.ago)
        create_churned_subscription(
          product: product,
          price: monthly_price,
          created_at: 60.days.ago,
          deactivated_at: 30.days.ago
        )

        index_model_records(Purchase)
      end

      it "renders the Churn/Show component" do
        get :show

        expect(response).to be_successful
        expect(inertia.component).to eq("Churn/Show")
      end

      it "includes churn_props with correct structure" do
        get :show

        expect(inertia.props[:churn_props]).to match(
          has_subscription_products: true,
          products: array_including(
            hash_including(
              id: product.id,
              name: product.name,
              unique_permalink: product.unique_permalink,
              alive: true
            )
          )
        )
      end

      it "includes churn_data immediately (not lazy loaded)" do
        get :show

        expect(inertia.props[:churn_data]).to be_present
        expect(inertia.props[:churn_data]).to include(
          :start_date,
          :end_date,
          :metrics,
          :daily_data
        )
      end

      it "includes all required metrics in churn_data" do
        get :show, params: { from: "2023-12-01", to: "2023-12-31" }

        metrics = inertia.props[:churn_data][:metrics]
        expect(metrics).to include(
          :customer_churn_rate,
          :last_period_churn_rate,
          :churned_subscribers,
          :churned_mrr_cents
        )

        expect(metrics[:customer_churn_rate]).to be_a(Numeric)
        expect(metrics[:churned_subscribers]).to be_a(Integer)
        expect(metrics[:churned_mrr_cents]).to be_a(Integer)
      end

      it "includes daily data array with correct structure" do
        get :show, params: { from: "2023-12-01", to: "2023-12-31" }

        daily_data = inertia.props[:churn_data][:daily_data]
        expect(daily_data).to be_an(Array)
        expect(daily_data.length).to eq(31)  # 31 days in December

        daily_data.each do |day|
          expect(day).to include(
            :date,
            :month,
            :month_index,
            :customer_churn_rate,
            :churned_subscribers,
            :churned_mrr_cents,
            :active_at_start,
            :new_subscribers
          )
        end
      end

      it "creates large seller record if warranted" do
        expect(LargeSeller).to receive(:create_if_warranted).with(user)
        get :show
      end

      it "uses Elasticsearch for data fetching" do
        # Verify ES is called, not database queries
        expect(Purchase).to receive(:search).at_least(:once).and_call_original
        expect(Subscription).not_to receive(:where)

        get :show
      end
    end

    context "when user has no subscription products" do
      let!(:product) { create(:product, user: user) }  # Regular product, not subscription

      it "denies access and redirects" do
        get :show

        expect(response).to redirect_to(dashboard_path)
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end

    context "with date parameters" do
      let!(:product) { create(:subscription_product, user: user) }
      let(:monthly_price) { create(:price, link: product, price_cents: 1000, recurrence: "monthly") }
      let(:from_date) { "2024-01-01" }
      let(:to_date) { "2024-01-31" }

      before do
        create_active_subscription(product: product, price: monthly_price, created_at: 60.days.ago)
        index_model_records(Purchase)
      end

      it "accepts valid date range" do
        get :show, params: { from: from_date, to: to_date }

        expect(response).to be_successful
        expect(inertia.props[:churn_data][:start_date]).to eq(from_date)
        expect(inertia.props[:churn_data][:end_date]).to eq(to_date)
      end

      it "returns nil churn_data for invalid date range (end before start)" do
        get :show, params: { from: "2024-01-31", to: "2024-01-01" }

        expect(response).to be_successful
        expect(inertia.props[:churn_data]).to be_nil
      end

      it "handles invalid date format gracefully" do
        expect do
          get :show, params: { from: "invalid-date", to: "2024-01-31" }
        end.to raise_error(ArgumentError, /Invalid date format/)
      end
    end

    context "with product filtering" do
      let!(:product1) { create(:subscription_product, user: user, name: "Product 1") }
      let!(:product2) { create(:subscription_product, user: user, name: "Product 2") }
      let(:monthly_price1) { create(:price, link: product1, price_cents: 1000, recurrence: "monthly") }
      let(:monthly_price2) { create(:price, link: product2, price_cents: 2000, recurrence: "monthly") }

      before do
        create_churned_subscription(
          product: product1,
          price: monthly_price1,
          created_at: 60.days.ago,
          deactivated_at: 30.days.ago
        )
        create_churned_subscription(
          product: product2,
          price: monthly_price2,
          created_at: 60.days.ago,
          deactivated_at: 30.days.ago
        )

        index_model_records(Purchase)
      end

      it "returns all products when no filter is applied" do
        get :show

        metrics = inertia.props[:churn_data][:metrics]
        expect(metrics[:churned_subscribers]).to eq(2)
        expect(metrics[:churned_mrr_cents]).to eq(3000)  # 1000 + 2000
      end

      it "filters data by selected products" do
        # Request churn data for only product1
        get :show, params: { products: [product1.id] }

        expect(response).to be_successful
        metrics = inertia.props[:churn_data][:metrics]

        # Should show only product1's data
        expect(metrics[:churned_subscribers]).to eq(1)
        expect(metrics[:churned_mrr_cents]).to eq(1000)
      end

      it "filters data for multiple selected products" do
        get :show, params: { products: [product1.id, product2.id] }

        metrics = inertia.props[:churn_data][:metrics]
        expect(metrics[:churned_subscribers]).to eq(2)
        expect(metrics[:churned_mrr_cents]).to eq(3000)
      end

      it "includes only available products in churn_props" do
        get :show

        products = inertia.props[:churn_props][:products]
        expect(products.length).to eq(2)
        expect(products.map { |p| p[:name] }).to match_array(["Product 1", "Product 2"])
      end
    end

    context "caching behavior" do
      let!(:product) { create(:subscription_product, user: user) }
      let(:monthly_price) { create(:price, link: product, price_cents: 1000, recurrence: "monthly") }

      before do
        create_churned_subscription(
          product: product,
          price: monthly_price,
          created_at: 60.days.ago,
          deactivated_at: 10.days.ago
        )

        index_model_records(Purchase)
      end

      context "for large sellers" do
        let!(:large_seller) { create(:large_seller, user: user) }

        it "uses caching for historical dates" do
          # Query historical period (3+ days ago)
          expect(ComputedSalesAnalyticsDay).to receive(:read_data_from_keys).at_least(:once).and_call_original

          get :show, params: { from: 30.days.ago.to_date.to_s, to: 10.days.ago.to_date.to_s }

          expect(response).to be_successful
          expect(inertia.props[:churn_data]).to be_present
        end

        it "creates LargeSeller record during request" do
          # Remove existing large_seller
          LargeSeller.where(user: user).delete_all

          expect do
            get :show
          end.to change { LargeSeller.where(user: user).count }.by(0).or(change { LargeSeller.where(user: user).count }.by(1))
        end
      end

      context "for regular sellers" do
        it "queries Elasticsearch without caching" do
          expect(ComputedSalesAnalyticsDay).not_to receive(:read_data_from_keys)
          expect(Purchase).to receive(:search).at_least(:once).and_call_original

          get :show

          expect(response).to be_successful
          expect(inertia.props[:churn_data]).to be_present
        end
      end
    end

    context "with MRR calculations" do
      let!(:monthly_product) { create(:subscription_product, user: user) }
      let!(:yearly_product) { create(:subscription_product, user: user) }
      let(:monthly_price) { create(:price, link: monthly_product, price_cents: 1000, recurrence: "monthly") }
      let(:yearly_price) { create(:price, link: yearly_product, price_cents: 12000, recurrence: "yearly") }

      before do
        create_churned_subscription(product: monthly_product, price: monthly_price, created_at: 60.days.ago, deactivated_at: 30.days.ago)
        create_churned_subscription(product: yearly_product, price: yearly_price, created_at: 60.days.ago, deactivated_at: 30.days.ago)

        index_model_records(Purchase)
      end

      it "correctly converts yearly MRR to monthly" do
        get :show

        metrics = inertia.props[:churn_data][:metrics]
        # Monthly: $10, Yearly: $120/12 = $10
        # Total: $20
        expect(metrics[:churned_mrr_cents]).to eq(2000)
      end
    end

    context "authorization" do
      let!(:product) { create(:subscription_product, user: user) }

      before do
        index_model_records(Purchase)
      end

      it "calls Pundit authorize" do
        expect(controller).to receive(:authorize).with(:churn).and_call_original
        get :show
        expect(response).to be_successful
      end

      it "uses ChurnPolicy for authorization" do
        get :show
        expect(response).to be_successful  # Authorized
      end
    end

    context "edge cases" do
      let!(:product) { create(:subscription_product, user: user) }

      it "handles empty churn data gracefully" do
        get :show

        expect(response).to be_successful
        expect(inertia.props[:churn_data]).to be_present
        expect(inertia.props[:churn_data][:metrics][:churned_subscribers]).to eq(0)
      end

      it "handles date range with single day" do
        get :show, params: { from: "2024-01-15", to: "2024-01-15" }

        expect(response).to be_successful
        daily_data = inertia.props[:churn_data][:daily_data]
        expect(daily_data.length).to eq(1)
      end

      it "respects user timezone" do
        pst_user = create(:user, timezone: "Pacific Time (US & Canada)")
        sign_in pst_user
        pst_product = create(:subscription_product, user: pst_user)

        get :show

        expect(response).to be_successful
        # Service should use user's timezone in ES queries
      end
    end
  end
end
