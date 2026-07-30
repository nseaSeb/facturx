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

  `:note` is BT-127, a plain string. Two differences from the document-level
  `:notes`: CII allows only **one** per line, and the EN 16931 profile does **not**
  allow a subject code there — that is `EXT-FR-FE-183`, a French extension on the
  target trajectory. Emitting one makes the schematron reject the invoice, so there
  is no field for it.
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
          optional(:note) => String.t()
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
end
