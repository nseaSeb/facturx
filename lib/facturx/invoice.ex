defmodule Facturx.Invoice do
  @moduledoc """
  In-memory representation of an invoice, mapped to/from CII XML by
  `Facturx.CII`.

  Monetary amounts and quantities are `Decimal` (never floats). Nested parties,
  lines, tax breakdown and totals use plain maps with the shapes documented
  below. This models the EN 16931 essentials — enough for a valid CII document —
  not every optional business term.

  Two fields exist for the French e-invoicing mandate and are `nil` (unemitted)
  by default, so cross-border EN 16931 use is unaffected:
  `:business_process` (BT-23) and `:tax_due_date_type_code` (BT-8). See
  `docs/reference/reforme-fr.md`.
  """

  @typedoc """
  A postal address.

  `:country` is the only part CII requires once an address is present. Note the
  wire order, which is not the intuitive one: postcode, then the three lines, then
  the city, the country, and finally the subdivision.
  """
  @type address :: %{
          optional(:line_one) => String.t(),
          optional(:line_two) => String.t(),
          optional(:line_three) => String.t(),
          optional(:postcode) => String.t(),
          optional(:city) => String.t(),
          optional(:country) => String.t(),
          optional(:country_subdivision) => String.t()
        }

  @typedoc "An optional trade contact."
  @type contact :: %{
          optional(:name) => String.t(),
          optional(:phone) => String.t(),
          optional(:email) => String.t()
        }

  @typedoc """
  A seller / buyer / ship-to / tax-representative party.

  `:legal_id` is the SIREN (BT-30 / BT-47) with `:legal_scheme` defaulting to
  `"0002"`. `:global_id` is BT-29d, the SIREN of a French *assujetti unique* (VAT
  group), whose scheme is `"0231"` — a different identifier answering a different
  question, so both may appear. `:vat` is the VAT identifier (BT-31 / BT-48 /
  BT-63).

  Note that the two scheme defaults are written into the XML, so parsing a document
  built without them returns them anyway: `parse(build(%{legal_id: "…"}))` comes
  back carrying `legal_scheme: "0002"`. The document is unchanged, the struct is
  normalised — the same already applies to a line's `:unit` (`"C62"`) and a tax
  entry's `:type` (`"VAT"`).
  """
  @type party :: %{
          optional(:name) => String.t(),
          optional(:global_id) => String.t(),
          optional(:global_scheme) => String.t(),
          optional(:legal_id) => String.t(),
          optional(:legal_scheme) => String.t(),
          optional(:vat) => String.t(),
          optional(:address) => address(),
          optional(:contact) => contact() | nil
        }

  @typedoc """
  An invoice line.

  `:gross_price` (BT-148) is the price before any discount, `:price_discount`
  (BT-147) the discount itself; EN 16931 expects
  `net_price = gross_price - price_discount`, which is not checked here.
  `:gross_price` must be set for `:price_discount` to be emitted, the CII price
  container requiring an amount.

  `:billing_period` is BG-26, the period this line covers — same shape as the
  document-level `t:period/0`. It is one of the three things `BR-FX-EN-04` lists,
  but note that rule only fires on DE-to-DE invoices and its assertion is a
  conjunction: a line period alone does not satisfy it.

  `:notes` is BT-127, taking the same `t:note/0` shape as the document-level
  field. What you may put in it depends on the profile, and `Facturx.CII.build/2`
  enforces that rather than trusting the caller:

    * `:en16931` — **one** note, content only. The profile caps `IncludedNote` at
      a single occurrence and has no room for a subject code there, so extra
      notes and any `:subject_code` are dropped.
    * `:extended` — as many notes as you like, each free to carry a
      `:subject_code`. That code is `EXT-FR-FE-183` (BT-127-00 for the repeated
      container), a French extension on the target trajectory.

  Emitting either of those in an EN 16931 document gets it rejected, which is why
  the profile decides and not the field.

  `:preceding_invoice` is `EXT-FR-FE-BG-06`, the same `t:preceding_invoice/0`
  shape as the document-level list but **singular**: the CII element is `0..1`
  here (`minOccurs="0"`, no `maxOccurs`). It is what a line points at to net off
  a down payment invoiced earlier, and like the subject code above it only
  emits in `:extended`.

  `:ship_to` and `:delivery_date` are the same, for a line delivered elsewhere or
  on another date than the document says — `EXT-FR-FE-BG-10` and
  `EXT-FR-FE-BG-11`. Same shapes as their document-level counterparts, both
  `0..1`, both `:extended` only. Multi-delivery is what they exist for.
  """
  @type line :: %{
          optional(:id) => String.t(),
          optional(:name) => String.t(),
          optional(:net_price) => Decimal.t(),
          optional(:gross_price) => Decimal.t(),
          optional(:price_discount) => Decimal.t(),
          optional(:quantity) => Decimal.t(),
          optional(:unit) => String.t(),
          optional(:vat_category) => String.t(),
          optional(:vat_rate) => Decimal.t(),
          optional(:line_total) => Decimal.t(),
          optional(:allowances) => [allowance_charge()],
          optional(:charges) => [allowance_charge()],
          optional(:billing_period) => period(),
          optional(:notes) => [note()],
          optional(:preceding_invoice) => preceding_invoice(),
          optional(:ship_to) => party(),
          optional(:delivery_date) => Date.t()
        }

  @typedoc """
  A document- or line-level allowance (BG-20 / BG-27) or charge (BG-21 / BG-28).

  Both map to the same CII element, told apart by `ChargeIndicator`; which list you
  put the entry in decides that, so there is no flag to get wrong.

  `:amount` is the amount itself (BT-92 / BT-99, and the only required field),
  `:basis_amount` what a percentage applies to (BT-93 / BT-100), `:percent` that
  percentage (BT-94 / BT-101), `:vat_category` and `:vat_rate` the VAT it falls
  under (BT-95/BT-96 / BT-102/BT-103), `:reason` and `:reason_code` why
  (BT-97/BT-98 / BT-104/BT-105).

  > #### Two rules only the schematron enforces {: .warning}
  >
  > **Every entry needs a `:reason` or a `:reason_code`** — `BR-33`/`BR-38` at
  > document level, `BR-42`/`BR-44` on a line. An entry with just an amount is
  > structurally valid and gets the invoice rejected.
  >
  > **Document-level entries must match `:totals`** (`:allowance_total`,
  > `:charge_total`), which in turn feed `:tax_basis_total` — `BR-CO-11`,
  > `BR-CO-12`, `BR-CO-13`. None of that arithmetic is computed here, and the XSD
  > does not check any of it.
  """
  @type allowance_charge :: %{
          optional(:amount) => Decimal.t(),
          optional(:basis_amount) => Decimal.t(),
          optional(:percent) => Decimal.t(),
          optional(:vat_category) => String.t(),
          optional(:vat_rate) => Decimal.t(),
          optional(:reason) => String.t(),
          optional(:reason_code) => String.t()
        }

  @typedoc """
  A payment means (BG-16).

  `:type_code` is BT-81, from UNTDID 4461 — commonly `"30"` (credit transfer),
  `"58"` (SEPA credit transfer), `"59"` (SEPA direct debit), `"48"` (card), `"20"`
  (cheque), `"10"` (cash). That list is **not** validated here: it holds 84 values
  and the bundled schematron already checks it, so a copy in Elixir would only be
  something to drift. Contrast BT-8, where three values and a real trap justified
  inlining.

  The account being credited is `:iban` (BT-84), `:account_name` (BT-85) or
  `:account_id` (BT-84 in its non-IBAN form), its institution `:bic` (BT-86).
  `:payer_iban` (BT-91) is the account debited for a direct debit, and
  `:card_id` / `:cardholder_name` (BT-87 / BT-88) cover a card payment.

  > #### Card numbers {: .warning}
  >
  > `:card_id` must be **at most 10 characters** — rule `BR-51`, which enforces the
  > PCI standard of showing at most the first 6 and last 4 digits. A masked
  > 16-character string such as `"************1234"` is *too long* and gets the
  > invoice rejected; pass `"401288" <> "1881"` or just the last digits. The XSD
  > accepts any length, so only the schematron catches this.
  """
  @type payment_means :: %{
          optional(:type_code) => String.t(),
          optional(:information) => String.t(),
          optional(:iban) => String.t(),
          optional(:account_name) => String.t(),
          optional(:account_id) => String.t(),
          optional(:bic) => String.t(),
          optional(:payer_iban) => String.t(),
          optional(:card_id) => String.t(),
          optional(:cardholder_name) => String.t()
        }

  @typedoc """
  A reference to a preceding invoice (BG-3).

  What a final invoice points at to net off the down payments already invoiced.
  Required in that case by the French mandate, whose invoicing framework codes
  `B4`/`S4`/`M4` mean exactly "final invoice after a down payment".

  `:number` is BT-25, `:issue_date` BT-26. Rule `G1.60` forbids pairing a
  `B4`/`S4`/`M4` framework with a down-payment `:type_code` (`386`, `500`, `503`);
  `Facturx.CII.build/2` enforces that when `:validate_business_process` is on.
  """
  @type preceding_invoice :: %{
          optional(:number) => String.t(),
          optional(:issue_date) => Date.t()
        }

  @typedoc """
  A document-level note (BG-1).

  `:subject_code` is BT-21, from UNTDID 4451. Note that CII orders the content
  before the code, unlike the business-term numbering.
  """
  @type note :: %{
          optional(:content) => String.t(),
          optional(:subject_code) => String.t()
        }

  @typedoc """
  An invoicing period (BG-14).

  `BR-29` requires the end to be on or after the start. That rule is flagged
  `warning` in the bundled schematron, so an inverted period yields
  `{:ok, {:valid_with_warnings, …}}` rather than an error — it is not checked here.
  """
  @type period :: %{
          optional(:start_date) => Date.t(),
          optional(:end_date) => Date.t()
        }

  @typedoc """
  A VAT breakdown entry (one per rate/category).

  `:due_date_type_code` is BT-8 for this entry. It overrides the document-level
  `:tax_due_date_type_code` and only exists because EN 16931 allows the code to
  differ per entry; French rule S1.13 forbids that, so domestic invoices should
  use the document-level field instead.

  `:exemption_reason` (BT-120) is free text and `:exemption_reason_code` (BT-121) a
  code from the EN 16931 VATEX list; both apply to categories such as `E`, `AE`,
  `K` or `G`.
  """
  @type tax :: %{
          optional(:type) => String.t(),
          optional(:category) => String.t(),
          optional(:rate) => Decimal.t(),
          optional(:basis) => Decimal.t(),
          optional(:calculated) => Decimal.t(),
          optional(:due_date_type_code) => String.t(),
          optional(:exemption_reason) => String.t(),
          optional(:exemption_reason_code) => String.t()
        }

  @typedoc """
  Document-level monetary summation.

  `:prepaid` (BT-113) is what has already been paid — the down payments a final
  invoice nets off, so it goes with `:preceding_invoices`. `:rounding` is BT-114.

  `:tax_total_in_tax_currency` is BT-111, the VAT total restated in the accounting
  currency. It is the **second** `TaxTotalAmount` occurrence rather than a separate
  element, and requires `:tax_currency` on the invoice (`BR-53`).

  `:tax_currency` must **differ** from `:currency`: the schematron tells BT-110 and
  BT-111 apart by their `currencyID`, so two identical ones are indistinguishable
  and get rejected — which also cascades into `BR-CO-15`.

  Beware the wire order, which does not follow the BT numbering: CII emits
  `ChargeTotalAmount` **before** `AllowanceTotalAmount`.
  """
  @type totals :: %{
          optional(:line_total) => Decimal.t(),
          optional(:charge_total) => Decimal.t(),
          optional(:allowance_total) => Decimal.t(),
          optional(:tax_basis_total) => Decimal.t(),
          optional(:tax_total) => Decimal.t(),
          optional(:tax_total_in_tax_currency) => Decimal.t(),
          optional(:rounding) => Decimal.t(),
          optional(:grand_total) => Decimal.t(),
          optional(:prepaid) => Decimal.t(),
          optional(:due_payable) => Decimal.t()
        }

  @type t :: %__MODULE__{
          profile: Facturx.profile(),
          business_process: String.t() | nil,
          number: String.t() | nil,
          type_code: String.t(),
          issue_date: Date.t() | nil,
          due_date: Date.t() | nil,
          currency: String.t(),
          tax_currency: String.t() | nil,
          notes: [note()],
          seller: party() | nil,
          buyer: party() | nil,
          tax_representative: party() | nil,
          ship_to: party() | nil,
          delivery_date: Date.t() | nil,
          billing_period: period() | nil,
          preceding_invoices: [preceding_invoice()],
          payment_means: [payment_means()],
          allowances: [allowance_charge()],
          charges: [allowance_charge()],
          lines: [line()],
          tax_breakdown: [tax()],
          tax_due_date_type_code: String.t() | nil,
          totals: totals()
        }

  defstruct profile: :en16931,
            # BT-23 "cadre de facturation" — one of `Facturx.business_processes/0`
            # (rule G1.02). nil = not emitted.
            business_process: nil,
            number: nil,
            # 380 = commercial invoice (UNTDID 1001)
            type_code: "380",
            issue_date: nil,
            due_date: nil,
            currency: "EUR",
            # BT-6 — VAT accounting currency, required alongside BT-111 (BR-53)
            tax_currency: nil,
            # BG-1 — document-level notes (BT-22 content, BT-21 subject code)
            notes: [],
            seller: nil,
            buyer: nil,
            # BG-11 — seller's tax representative (its BT-63 VAT id is the point)
            tax_representative: nil,
            ship_to: nil,
            delivery_date: nil,
            # BG-14 — invoicing period.
            billing_period: nil,
            # BG-3 — preceding invoice references, i.e. the down payment invoices a
            # final invoice nets off. Goes with the B4/S4/M4 frameworks.
            preceding_invoices: [],
            # BG-16 — how the invoice is to be paid (IBAN, BIC, direct debit, card)
            payment_means: [],
            # BG-20 / BG-21 — document-level allowances and charges. Keep :totals
            # in step (:allowance_total / :charge_total), or BR-CO-11/12 reject it.
            allowances: [],
            charges: [],
            lines: [],
            tax_breakdown: [],
            # BT-8 (UNTDID 2475, one of `Facturx.vat_point_date_codes/0`) — VAT
            # point date code, i.e. the "TVA sur les débits" option.
            #
            # Convenience for the French case: BT-8 lives per VAT breakdown entry
            # on the wire, but rule S1.13 requires one value for the whole
            # invoice, so this is applied to every ram:ApplicableTradeTax that
            # does not carry its own :due_date_type_code.
            #
            # With an empty :tax_breakdown there is nowhere to put it, so it is
            # not emitted; `build/2` returns {:error, {:vat_point_date_unemittable,
            # code}} rather than dropping it silently.
            tax_due_date_type_code: nil,
            totals: %{}

  # --- construction ----------------------------------------------------------

  @typedoc """
  What `new/1` rejected, as `{path, reason}`.

  The path locates the value — `[:number]`, `[:lines, 2, :net_price]` — so an
  error names the field rather than the document.
  """
  @type error :: {[atom() | non_neg_integer()], atom()}

  @doc """
  Build an invoice from a plain map, validating and coercing as it goes.

  Optional: `Facturx.CII.build/2` takes a bare struct or map exactly as before,
  and nothing here is required to use the library. What `new/1` adds is a place
  to fail early, on the caller's data rather than on a schematron report.

  Returns **every** problem it found, not the first:

      iex> Facturx.Invoice.new(%{currency: "EURO", lines: [%{net_price: 1.5}]})
      {:error, [{[:number], :required}, {[:issue_date], :required},
                {[:seller], :required}, {[:buyer], :required},
                {[:currency], :not_a_currency_code},
                {[:lines, 0, :net_price], :float}]}

  ## Amounts

  Integers and strings are coerced to `Decimal`; a `Decimal` passes through.

  **Floats are refused.** `Decimal.from_float/1` is faithful — `19.99` stays
  `19.99` — so the refusal is not about that conversion. It is that a float
  reaching this function has usually been through float arithmetic already, and
  `0.1 + 0.2` is `0.30000000000000004` before anything here can see it. Accepting
  it would record the drift faithfully and call it validated. Pass a string, or a
  `Decimal`. See `docs/adr/0001-perimetre-et-architecture.md`.

  Non-finite decimals are refused for the same reason: `Decimal.parse/1` accepts
  `"NaN"` and `"Infinity"`, and neither is a monetary amount.

  ## What is required

  `:number` (BT-1), `:issue_date` (BT-2), `:type_code` (BT-3), `:currency`
  (BT-5), and a `:seller` and `:buyer` each carrying a `:name`. Everything else
  is optional here — including the totals, which `totals/2` derives.
  """
  @spec new(map()) :: {:ok, t()} | {:error, [error()]}
  def new(attrs) when is_map(attrs) do
    attrs = Map.delete(attrs, :__struct__)

    case coerce_amounts(attrs) ++ required(attrs) ++ shapes(attrs) do
      [] -> {:ok, struct(__MODULE__, coerced(attrs))}
      errors -> {:error, Enum.sort(errors)}
    end
  end

  @doc """
  Derive the line amounts, the VAT breakdown and the document totals.

  Implements `BR-CO-10` through `BR-CO-17` and the per-category basis rules
  (`BR-S-08` and its siblings): each line's net amount (BT-131), one breakdown
  entry per VAT category and rate with its taxable and tax amounts (BT-116,
  BT-117), then BT-106 to BT-115.

  Values the caller already supplied are **kept**, not replaced. Where a supplied
  value disagrees with the derived one, that is reported rather than silently
  resolved:

      {:error, {:totals_mismatch, [{[:totals, :grand_total], given, computed}]}}

  Pass `overwrite: true` to take the computed figures regardless. A disagreement
  is information — it usually means the caller and this module read the invoice
  differently — so discarding it is a decision, not a default.

  Two things are never derived, because nothing in the invoice determines them:
  `:prepaid` (BT-113) and `:rounding` (BT-114). Both are read if present and
  treated as zero if not. `:tax_total_in_tax_currency` (BT-111) is not derived
  either — it needs an exchange rate this library does not have.

  Exemption reasons are preserved: a breakdown entry the caller supplied is
  completed, never replaced, since BT-120 and BT-121 cannot be derived from
  amounts and category `E` is rejected without them (`BR-E-10`).
  """
  @spec totals(t(), keyword()) :: {:ok, t()} | {:error, term()}
  defdelegate totals(invoice, opts \\ []), to: Facturx.Totals, as: :compute

  # --- validation ------------------------------------------------------------

  @required [:number, :issue_date, :type_code, :currency]

  defp required(attrs) do
    for field <- @required, blank?(Map.get(attrs, field)), do: {[field], :required}
  end

  defp shapes(attrs) do
    party(attrs, :seller) ++
      party(attrs, :buyer) ++
      currency(attrs) ++
      date(attrs, :issue_date) ++
      date(attrs, :due_date)
  end

  defp party(attrs, key) do
    case Map.get(attrs, key) do
      nil -> [{[key], :required}]
      p when is_map(p) -> if blank?(p[:name]), do: [{[key, :name], :required}], else: []
      _ -> [{[key], :not_a_party}]
    end
  end

  defp currency(attrs) do
    case Map.get(attrs, :currency) do
      nil ->
        []

      <<_::binary-size(3)>> = c ->
        if c == String.upcase(c), do: [], else: [{[:currency], :not_a_currency_code}]

      _ ->
        [{[:currency], :not_a_currency_code}]
    end
  end

  defp date(attrs, key) do
    case Map.get(attrs, key) do
      nil -> []
      %Date{} -> []
      _ -> [{[key], :not_a_date}]
    end
  end

  defp blank?(value), do: value in [nil, ""]

  # --- amount coercion -------------------------------------------------------

  # Every path at which the struct expects a Decimal.
  @totals_amounts ~w(line_total charge_total allowance_total tax_basis_total tax_total
                     tax_total_in_tax_currency rounding grand_total prepaid due_payable)a
  @line_amounts ~w(net_price gross_price price_discount quantity line_total vat_rate)a
  @charge_amounts ~w(amount basis_amount percent vat_rate)a
  @tax_amounts ~w(rate basis calculated)a

  # Both walks enumerate the same `paths/1`, which is what stops them disagreeing
  # about which fields are amounts.
  defp coerce_amounts(attrs) do
    Enum.flat_map(paths(attrs), fn {path, value} ->
      case to_decimal(value) do
        {:ok, _} -> []
        {:error, reason} -> [{path, reason}]
      end
    end)
  end

  defp coerced(attrs) do
    Enum.reduce(paths(attrs), attrs, fn {path, value}, acc ->
      case to_decimal(value) do
        {:ok, d} -> put_in_path(acc, path, d)
        {:error, _} -> acc
      end
    end)
  end

  defp paths(attrs) do
    totals = for k <- @totals_amounts, v = get_in_map(attrs, [:totals, k]), do: {[:totals, k], v}

    lines =
      for {line, i} <- Enum.with_index(Map.get(attrs, :lines) || []),
          entry <- line_paths(line, i),
          do: entry

    charges =
      for {group, key} <- [{:allowances, :allowances}, {:charges, :charges}],
          {ac, i} <- Enum.with_index(Map.get(attrs, group) || []),
          k <- @charge_amounts,
          v = ac[k],
          do: {[key, i, k], v}

    taxes =
      for {tax, i} <- Enum.with_index(Map.get(attrs, :tax_breakdown) || []),
          k <- @tax_amounts,
          v = tax[k],
          do: {[:tax_breakdown, i, k], v}

    totals ++ lines ++ charges ++ taxes
  end

  defp line_paths(line, i) do
    own = for k <- @line_amounts, v = line[k], do: {[:lines, i, k], v}

    nested =
      for group <- [:allowances, :charges],
          {ac, j} <- Enum.with_index(line[group] || []),
          k <- @charge_amounts,
          v = ac[k],
          do: {[:lines, i, group, j, k], v}

    own ++ nested
  end

  defp get_in_map(attrs, [a, b]) do
    case Map.get(attrs, a) do
      m when is_map(m) -> Map.get(m, b)
      _ -> nil
    end
  end

  defp put_in_path(map, [key], value), do: Map.put(map, key, value)

  defp put_in_path(map, [key | rest], value) when is_integer(key) do
    List.update_at(map, key, &put_in_path(&1, rest, value))
  end

  defp put_in_path(map, [key | rest], value) do
    Map.put(map, key, put_in_path(Map.get(map, key), rest, value))
  end

  defp to_decimal(%Decimal{coef: coef} = d) when is_integer(coef), do: {:ok, d}
  defp to_decimal(%Decimal{}), do: {:error, :not_a_finite_amount}
  defp to_decimal(n) when is_integer(n), do: {:ok, Decimal.new(n)}
  defp to_decimal(f) when is_float(f), do: {:error, :float}

  defp to_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {%Decimal{coef: coef} = d, ""} when is_integer(coef) -> {:ok, d}
      _ -> {:error, :not_a_number}
    end
  end

  defp to_decimal(_other), do: {:error, :not_a_number}
end
