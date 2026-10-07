require "test_helper"

class Transaction::ImportExtraTest < ActiveSupport::TestCase
  test "merges requested keys into the existing import hash and leaves other keys alone" do
    result = Transaction::ImportExtra.new({ "import" => { "reference" => "R-2" } })
      .apply_to({ "plaid" => { "x" => 1 }, "import" => { "source" => "Quicken", "reference" => "R-1" } })

    assert_equal({ "plaid" => { "x" => 1 }, "import" => { "source" => "Quicken", "reference" => "R-2" } }, result)
  end

  test "coerces numbers to strings and strips whitespace" do
    result = Transaction::ImportExtra.new({ "import" => { "check_number" => 1042, "source" => "  Quicken " } }).apply_to(nil)

    assert_equal({ "import" => { "check_number" => "1042", "source" => "Quicken" } }, result)
  end

  test "does not mutate the existing extra" do
    existing = { "import" => { "source" => "Quicken" } }
    Transaction::ImportExtra.new({ "import" => { "source" => "Other" } }).apply_to(existing)

    assert_equal "Quicken", existing.dig("import", "source")
  end

  test "rejects other namespaces, non-object values and malformed keys" do
    assert_not Transaction::ImportExtra.new({ "plaid" => {} }).valid?
    assert_not Transaction::ImportExtra.new("string").valid?
    assert_not Transaction::ImportExtra.new(nil).valid?
    assert_not Transaction::ImportExtra.new({ "import" => [ 1 ] }).valid?
    assert_not Transaction::ImportExtra.new({ "import" => { "Bad-Key" => "x" } }).valid?
    assert_not Transaction::ImportExtra.new({ "import" => { "k" => [ "x" ] } }).valid?
    assert_not Transaction::ImportExtra.new({ "import" => { "k" => true } }).valid?
  end

  test "caps the number of keys after merging" do
    existing = { "import" => (1..Transaction::ImportExtra::MAX_KEYS).to_h { |i| [ "k#{"a" * i}", "v" ] } }
    request = Transaction::ImportExtra.new({ "import" => { "one_more" => "v" } })

    request.apply_to(existing)

    assert_not request.valid?
  end

  test "emptying the namespace drops the key" do
    assert_equal({}, Transaction::ImportExtra.new({ "import" => nil }).apply_to({ "import" => { "a" => "b" } }))
    assert_equal({}, Transaction::ImportExtra.new({ "import" => { "a" => nil } }).apply_to({ "import" => { "a" => "b" } }))
  end
end
