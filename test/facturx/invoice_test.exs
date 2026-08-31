defmodule Facturx.InvoiceTest do
  use ExUnit.Case, async: true

  alias Facturx.{Invoice, TestInvoice}

  defp d(s), do: Decimal.new(s)

  defp minimal_attrs(extra \\ %{}) do
    Map.merge(
      %{
        number: "FA-1",
        issue_date: ~D[2026-03-15],
        type_code: "380",
        currency: "EUR",
        seller: %{name: "Vendeur SAS"},
        buyer: %{name: "Acheteur SARL"}
      },
      extra
    )
  end

  describe "new/1" do
    test "builds a struct from a plain map" do
      assert {:ok, %Invoice{number: "FA-1", currency: "EUR"}} = Invoice.new(minimal_attrs())
    end

    test "reports every problem at once, not the first" do
      assert {:error, errors} = Invoice.new(%{currency: "EURO"})

      assert {[:number], :required} in errors
      assert {[:issue_date], :required} in errors
      assert {[:type_code], :required} in errors
      assert {[:seller], :required} in errors
      assert {[:buyer], :required} in errors
      assert {[:currency], :not_a_currency_code} in errors
    end

    test "a party without a name is located precisely" do
      assert {:error, errors} = Invoice.new(minimal_attrs(%{buyer: %{vat: "FR1"}}))
      assert {[:buyer, :name], :required} in errors
    end

    test "an issue date that is not a Date is refused" do
      assert {:error, errors} = Invoice.new(minimal_attrs(%{issue_date: "2026-03-15"}))
      assert {[:issue_date], :not_a_date} in errors
    end
  end

  describe "new/1 amount coercion" do
    test "integers and strings become Decimal, wherever they sit" do
      attrs =
        minimal_attrs(%{
          totals: %{grand_total: "314.00", prepaid: 100},
          lines: [%{net_price: "100.00", quantity: 2, allowances: [%{amount: "5.00"}]}],
          charges: [%{amount: 30}],
          tax_breakdown: [%{rate: "20.00", basis: "220.00"}]
        })

      assert {:ok, inv} = Invoice.new(attrs)
      assert Decimal.equal?(inv.totals[:grand_total], d("314.00"))
      assert Decimal.equal?(inv.totals[:prepaid], d("100"))
      assert Decimal.equal?(hd(inv.lines)[:net_price], d("100.00"))
      assert Decimal.equal?(hd(inv.lines)[:quantity], d("2"))
      assert Decimal.equal?(hd(hd(inv.lines)[:allowances])[:amount], d("5.00"))
      assert Decimal.equal?(hd(inv.charges)[:amount], d("30"))
      assert Decimal.equal?(hd(inv.tax_breakdown)[:rate], d("20.00"))
    end

    test "a string keeps its scale, because a scale is a number of cents" do
      assert {:ok, inv} = Invoice.new(minimal_attrs(%{totals: %{grand_total: "1.50"}}))
      assert Decimal.to_string(inv.totals[:grand_total], :normal) == "1.50"
    end

    test "floats are refused, and the path says which one" do
      attrs = minimal_attrs(%{lines: [%{net_price: d("1")}, %{net_price: 1.5}]})

      assert {:error, [{[:lines, 1, :net_price], :float}]} = Invoice.new(attrs)
    end

    test "NaN and Infinity are refused wherever an amount is expected" do
      for bad <- ["NaN", "Infinity", "-Infinity"] do
        {value, ""} = Decimal.parse(bad)
        attrs = minimal_attrs(%{totals: %{grand_total: value}})

        assert {:error, [{[:totals, :grand_total], :not_a_finite_amount}]} = Invoice.new(attrs),
               "#{bad} was accepted"
      end
    end

    test "a string that is not a number is refused rather than read as zero" do
      attrs = minimal_attrs(%{totals: %{grand_total: "314,00"}})

      assert {:error, [{[:totals, :grand_total], :not_a_number}]} = Invoice.new(attrs)
    end
  end

  describe "totals/2" do
    # The reference invoice's figures are maintained by hand and have been through
    # the schematron; deriving them from scratch and landing on the same numbers
    # is the strongest check available without a network call.
    test "derives exactly what the reference invoice states" do
      reference = TestInvoice.maximal()

      assert {:ok, computed} = Invoice.totals(stripped(reference))

      for key <- [
            :line_total,
            :allowance_total,
            :charge_total,
            :tax_basis_total,
            :tax_total,
            :grand_total,
            :due_payable
          ] do
        assert Decimal.equal?(computed.totals[key], reference.totals[key]),
               "#{key}: #{computed.totals[key]} vs #{reference.totals[key]}"
      end

      assert Enum.map(computed.lines, & &1[:line_total]) ==
               Enum.map(reference.lines, & &1[:line_total])
    end

    test "derives the VAT breakdown, one entry per category and rate" do
      assert {:ok, computed} = Invoice.totals(stripped(TestInvoice.maximal()))

      assert [exempt, standard] = computed.tax_breakdown

      assert exempt[:category] == "E"
      assert Decimal.equal?(exempt[:basis], d("50.00"))
      assert Decimal.equal?(exempt[:calculated], d("0.00"))

      assert standard[:category] == "S"
      # 210.00 of lines, less the 20.00 allowance, plus the 30.00 charge.
      assert Decimal.equal?(standard[:basis], d("220.00"))
      assert Decimal.equal?(standard[:calculated], d("44.00"))
    end

    test "keeps the exemption reason, which no amount can imply" do
      assert {:ok, computed} = Invoice.totals(stripped(TestInvoice.maximal()))
      exempt = Enum.find(computed.tax_breakdown, &(&1[:category] == "E"))

      assert exempt[:exemption_reason_code] == "VATEX-EU-132-1I"
      assert exempt[:exemption_reason] =~ "Exonération"
    end

    test "reports a disagreement instead of resolving it" do
      wrong = put_in(stripped(TestInvoice.maximal()).totals[:grand_total], d("999.00"))

      assert {:error, {:totals_mismatch, diffs}} = Invoice.totals(wrong)

      assert {[:totals, :grand_total], given, computed} =
               List.keyfind(diffs, [:totals, :grand_total], 0)

      assert Decimal.equal?(given, d("999.00"))
      assert Decimal.equal?(computed, d("314.00"))
    end

    test "overwrite: true takes the computed figures" do
      wrong = put_in(stripped(TestInvoice.maximal()).totals[:grand_total], d("999.00"))

      assert {:ok, computed} = Invoice.totals(wrong, overwrite: true)
      assert Decimal.equal?(computed.totals[:grand_total], d("314.00"))
    end

    test "a line total the caller supplied is kept, and checked" do
      inv = stripped(TestInvoice.maximal())
      wrong = %{inv | lines: List.update_at(inv.lines, 0, &Map.put(&1, :line_total, d("1.00")))}

      assert {:error, {:totals_mismatch, diffs}} = Invoice.totals(wrong)
      assert Enum.any?(diffs, fn {path, _, _} -> path == [:lines, "1", :line_total] end)
    end

    test "refuses to add a non-finite amount rather than propagating it" do
      {nan, ""} = Decimal.parse("NaN")
      inv = stripped(TestInvoice.maximal())
      hostile = %{inv | lines: List.update_at(inv.lines, 0, &Map.put(&1, :net_price, nan))}

      assert {:error, {:not_a_finite_amount, _}} = Invoice.totals(hostile)
    end

    test "BT-113 and BT-114 are read, never derived" do
      inv = stripped(TestInvoice.maximal())
      # 314.00 grand total, 100.00 prepaid, and a cent of rounding.
      with_rounding = put_in(inv.totals[:rounding], d("0.01"))

      assert {:ok, computed} = Invoice.totals(with_rounding)
      assert Decimal.equal?(computed.totals[:due_payable], d("214.01"))
    end

    test "an invoice with no allowances or charges emits neither total" do
      attrs = %{
        TestInvoice.maximal()
        | allowances: [],
          charges: [],
          lines: [
            %{
              id: "1",
              name: "x",
              net_price: d("10.00"),
              quantity: d("1"),
              vat_category: "S",
              vat_rate: d("20.00")
            }
          ],
          tax_breakdown: [],
          totals: %{}
      }

      assert {:ok, computed} = Invoice.totals(attrs)
      refute Map.has_key?(computed.totals, :allowance_total)
      refute Map.has_key?(computed.totals, :charge_total)
      assert Decimal.equal?(computed.totals[:grand_total], d("12.00"))
    end
  end

  # The reference invoice with every derived figure removed, so `totals/2` has to
  # produce them rather than agree with them.
  defp stripped(inv) do
    %{
      inv
      | lines: Enum.map(inv.lines, &Map.delete(&1, :line_total)),
        tax_breakdown: Enum.map(inv.tax_breakdown, &Map.drop(&1, [:basis, :calculated])),
        totals: Map.take(inv.totals, [:prepaid])
    }
  end
end
