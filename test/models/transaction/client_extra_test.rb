require "test_helper"

class Transaction::ClientExtraTest < ActiveSupport::TestCase
  test "merges requested keys into the existing import hash and leaves other keys alone" do
    result = Transaction::ClientExtra.new({ "import" => { "reference" => "R-2" } })
      .apply_to({ "plaid" => { "x" => 1 }, "import" => { "source" => "Quicken", "reference" => "R-1" } })

    assert_equal({ "plaid" => { "x" => 1 }, "import" => { "source" => "Quicken", "reference" => "R-2" } }, result)
  end

  test "coerces numbers to strings and strips whitespace" do
    result = Transaction::ClientExtra.new({ "import" => { "check_number" => 1042, "source" => "  Quicken " } }).apply_to(nil)

    assert_equal({ "import" => { "check_number" => "1042", "source" => "Quicken" } }, result)
  end

  test "does not mutate the existing extra" do
    existing = { "import" => { "source" => "Quicken" } }
    Transaction::ClientExtra.new({ "import" => { "source" => "Other" } }).apply_to(existing)

    assert_equal "Quicken", existing.dig("import", "source")
  end

  test "rejects other namespaces, non-object values and malformed keys" do
    assert_not Transaction::ClientExtra.new({ "plaid" => {} }).valid?
    assert_not Transaction::ClientExtra.new("string").valid?
    assert_not Transaction::ClientExtra.new(nil).valid?
    assert_not Transaction::ClientExtra.new({ "import" => [ 1 ] }).valid?
    assert_not Transaction::ClientExtra.new({ "import" => { "Bad-Key" => "x" } }).valid?
    assert_not Transaction::ClientExtra.new({ "import" => { "k" => [ "x" ] } }).valid?
    assert_not Transaction::ClientExtra.new({ "import" => { "k" => true } }).valid?
  end

  test "caps the number of keys after merging" do
    existing = { "import" => (1..Transaction::ClientExtra::MAX_KEYS).to_h { |i| [ "k#{"a" * i}", "v" ] } }
    request = Transaction::ClientExtra.new({ "import" => { "one_more" => "v" } })

    request.apply_to(existing)

    assert_not request.valid?
  end

  test "emptying the namespace drops the key" do
    assert_equal({}, Transaction::ClientExtra.new({ "import" => nil }).apply_to({ "import" => { "a" => "b" } }))
    assert_equal({}, Transaction::ClientExtra.new({ "import" => { "a" => nil } }).apply_to({ "import" => { "a" => "b" } }))
  end

  test "retail keeps its items as a list of string objects and drops blank fields" do
    result = Transaction::ClientExtra.new({ "retail" => {
      "retailer" => "Amazon",
      "items" => [ { "title" => " Lamp ", "quantity" => 2, "note" => " " }, {}, { "title" => "Cable" } ]
    } }).apply_to(nil)

    assert_equal(
      { "retail" => { "retailer" => "Amazon", "items" => [ { "title" => "Lamp", "quantity" => "2" }, { "title" => "Cable" } ] } },
      result
    )
  end

  test "items only exist under retail" do
    assert_not Transaction::ClientExtra.new({ "import" => { "items" => [ { "title" => "x" } ] } }).valid?
  end

  test "an empty items list removes the key" do
    result = Transaction::ClientExtra.new({ "retail" => { "items" => [] } })
      .apply_to({ "retail" => { "retailer" => "Amazon", "items" => [ { "title" => "x" } ] } })

    assert_equal({ "retail" => { "retailer" => "Amazon" } }, result)
  end

  test "the key cap does not count items" do
    existing = { "retail" => (1..Transaction::ClientExtra::MAX_KEYS - 1).to_h { |i| [ "k#{"a" * i}", "v" ] } }
    request = Transaction::ClientExtra.new({ "retail" => { "items" => [ { "title" => "x" } ] } })

    request.apply_to(existing)

    assert request.valid?
  end
end
