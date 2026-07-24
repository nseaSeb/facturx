defmodule Facturx.Invoice do
  @moduledoc """
  In-memory representation of an invoice, mapped to/from CII XML by
  `Facturx.CII`.

  Monetary amounts and quantities are `Decimal` (never floats). Nested parties,
  lines, tax breakdown and totals use plain maps with the shapes documented
  below. This models the EN 16931 essentials — enough for a valid CII document —
  not every optional business term.
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

  @typedoc "An invoice line."
  @type line :: %{
          optional(:id) => String.t(),
          optional(:name) => String.t(),
          optional(:net_price) => Decimal.t(),
          optional(:quantity) => Decimal.t(),
          optional(:unit) => String.t(),
          optional(:vat_category) => String.t(),
          optional(:vat_rate) => Decimal.t(),
          optional(:line_total) => Decimal.t()
        }

  @typedoc "A VAT breakdown entry (one per rate/category)."
  @type tax :: %{
          optional(:type) => String.t(),
          optional(:category) => String.t(),
          optional(:rate) => Decimal.t(),
          optional(:basis) => Decimal.t(),
          optional(:calculated) => Decimal.t()
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
          number: String.t() | nil,
          type_code: String.t(),
          issue_date: Date.t() | nil,
          due_date: Date.t() | nil,
          currency: String.t(),
          seller: party() | nil,
          buyer: party() | nil,
          ship_to: party() | nil,
          delivery_date: Date.t() | nil,
          lines: [line()],
          tax_breakdown: [tax()],
          totals: totals()
        }

  defstruct profile: :en16931,
            number: nil,
            # 380 = commercial invoice (UNTDID 1001)
            type_code: "380",
            issue_date: nil,
            due_date: nil,
            currency: "EUR",
            seller: nil,
            buyer: nil,
            ship_to: nil,
            delivery_date: nil,
            lines: [],
            tax_breakdown: [],
            totals: %{}
end
