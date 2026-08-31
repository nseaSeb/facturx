defmodule Facturx.InvoiceTest do
  use ExUnit.Case, async: true

  alias Facturx.{Invoice, TestInvoice}

  # The `iex>` block in `new/1` is otherwise decoration: it drifted from the code
  # once already, listing six errors where seven are returned and in the wrong
  # order.
  doctest Facturx.Invoice

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
          lines: [
            %{
              net_price: "100.00",
              quantity: 2,
              vat_category: "S",
              vat_rate: "20.00",
              allowances: [%{amount: "5.00"}]
            }
          ],
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
      vat = %{vat_category: "S", vat_rate: d("20.00")}

      attrs =
        minimal_attrs(%{
          lines: [Map.put(vat, :net_price, d("1")), Map.put(vat, :net_price, 1.5)]
        })

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

    test "a collection that is not one is an error, not an exception" do
      # new/1 promises every problem back as data, and the coercion walk runs
      # before the shape checks — so it has to survive what it is walking.
      assert {:error, errors} = Invoice.new(minimal_attrs(%{lines: "abc"}))
      assert {[:lines], :not_a_list} in errors

      assert {:error, errors} = Invoice.new(minimal_attrs(%{lines: ["x"]}))
      assert {[:lines, 0], :not_a_map} in errors

      assert {:error, errors} = Invoice.new(minimal_attrs(%{totals: "none"}))
      assert {[:totals], :not_a_map} in errors
    end

    test "a currency that is not three letters is refused" do
      for bad <- ["123", "---", "eur", "EURO", "EU", "€", 978] do
        assert {:error, errors} = Invoice.new(minimal_attrs(%{currency: bad}))

        assert {[:currency], :not_a_currency_code} in errors,
               "#{inspect(bad)} was accepted as a currency"
      end
    end

    test "a string that is not a number is refused rather than read as zero" do
      attrs = minimal_attrs(%{totals: %{grand_total: "314,00"}})

      assert {:error, [{[:totals, :grand_total], :not_a_number}]} = Invoice.new(attrs)
    end
  end

  describe "totals/2 refuses what it cannot derive" do
    # Everything totals/2 computes is founded on the line amounts. With no lines
    # there is nothing to derive, and deriving zero would be a lie: a BASIC WL or
    # MINIMUM invoice carries no lines and still has a VAT liability. Before this,
    # such an invoice came back {:ok, …} with its declared breakdown emptied and
    # a grand total of 0.00.
    test "an invoice with no lines is an error, not a zero total" do
      inv = %{priced([{"50.00", "S", "20.00"}]) | lines: []}

      assert Invoice.totals(inv) == {:error, :no_lines}
    end

    test "a breakdown entry matching no line is an error, not a dropped liability" do
      inv =
        %{
          priced([{"50.00", "S", "20.00"}])
          | tax_breakdown: [
              %{category: "E", rate: d("0.00"), basis: d("30.00"), calculated: d("0.00")}
            ]
        }

      assert {:error, {:orphan_tax_breakdown, [{"E", "0"}]}} = Invoice.totals(inv)
    end

    test "an amount that is not a Decimal is refused rather than coerced" do
      # compute/2 takes any Invoice, not only one new/1 built, and it both adds
      # and sorts these. A rate written `20` used to raise out of the sort.
      inv = %{
        priced([{"50.00", "S", "20.00"}])
        | lines: [
            %{id: "1", vat_category: "S", vat_rate: 20, net_price: d("1.00"), quantity: d("1")}
          ]
      }

      assert {:error, {:not_a_decimal, [:lines, 0, :vat_rate], 20}} = Invoice.totals(inv)
    end
  end

  describe "totals/2 grouping" do
    # `Decimal.new("20")` and `Decimal.new("20.00")` are numerically equal and
    # different terms. Grouping on the term produced two ram:ApplicableTradeTax
    # entries for one category and rate, which the schematron rejects.
    test "two spellings of the same rate make one breakdown entry" do
      inv = priced([{"50.00", "S", "20"}, {"100.00", "S", "20.00"}])

      assert {:ok, out} = Invoice.totals(inv)
      assert [entry] = out.tax_breakdown
      assert Decimal.equal?(entry[:basis], d("150.00"))
      assert Decimal.equal?(entry[:calculated], d("30.00"))
    end

    test "a supplied entry is matched whatever scale its rate is written at" do
      inv =
        %{
          priced([{"50.00", "E", "0"}])
          | tax_breakdown: [
              %{
                type: "VAT",
                category: "E",
                rate: d("0.00"),
                exemption_reason: "Exonération article 261-4-4 du CGI",
                exemption_reason_code: "VATEX-EU-132-1I"
              }
            ]
        }

      assert {:ok, out} = Invoice.totals(inv)
      assert [entry] = out.tax_breakdown
      # BR-E-10 rejects an exempt breakdown without one, and no amount implies it.
      assert entry[:exemption_reason_code] == "VATEX-EU-132-1I"
      assert Decimal.equal?(entry[:basis], d("50.00"))
    end

    test "the rate is emitted as it was written, not as the key normalised it" do
      inv = priced([{"50.00", "S", "20.00"}])

      assert {:ok, out} = Invoice.totals(inv)
      assert Decimal.to_string(hd(out.tax_breakdown)[:rate], :normal) == "20.00"
    end
  end

  describe "amounts that cannot be added" do
    # The finiteness gate walks Invoice.amount_paths/1, the same list new/1
    # coerces and CII.build/2 refuses on. Three separate lists would have drifted,
    # and the field they all forgot would be the one carrying the NaN.
    test "a NaN anywhere an amount is expected stops totals/2" do
      {nan, ""} = Decimal.parse("NaN")

      cases = [
        {"line net price", &put_in(&1.lines, [Map.put(hd(&1.lines), :net_price, nan)])},
        {"line gross price", &put_in(&1.lines, [Map.put(hd(&1.lines), :gross_price, nan)])},
        {"charge basis",
         &%{&1 | charges: [%{amount: d("1.00"), basis_amount: nan, reason: "x"}]}},
        {"breakdown basis",
         &%{&1 | tax_breakdown: [%{category: "S", rate: d("20.00"), basis: nan}]}},
        {"a total", &put_in(&1.totals, %{prepaid: nan})}
      ]

      for {label, mutate} <- cases do
        hostile = mutate.(priced([{"50.00", "S", "20.00"}]))

        assert {:error, {:not_a_finite_amount, _path, _value}} = Invoice.totals(hostile),
               "#{label} was accepted"
      end
    end

    test "and stops build/2, which would otherwise emit it" do
      {nan, ""} = Decimal.parse("NaN")
      hostile = put_in(priced([{"50.00", "S", "20.00"}]).totals, %{grand_total: nan})

      assert {:error, {:not_a_finite_amount, [:totals, :grand_total], _}} = Facturx.build(hostile)
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

    test "a divergence path uses an index, like every other path" do
      inv = stripped(TestInvoice.maximal())

      wrong = %{
        inv
        | tax_breakdown: List.update_at(inv.tax_breakdown, 1, &Map.put(&1, :basis, d("1.00")))
      }

      assert {:error, {:totals_mismatch, diffs}} = Invoice.totals(wrong)

      # `[:tax_breakdown, 1, :basis]`, not `[:tax_breakdown, "S", :basis]`: the
      # Invoice.error typedoc says `[atom() | non_neg_integer()]`, and a caller
      # feeding these to get_in/put_in needs the index.
      assert Enum.any?(diffs, fn {path, _, _} -> path == [:tax_breakdown, 1, :basis] end),
             inspect(Enum.map(diffs, &elem(&1, 0)))
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
      assert Enum.any?(diffs, fn {path, _, _} -> path == [:lines, 0, :line_total] end)
    end

    test "refuses to add a non-finite amount rather than propagating it" do
      {nan, ""} = Decimal.parse("NaN")
      inv = stripped(TestInvoice.maximal())
      hostile = %{inv | lines: List.update_at(inv.lines, 0, &Map.put(&1, :net_price, nan))}

      assert {:error, {:not_a_finite_amount, [:lines, 0, :net_price], _}} =
               Invoice.totals(hostile)
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

  # An invoice reduced to its prices: `{net_price, vat_category, vat_rate}` per
  # line, and nothing derived.
  defp priced(specs) do
    lines =
      for {{price, category, rate}, i} <- Enum.with_index(specs, 1) do
        %{
          id: "#{i}",
          name: "Ligne #{i}",
          net_price: d(price),
          quantity: d("1"),
          unit: "C62",
          vat_category: category,
          vat_rate: d(rate)
        }
      end

    %{
      TestInvoice.maximal()
      | tax_currency: nil,
        allowances: [],
        charges: [],
        preceding_invoices: [],
        lines: lines,
        tax_breakdown: [],
        totals: %{}
    }
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
