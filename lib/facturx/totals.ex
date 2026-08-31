defmodule Facturx.Totals do
  @moduledoc false
  # The EN 16931 document arithmetic, behind `Facturx.Invoice.totals/2`.
  #
  # Every rule here is one the schematron checks and the XSD does not, so the
  # test that matters is not a unit test of these functions but a document put in
  # front of Saxon — which is what test/facturx/validate_test.exs does.

  alias Facturx.Invoice

  # BR-CO-* work on two decimals. The bundled schematron writes the comparison as
  # `round(x * 100) div 100` in XPath, whose round() is half up, so that is the
  # mode here — a different one drifts by a cent on exactly the values a
  # rounding rule exists to pin.
  @scale 2
  @rounding :half_up

  @spec compute(Invoice.t(), keyword()) :: {:ok, Invoice.t()} | {:error, term()}
  def compute(%Invoice{} = inv, opts \\ []) do
    with :ok <- all_finite(inv) do
      lines = Enum.map(inv.lines, &derive_line/1)
      breakdown = breakdown(lines, inv)
      totals = document_totals(lines, breakdown, inv)

      computed = %{inv | lines: lines, tax_breakdown: breakdown, totals: totals}

      case divergences(inv, computed) do
        [] -> {:ok, computed}
        diffs -> reconcile(inv, computed, diffs, Keyword.get(opts, :overwrite, false))
      end
    end
  end

  defp reconcile(_inv, computed, _diffs, true), do: {:ok, computed}
  defp reconcile(_inv, _computed, diffs, false), do: {:error, {:totals_mismatch, diffs}}

  # --- refusing what cannot be added safely ---------------------------------

  # `Decimal` represents NaN and Infinity with a `:NaN` or `:inf` coefficient.
  # Adding those propagates rather than failing, and the result would be emitted
  # as `<ram:GrandTotalAmount>NaN</ram:GrandTotalAmount>`. This module is the
  # first place the library does arithmetic of its own, so it is the first place
  # that has to say no.
  defp all_finite(inv) do
    inv
    |> Map.from_struct()
    |> Invoice.amount_paths()
    |> Enum.find(fn {_path, value} -> not finite?(value) end)
    |> case do
      nil -> :ok
      {path, value} -> {:error, {:not_a_finite_amount, path, value}}
    end
  end

  defp finite?(%Decimal{coef: coef}), do: is_integer(coef)
  defp finite?(_other), do: true

  # --- lines -----------------------------------------------------------------

  # BT-131 = net price x quantity, less the line's allowances, plus its charges.
  #
  # Always derived, even when the line already carries a total. Keeping the
  # caller's figure would be worse than useless: the document totals are summed
  # from these, so one wrong line amount would propagate into BT-106, BT-109,
  # BT-112 and BT-115 without a single rule noticing. What the caller stated is
  # not lost — `divergences/2` compares against it and reports.
  defp derive_line(line), do: Map.put(line, :line_total, line_total(line))

  defp line_total(line) do
    net = line[:net_price] || Decimal.new(0)
    qty = line[:quantity] || Decimal.new(1)

    net
    |> Decimal.mult(qty)
    |> round2()
    |> Decimal.sub(sum(line[:allowances] || []))
    |> Decimal.add(sum(line[:charges] || []))
    |> round2()
  end

  # --- VAT breakdown ---------------------------------------------------------

  # One entry per {category, rate}. BT-116 is the sum of the line amounts in that
  # group, less the document allowances and plus the document charges that fall
  # under the same VAT — BR-S-08 and its siblings, one per category.
  #
  # An entry the caller already supplied is completed, never replaced: the
  # exemption reason and code (BT-120, BT-121) cannot be derived from amounts,
  # and category E is rejected without them (BR-E-10).
  defp breakdown(lines, inv) do
    entries =
      Enum.map(lines, &{vat_key(&1), &1[:line_total], &1[:vat_rate]}) ++
        Enum.map(inv.allowances, &{vat_key(&1), Decimal.negate(amount(&1)), &1[:vat_rate]}) ++
        Enum.map(inv.charges, &{vat_key(&1), amount(&1), &1[:vat_rate]})

    existing = Map.new(inv.tax_breakdown, &{tax_key(&1), &1})

    entries
    |> Enum.reject(fn {key, _amount, _rate} -> key == nil end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {{category, _normalised} = key, members} ->
      basis =
        members
        |> Enum.map(&elem(&1, 1))
        |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1 || Decimal.new(0)))
        |> round2()

      declared = Map.get(existing, key, %{})

      # The rate as somebody wrote it, not as the key normalised it: the
      # caller's own entry first, else the first member's. `20` and `20.00` are
      # one rate and must land in one entry, but the document should still say
      # what it was given.
      rate = declared[:rate] || elem(hd(members), 2)

      Map.merge(declared, %{
        type: "VAT",
        category: category,
        rate: rate,
        basis: basis,
        calculated: vat_amount(basis, rate)
      })
    end)
    # Deterministic order, so the same invoice always builds the same bytes.
    |> Enum.sort_by(&{&1[:category], Decimal.to_float(&1[:rate])})
  end

  # BT-117 = BT-116 x BT-119 / 100, rounded to the cent (BR-CO-17).
  defp vat_amount(basis, rate) do
    basis |> Decimal.mult(rate) |> Decimal.div(100) |> round2()
  end

  # The key groups on the rate's *value*. `Decimal.new("20")` and
  # `Decimal.new("20.00")` are numerically equal and different terms, and
  # `Enum.group_by/3` compares terms — so without normalising, an invoice
  # carrying both spellings of 20 % produced two `ram:ApplicableTradeTax` entries
  # for one category and rate, which the schematron rejects. The same slip made a
  # caller's own breakdown entry unmatchable, silently dropping its exemption
  # reason and failing BR-E-10.
  defp vat_key(entry), do: key(entry[:vat_category], entry[:vat_rate])
  defp tax_key(entry), do: key(entry[:category], entry[:rate])

  defp key(nil, _rate), do: nil
  defp key(_category, nil), do: nil
  defp key(category, rate), do: {category, Decimal.normalize(rate)}

  # --- document totals -------------------------------------------------------

  defp document_totals(lines, breakdown, inv) do
    given = inv.totals

    line_total = lines |> Enum.map(& &1[:line_total]) |> sum_list()
    allowance_total = sum(inv.allowances)
    charge_total = sum(inv.charges)

    # BR-CO-13
    tax_basis =
      line_total |> Decimal.sub(allowance_total) |> Decimal.add(charge_total) |> round2()

    # BR-CO-14
    tax_total = breakdown |> Enum.map(& &1[:calculated]) |> sum_list()

    # BR-CO-15
    grand_total = tax_basis |> Decimal.add(tax_total) |> round2()

    # BR-CO-16 — BT-113 and BT-114 are the caller's to state; neither can be
    # derived, and both default to nothing rather than to zero.
    prepaid = given[:prepaid] || Decimal.new(0)
    rounding = given[:rounding] || Decimal.new(0)
    due = grand_total |> Decimal.sub(prepaid) |> Decimal.add(rounding) |> round2()

    given
    |> Map.merge(%{
      line_total: line_total,
      allowance_total: allowance_total,
      charge_total: charge_total,
      tax_basis_total: tax_basis,
      tax_total: tax_total,
      grand_total: grand_total,
      due_payable: due
    })
    # BT-107 and BT-108 are only emitted when there is something to say.
    |> drop_zero(:allowance_total, inv.allowances)
    |> drop_zero(:charge_total, inv.charges)
  end

  defp drop_zero(totals, _key, [_ | _]), do: totals
  defp drop_zero(totals, key, []), do: Map.delete(totals, key)

  # --- reporting what the caller had that we disagree with -------------------

  @reported ~w(line_total allowance_total charge_total tax_basis_total tax_total
               grand_total due_payable)a

  defp divergences(inv, computed) do
    totals =
      for key <- @reported,
          given = inv.totals[key],
          given != nil,
          not Decimal.equal?(given, computed.totals[key] || Decimal.new(0)),
          do: {[:totals, key], given, computed.totals[key]}

    lines =
      for {{given, derived}, i} <- Enum.with_index(Enum.zip(inv.lines, computed.lines)),
          given[:line_total] != nil,
          not Decimal.equal?(given[:line_total], derived[:line_total]),
          do: {[:lines, i, :line_total], given[:line_total], derived[:line_total]}

    taxes =
      for given <- inv.tax_breakdown,
          key = tax_key(given),
          key != nil,
          match = Enum.find(computed.tax_breakdown, &(tax_key(&1) == key)),
          match != nil,
          field <- [:basis, :calculated],
          given[field] != nil,
          not Decimal.equal?(given[field], match[field]),
          do: {[:tax_breakdown, elem(key, 0), field], given[field], match[field]}

    totals ++ lines ++ taxes
  end

  # --- helpers ---------------------------------------------------------------

  defp sum(entries), do: entries |> Enum.map(&amount/1) |> sum_list()

  defp sum_list(amounts) do
    amounts
    |> Enum.reduce(Decimal.new(0), fn a, acc -> Decimal.add(acc, a || Decimal.new(0)) end)
    |> round2()
  end

  defp amount(entry), do: entry[:amount] || Decimal.new(0)

  defp round2(d), do: Decimal.round(d, @scale, @rounding)
end
