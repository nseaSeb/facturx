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

  @typedoc "A postal address."
  @type address :: %{
          optional(:line_one) => String.t(),
          optional(:postcode) => String.t(),
          optional(:city) => String.t(),
          optional(:country) => String.t()
        }

  @typedoc "An optional trade contact."
  @type contact :: %{
          optional(:name) => String.t(),
          optional(:phone) => String.t(),
          optional(:email) => String.t()
        }

  @typedoc "A seller/buyer/ship-to party."
  @type party :: %{
          optional(:name) => String.t(),
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
          optional(:line_total) => Decimal.t()
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

  @typedoc "Document-level monetary summation."
  @type totals :: %{
          optional(:line_total) => Decimal.t(),
          optional(:tax_basis_total) => Decimal.t(),
          optional(:tax_total) => Decimal.t(),
          optional(:grand_total) => Decimal.t(),
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
          notes: [note()],
          seller: party() | nil,
          buyer: party() | nil,
          ship_to: party() | nil,
          delivery_date: Date.t() | nil,
          billing_period: period() | nil,
          preceding_invoices: [preceding_invoice()],
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
            # BG-1 — document-level notes (BT-22 content, BT-21 subject code)
            notes: [],
            seller: nil,
            buyer: nil,
            ship_to: nil,
            delivery_date: nil,
            # BG-14 — invoicing period. One of BT-72 / BG-14 / BG-26 is required by
            # BR-FX-EN-04 on anything but a down-payment invoice.
            billing_period: nil,
            # BG-3 — preceding invoice references, i.e. the down payment invoices a
            # final invoice nets off. Goes with the B4/S4/M4 frameworks.
            preceding_invoices: [],
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
