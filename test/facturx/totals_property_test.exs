defmodule Facturx.TotalsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Facturx.{Invoice, TestInvoice}

  # Amounts as a caller would write them: two decimals, and small enough that a
  # hundred lines still land inside what an invoice plausibly holds.
  defp amount(max) do
    gen all(cents <- integer(1..max)) do
      Decimal.new(1, cents, -2)
    end
  end

  defp rate do
    # The four French rates, plus zero for the exempt category.
    gen all(r <- member_of(["20.00", "10.00", "5.50", "2.10", "0.00"])) do
      Decimal.new(r)
    end
  end

  defp line do
    gen all(
          price <- amount(50_000),
          quantity <- integer(1..40),
          rate <- rate(),
          allowance <- one_of([constant(nil), amount(5_000)]),
          charge <- one_of([constant(nil), amount(5_000)])
        ) do
      %{
        id: "L",
        name: "Ligne",
        net_price: price,
        quantity: Decimal.new(quantity),
        unit: "C62",
        vat_category: if(Decimal.equal?(rate, Decimal.new("0.00")), do: "E", else: "S"),
        vat_rate: rate,
        allowances: entry(allowance, "Remise"),
        charges: entry(charge, "Frais")
      }
    end
  end

  defp entry(nil, _reason), do: []
  defp entry(amount, reason), do: [%{amount: amount, reason: reason}]

  defp invoice do
    gen all(lines <- list_of(line(), min_length: 1, max_length: 12)) do
      %{
        TestInvoice.maximal()
        | tax_currency: nil,
          allowances: [],
          charges: [],
          preceding_invoices: [],
          lines: Enum.with_index(lines, 1) |> Enum.map(fn {l, i} -> %{l | id: "#{i}"} end),
          tax_breakdown: [],
          totals: %{}
      }
    end
  end

  property "every derived amount is expressed in cents, never in fractions of one" do
    # BR-DEC-* reject an amount with more than two decimals, and the XSD does
    # not: a rate of 5.5% on an odd price is exactly how a third decimal appears.
    check all(inv <- invoice()) do
      assert {:ok, out} = Invoice.totals(inv)

      amounts =
        Map.values(out.totals) ++
          Enum.map(out.lines, & &1[:line_total]) ++
          Enum.flat_map(out.tax_breakdown, &[&1[:basis], &1[:calculated]])

      for amount <- amounts, amount != nil do
        assert -amount.exp <= 2,
               "#{Decimal.to_string(amount, :normal)} has more than two decimals"
      end
    end
  end

  property "the derived totals satisfy the identities the schematron checks" do
    check all(inv <- invoice()) do
      assert {:ok, out} = Invoice.totals(inv)
      t = out.totals

      # BR-CO-10: the sum of the line amounts.
      assert Decimal.equal?(t[:line_total], sum(Enum.map(out.lines, & &1[:line_total])))

      # BR-CO-13: total without VAT = lines - allowances + charges.
      assert Decimal.equal?(
               t[:tax_basis_total],
               t[:line_total]
               |> Decimal.sub(t[:allowance_total] || Decimal.new(0))
               |> Decimal.add(t[:charge_total] || Decimal.new(0))
             )

      # BR-CO-14: the VAT total is the sum of the category amounts.
      assert Decimal.equal?(t[:tax_total], sum(Enum.map(out.tax_breakdown, & &1[:calculated])))

      # BR-CO-15 and BR-CO-16.
      assert Decimal.equal?(t[:grand_total], Decimal.add(t[:tax_basis_total], t[:tax_total]))

      assert Decimal.equal?(
               t[:due_payable],
               Decimal.sub(t[:grand_total], t[:prepaid] || Decimal.new(0))
             )
    end
  end

  property "each VAT category's taxable amount is the sum of what falls under it" do
    check all(inv <- invoice()) do
      assert {:ok, out} = Invoice.totals(inv)

      for entry <- out.tax_breakdown do
        same_vat = fn e ->
          e[:vat_category] == entry[:category] and Decimal.equal?(e[:vat_rate], entry[:rate])
        end

        lines = out.lines |> Enum.filter(same_vat) |> Enum.map(& &1[:line_total]) |> sum()
        allowances = out.allowances |> Enum.filter(same_vat) |> Enum.map(& &1[:amount]) |> sum()
        charges = out.charges |> Enum.filter(same_vat) |> Enum.map(& &1[:amount]) |> sum()

        expected = lines |> Decimal.sub(allowances) |> Decimal.add(charges)

        assert Decimal.equal?(entry[:basis], expected)

        assert Decimal.equal?(
                 entry[:calculated],
                 entry[:basis]
                 |> Decimal.mult(entry[:rate])
                 |> Decimal.div(100)
                 |> Decimal.round(2)
               )
      end
    end
  end

  property "deriving twice changes nothing" do
    # Idempotence is what says the second pass will not disagree with the first —
    # and, since a supplied figure that differs is an error, it is also what says
    # the output of totals/2 is accepted by totals/2.
    check all(inv <- invoice()) do
      assert {:ok, once} = Invoice.totals(inv)
      assert {:ok, twice} = Invoice.totals(once)

      assert twice == once
    end
  end

  property "what totals/2 derives, the EN 16931 schema accepts" do
    check all(inv <- invoice()) do
      assert {:ok, out} = Invoice.totals(inv)
      assert {:ok, xml} = Facturx.build(out, profile: :en16931)
      assert {:ok, :valid} = Facturx.validate_xsd(xml, profile: :en16931)
    end
  end

  defp sum(amounts) do
    Enum.reduce(amounts, Decimal.new(0), &Decimal.add(&2, &1 || Decimal.new(0)))
  end
end
