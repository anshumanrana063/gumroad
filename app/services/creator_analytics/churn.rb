# frozen_string_literal: true

# Calculates customer churn rate metrics for subscription products using Elasticsearch.
# Follows CreatorAnalytics::Following pattern with inline caching for large sellers.
#
# Churn rate formula (per Stripe):
#   (Churned Customers / Total Base Customers) × 100
#
# Where Total Base = Active at Start + New During Period
#
# @see https://stripe.com/resources/more/monthly-churn-101
class CreatorAnalytics::Churn
  include ActiveModel::Validations

  DEFAULT_START_DATE_OFFSET = 1.month

  validates :end_date, comparison: { greater_than_or_equal_to: :start_date }

  attr_reader :start_date, :end_date, :user, :products

  def initialize(user:, start_date: nil, end_date: nil, params: {}, products: nil)
    @user = user
    @params = params
    @start_date = parse_date(start_date, :start)
    @end_date = parse_date(end_date, :end)
    @products = products || parse_products
  end

  def fetch_churn_data
    return nil unless has_subscription_products?
    return nil unless valid?

    daily_data_by_date = fetch_daily_churn_with_caching
    period_metrics = calculate_period_metrics_from_daily(daily_data_by_date)
    last_period_rate = calculate_last_period_churn_rate

    {
      start_date: start_date.to_s,
      end_date: end_date.to_s,
      metrics: build_metrics(period_metrics, last_period_rate),
      daily_data: format_daily_data(daily_data_by_date)
    }
  end

  def has_subscription_products?
    user.products.alive.is_recurring_billing.exists?
  end

  def available_products
    user.products_for_creator_analytics.select(&:is_recurring_billing?)
  end

  def time_window
    (end_date - start_date).to_i + 1
  end

  def self.customer_churn_rate(user:, start_date:, end_date:, products: nil)
    new(
      user: user,
      start_date: start_date,
      end_date: end_date,
      products: products
    ).send(:calculate_churn_rate_from_data)
  end

  private
    # Fetch daily churn data with caching for historical dates (like CachingProxy pattern)
    def fetch_daily_churn_with_caching
      dates = (start_date..end_date).to_a

      if use_cache?
        fetch_with_per_day_caching(dates)
      else
        query_churn_for_date_range(dates)
      end
    end

    def fetch_with_per_day_caching(dates)
      # Split dates into cached (old) and realtime (recent)
      cached_dates = dates.select { |d| d <= last_date_to_cache }
      realtime_dates = dates.select { |d| d > last_date_to_cache }

      result = {}

      # Fetch cached data for old dates
      if cached_dates.any?
        keys_to_dates = cached_dates.index_by { |d| cache_key_for_date(d) }
        cached_data = ComputedSalesAnalyticsDay.read_data_from_keys(keys_to_dates.keys)

        cached_data.each do |key, data|
          date = keys_to_dates[key]
          result[date] = data if date && data
        end

        # Find missing cached dates and query them
        missing_dates = cached_dates - result.keys
        if missing_dates.any?
          fresh_data = query_churn_for_date_range(missing_dates)

          # Store in cache
          fresh_data.each do |date, data|
            ComputedSalesAnalyticsDay.upsert_data_from_key(cache_key_for_date(date), data)
            result[date] = data
          end
        end
      end

      # Fetch realtime data for recent dates
      if realtime_dates.any?
        realtime_data = query_churn_for_date_range(realtime_dates)
        result.merge!(realtime_data)
      end

      result
    end

    # Query Elasticsearch for churn data across date range (following Following pattern)
    # ONE query for all dates using date_histogram
    def query_churn_for_date_range(dates)
      date_range_start = dates.min
      date_range_end = dates.max

      body = {
        query: build_subscription_query_for_range(date_range_start, date_range_end),
        size: 0,
        aggs: {
          churned_by_date: {
            date_histogram: {
              field: "subscription_deactivated_at",
              calendar_interval: "day",
              time_zone: user.timezone_formatted_offset,
              format: "yyyy-MM-dd",
              min_doc_count: 0,
              extended_bounds: { min: date_range_start.to_s, max: date_range_end.to_s }
            },
            aggs: {
              unique_subscriptions: { cardinality: { field: "subscription_id" } },
              churned_mrr: { sum: { field: "monthly_recurring_revenue" } }
            }
          },
          new_by_date: {
            filter: {
              range: {
                created_at: {
                  gte: date_range_start.to_s,
                  lte: date_range_end.to_s
                }
              }
            },
            aggs: {
              by_date: {
                date_histogram: {
                  field: "created_at",
                  calendar_interval: "day",
                  time_zone: user.timezone_formatted_offset,
                  format: "yyyy-MM-dd",
                  min_doc_count: 0,
                  extended_bounds: { min: date_range_start.to_s, max: date_range_end.to_s }
                },
                aggs: {
                  unique_subscriptions: { cardinality: { field: "subscription_id" } }
                }
              }
            }
          }
        }
      }

      response = Purchase.search(body)
      parse_churn_aggregations(response.aggregations, dates)
    end

    def parse_churn_aggregations(aggregations, dates)
      churned_buckets = aggregations.churned_by_date.buckets
      new_buckets = aggregations.dig(:new_by_date, :by_date, :buckets) || []

      churned_by_date = churned_buckets.each_with_object({}) do |bucket, hash|
        date = Date.parse(bucket["key_as_string"])
        hash[date] = {
          churned_count: bucket.unique_subscriptions.value.to_i,
          churned_mrr_cents: bucket.churned_mrr.value.to_i
        }
      end

      new_by_date = new_buckets.each_with_object({}) do |bucket, hash|
        date = Date.parse(bucket["key_as_string"])
        hash[date] = { new_subscribers: bucket.unique_subscriptions.value.to_i }
      end

      # Get active at start (only for first date)
      active_at_start = active_subscriptions_at(dates.min)

      # Build result for all dates
      dates.each_with_object({}) do |date, result|
        result[date] = {
          date: date.to_s,
          customer_churn_rate: 0.0,  # Calculated later with running totals
          churned_subscribers: churned_by_date.dig(date, :churned_count) || 0,
          churned_mrr_cents: churned_by_date.dig(date, :churned_mrr_cents) || 0,
          active_at_start: (date == dates.min ? active_at_start : 0),
          new_subscribers: new_by_date.dig(date, :new_subscribers) || 0
        }
      end
    end

    def active_subscriptions_at(date)
      body = {
        query: {
          bool: {
            filter: [
              { terms: { product_id: subscription_products.pluck(:id) } },
              { term: { seller_id: user.id } },
              { exists: { field: "subscription_id" } },
              { term: { not_subscription_or_original_subscription_purchase: true } },
              { range: { created_at: { lt: date.to_s } } }
            ],
            should: [
              { bool: { must_not: { exists: { field: "subscription_deactivated_at" } } } },
              { range: { subscription_deactivated_at: { gt: date.to_s } } }
            ],
            minimum_should_match: 1
          }
        },
        size: 0,
        aggs: {
          active_subscriptions: { cardinality: { field: "subscription_id" } }
        }
      }

      response = Purchase.search(body)
      response.aggregations.active_subscriptions.value.to_i
    end

    def build_subscription_query_for_range(start_date, end_date)
      {
        bool: {
          filter: [
            { term: { seller_id: user.id } },
            { terms: { product_id: subscription_products.pluck(:id) } },
            { exists: { field: "subscription_id" } },
            # Query original subscription purchases (not recurring charges)
            { term: { not_subscription_or_original_subscription_purchase: true } }
          ],
          should: [
            # Churned in this range
            { range: { subscription_deactivated_at: { gte: start_date.to_s, lte: end_date.to_s } } },
            # Created in this range (new subscriptions)
            { range: { created_at: { gte: start_date.to_s, lte: end_date.to_s } } }
          ],
          minimum_should_match: 1
        }
      }
    end

    # Calculate running totals and churn rates
    def calculate_period_metrics_from_daily(daily_data_by_date)
      total_churned = 0
      total_churned_mrr_cents = 0
      total_new = 0
      running_active = 0

      # Sort dates to ensure chronological processing
      sorted_dates = daily_data_by_date.keys.sort

      # First pass: get totals and initial active count
      sorted_dates.each do |date|
        data = daily_data_by_date[date]

        if date == start_date
          running_active = data[:active_at_start] || 0
        end

        total_churned += (data[:churned_subscribers] || 0)
        total_churned_mrr_cents += (data[:churned_mrr_cents] || 0)
        total_new += (data[:new_subscribers] || 0)
      end

      # Second pass: calculate churn rates with running totals
      sorted_dates.each do |date|
        data = daily_data_by_date[date]

        if date == start_date
          running_active = data[:active_at_start] || 0
        end

        new_subs = data[:new_subscribers] || 0
        churned_subs = data[:churned_subscribers] || 0
        base = running_active + new_subs
        churn_rate = base > 0 ? (churned_subs.to_f / base * 100).round(2) : 0.0

        data[:customer_churn_rate] = churn_rate
        data[:active_at_start] = running_active

        running_active = running_active + new_subs - churned_subs
      end

      first_day_data = daily_data_by_date.values.first || {}
      active_at_start = first_day_data[:active_at_start] || 0
      total_base = active_at_start + total_new
      overall_churn_rate = total_base.zero? ? 0.0 : (total_churned.to_f / total_base * 100).round(2)

      {
        churn_rate: overall_churn_rate,
        churned_subscribers: total_churned,
        churned_mrr_cents: total_churned_mrr_cents,
        total_base: total_base,
        active_at_start: active_at_start,
        new_subscribers: total_new
      }
    end

    def calculate_churn_rate_from_data
      daily_data = fetch_daily_churn_with_caching
      metrics = calculate_period_metrics_from_daily(daily_data)
      metrics[:churn_rate]
    end

    def calculate_last_period_churn_rate
      period_length = (end_date - start_date).to_i
      last_period_end = start_date - 1.day
      last_period_start = last_period_end - period_length.days

      self.class.customer_churn_rate(
        user: user,
        start_date: last_period_start,
        end_date: last_period_end,
        products: @products
      )
    end

    def subscription_products
      @subscription_products ||= begin
        base_products = user.products.alive.is_recurring_billing
        if @products.present?
          base_products.where(id: @products.map(&:id))
        else
          base_products
        end
      end
    end

    def build_metrics(period_metrics, last_period_rate)
      {
        customer_churn_rate: period_metrics[:churn_rate],
        last_period_churn_rate: last_period_rate,
        churned_subscribers: period_metrics[:churned_subscribers],
        churned_mrr_cents: period_metrics[:churned_mrr_cents]
      }
    end

    def format_daily_data(daily_data_by_date)
      (start_date..end_date).map do |date|
        data = daily_data_by_date[date] || {}
        {
          date: data[:date] || date.to_s,
          month: date.strftime("%B %Y"),
          month_index: ((date.year - start_date.year) * 12) + (date.month - start_date.month),
          customer_churn_rate: data[:customer_churn_rate] || 0.0,
          churned_subscribers: data[:churned_subscribers] || 0,
          churned_mrr_cents: data[:churned_mrr_cents] || 0,
          active_at_start: data[:active_at_start] || 0,
          new_subscribers: data[:new_subscribers] || 0
        }
      end
    end

    def parse_date(date_value, type)
      return date_value.to_date if date_value

      case type
      when :start
        (@params[:start_time] || @params[:from])&.to_date || DEFAULT_START_DATE_OFFSET.ago.to_date
      when :end
        (@params[:end_time] || @params[:to])&.to_date || Date.current
      end
    rescue Date::Error => e
      raise ArgumentError, "Invalid date format: #{e.message}"
    end

    def parse_products
      return Link.none unless @params[:products].present?

      @user.products.where(id: @params[:products])
    end

    # Caching helpers (following CachingProxy pattern)
    def use_cache?
      LargeSeller.where(user: @user).exists?
    end

    def cache_key_for_date(date)
      "#{user_cache_key}_churn_for_#{date}"
    end

    def user_cache_key
      return @_user_cache_key if @_user_cache_key
      version = $redis.get(RedisKey.seller_analytics_cache_version) || 0
      product_ids = subscription_products.pluck(:id).sort.join(",")
      @_user_cache_key = "churn_v#{version}_user_#{@user.id}_#{@user.timezone}_products_#{product_ids}"
    end

    def today_date
      Time.now.in_time_zone(@user.timezone).to_date
    end

    def last_date_to_cache
      today_date - 2.days
    end
end
