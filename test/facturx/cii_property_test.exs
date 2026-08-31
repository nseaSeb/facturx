defmodule Facturx.CIIPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Facturx.{CII, TestInvoice}

  # `Facturx.TestInvoice.maximal/0` is the one invoice that populates every data
  # item the builder knows how to emit. Rather than invent invoices from
  # scratch — which would mostly generate documents the XSD rejects for reasons
  # that say nothing about the round-trip — each property removes a random
  # subset of the optional blocks from it. Every draw is therefore a plausible
  # invoice, and the drawn subsets between them cover the presence/absence
  # combinations of the blocks that `CII.build/2` guards.
  #
  # Some removals come in pairs, because removing one half alone changes the
  # document rather than shrinking it: BT-6 (`:tax_currency`) is what gives
  # BT-111 its distinct currencyID, so the two go together.
  defp prunings do
    [
      {:business_process, &%{&1 | business_process: nil}},
      {:notes, &%{&1 | notes: []}},
      {:due_date, &%{&1 | due_date: nil}},
      {:tax_representative, &%{&1 | tax_representative: nil}},
      {:ship_to, &%{&1 | ship_to: nil}},
      {:delivery_date, &%{&1 | delivery_date: nil}},
      {:billing_period, &%{&1 | billing_period: nil}},
      {:preceding_invoices, &%{&1 | preceding_invoices: []}},
      {:payment_means, &%{&1 | payment_means: []}},
      {:allowances_and_charges, &%{&1 | allowances: [], charges: []}},
      {:tax_due_date_type_code, &%{&1 | tax_due_date_type_code: nil}},
      {:tax_currency, &__MODULE__.drop_tax_currency/1},
      {:line_notes, &__MODULE__.drop_from_lines(&1, [:notes])},
      {:line_billing_period, &__MODULE__.drop_from_lines(&1, [:billing_period])},
      {:line_preceding_invoice, &__MODULE__.drop_from_lines(&1, [:preceding_invoice])},
      {:line_ship_to, &__MODULE__.drop_from_lines(&1, [:ship_to])},
      {:line_delivery_date, &__MODULE__.drop_from_lines(&1, [:delivery_date])},
      {:line_allow_charge, &__MODULE__.drop_from_lines(&1, [:allowances, :charges])},
      {:line_gross_price, &__MODULE__.drop_from_lines(&1, [:gross_price, :price_discount])}
    ]
  end

  @doc false
  def drop_tax_currency(inv) do
    %{inv | tax_currency: nil, totals: Map.delete(inv.totals, :tax_total_in_tax_currency)}
  end

  @doc false
  def drop_from_lines(inv, keys) do
    %{inv | lines: Enum.map(inv.lines, &Map.drop(&1, keys))}
  end

  defp pruned_invoice do
    all = prunings()

    gen all(dropped <- list_of(member_of(all), max_length: length(all))) do
      Enum.reduce(dropped, TestInvoice.maximal(), fn {_name, prune}, inv -> prune.(inv) end)
    end
  end

  # Amounts are the one thing a rounding or formatting slip would corrupt
  # silently. The library never calls `Decimal.new/1` on a float, so the
  # generator builds decimals from an integer coefficient and an explicit
  # exponent — the shape a caller gets from `Decimal.new/1` on a string.
  defp money do
    gen all(
          sign <- member_of([1, -1]),
          coefficient <- integer(0..99_999_999),
          exponent <- integer(-4..0)
        ) do
      Decimal.new(sign, coefficient, exponent)
    end
  end

  describe "build/parse round-trip" do
    # The roadmap calls `parse(build(inv)) == inv` "the invariant", but stated
    # that way it is false by design: build writes defaults the struct left
    # implicit (`legal_scheme: "0002"`, a line's `"C62"`, a tax entry's `"VAT"`),
    # so parse hands back a *normalised* struct. Normalisation happens once, on
    # the first pass — which is exactly what makes the fixed point the honest
    # statement of the same idea, and a strictly stronger one: it also pins that
    # the second build is byte-identical, not merely equivalent.
    property "a second pass changes neither the struct nor a byte of the XML" do
      check all(inv <- pruned_invoice()) do
        assert {:ok, xml} = CII.build(inv, profile: :extended)
        assert {:ok, parsed} = CII.parse(xml)
        assert {:ok, xml2} = CII.build(parsed, profile: :extended)
        assert {:ok, reparsed} = CII.parse(xml2)

        assert xml2 == xml
        assert reparsed == parsed
      end
    end

    property "every pruning still produces a document the EXTENDED XSD accepts" do
      check all(inv <- pruned_invoice()) do
        assert {:ok, xml} = CII.build(inv, profile: :extended)
        assert {:ok, :valid} = Facturx.validate_xsd(xml, profile: :extended)
      end
    end
  end

  describe "Decimal rendering" do
    property "an amount survives build/parse with its value and its scale intact" do
      check all(amount <- money()) do
        inv = put_in(TestInvoice.maximal().totals[:grand_total], amount)

        assert {:ok, xml} = CII.build(inv, profile: :extended)
        assert {:ok, parsed} = CII.parse(xml)

        back = parsed.totals[:grand_total]

        assert Decimal.equal?(back, amount)
        # Not just equal: identical. `1.50` and `1.5` are equal decimals but a
        # different number of cents on an invoice, and CII carries the scale.
        assert Decimal.to_string(back, :normal) == Decimal.to_string(amount, :normal)
      end
    end

    property "no amount is ever emitted in exponential notation" do
      check all(amount <- money()) do
        inv = put_in(TestInvoice.maximal().totals[:grand_total], amount)

        assert {:ok, xml} = CII.build(inv, profile: :extended)
        assert [_, rendered] = Regex.run(~r|<ram:GrandTotalAmount>([^<]*)</|, xml)
        refute rendered =~ ~r/[eE]/
      end
    end
  end
end
