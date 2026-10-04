require "test_helper"

class ProviderRequestCountTest < ActiveSupport::TestCase
  test "increment! creates the counter and returns the new count" do
    assert_equal 1, ProviderRequestCount.increment!("rentcast")
    assert_equal 2, ProviderRequestCount.increment!("rentcast")
    assert_equal 2, ProviderRequestCount.count_for("rentcast")
  end

  test "counts are scoped per provider and period" do
    ProviderRequestCount.increment!("rentcast")
    ProviderRequestCount.increment!("realie")
    ProviderRequestCount.increment!("rentcast", period: "2020-01")

    assert_equal 1, ProviderRequestCount.count_for("rentcast")
    assert_equal 1, ProviderRequestCount.count_for("realie")
    assert_equal 1, ProviderRequestCount.count_for("rentcast", period: "2020-01")
  end

  test "decrement! floors at zero" do
    ProviderRequestCount.increment!("rentcast")
    ProviderRequestCount.decrement!("rentcast")
    ProviderRequestCount.decrement!("rentcast")

    assert_equal 0, ProviderRequestCount.count_for("rentcast")
  end

  test "count_for returns zero when no counter exists" do
    assert_equal 0, ProviderRequestCount.count_for("rentcast")
  end

  test "set! overwrites the count and keeps a reported limit" do
    ProviderRequestCount.increment!("cardog", by: 6)
    ProviderRequestCount.set!("cardog", 8, limit: 50)
    assert_equal 8, ProviderRequestCount.count_for("cardog")
    assert_equal 50, ProviderRequestCount.reported_limit_for("cardog")

    ProviderRequestCount.set!("cardog", 11)
    assert_equal 11, ProviderRequestCount.count_for("cardog")
    assert_equal 50, ProviderRequestCount.reported_limit_for("cardog")
  end

  test "increment! and decrement! accept a cost" do
    assert_equal 5, ProviderRequestCount.increment!("cardog", by: 5)
    assert_equal 6, ProviderRequestCount.increment!("cardog", by: 1)
    ProviderRequestCount.decrement!("cardog", by: 5)

    assert_equal 1, ProviderRequestCount.count_for("cardog")
  end
end
