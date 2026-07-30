defmodule Facturx.CII do
  @moduledoc """
  Cross Industry Invoice (CII) XML — build and parse (pure Elixir, via Saxy).

  Maps between `Facturx.Invoice` and the EN 16931 CII vocabulary
  (`rsm:CrossIndustryInvoice`, `ram:*`, `udt:*`). Element order follows the CII
  schema so the output validates.
  """

  alias Facturx.Invoice

  @ns [
    {"xmlns:rsm", "urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"},
    {"xmlns:ram",
     "urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"},
    {"xmlns:udt", "urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100"},
    {"xmlns:qdt", "urn:un:unece:uncefact:data:standard:QualifiedDataType:100"}
  ]

  # ==========================================================================
  # build: Invoice -> CII XML
  # ==========================================================================

  @doc """
  Build the CII XML for `invoice`.

  ## Options

    * `:profile` — overrides `invoice.profile`.

    * `:validate_business_process` — check BT-23 (`:business_process`) against
      `Facturx.business_processes/0`, returning
      `{:error, {:invalid_business_process, code}}`. **Defaults to `false`**,
      because that list is the *French* one whereas BT-23 is an EN 16931 term
      whose values are not restricted (Peppol uses `urn:fdc:peppol.eu:…`, Chorus
      Pro used `A1`/`A2`).

    * `:validate_vat_point_date` — check BT-8 (`:tax_due_date_type_code`, or a
      per-entry `:due_date_type_code`) against `Facturx.vat_point_date_codes/0`,
      returning `{:error, {:invalid_vat_point_date_code, code}}`. **Defaults to
      `true`**, the other way round, because this list is imposed by EN 16931
      itself (rule BR-CL-06): a value outside it is invalid in CII whatever the
      jurisdiction.

  Both accept a per-call value or a default from the application environment, the
  option winning:

      config :facturx, Facturx.CII, validate_business_process: true

  ## Rebuilding third-party documents

  `parse/1` validates nothing, so a document you received may carry codes these
  checks reject — a BT-8 of `3`/`35`/`432` (the UBL values) is common in
  UBL→CII conversions. `build/2` on such a struct fails by design; pass
  `validate_vat_point_date: false` to reproduce it as-is.

  ## Notes

  `nil` and `""` are both treated as absent and emit no element. A
  `:tax_due_date_type_code` with an empty `:tax_breakdown` has nowhere to go and
  returns `{:error, {:vat_point_date_unemittable, code}}` rather than being
  dropped silently.
  """
  @spec build(Invoice.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def build(invoice, opts \\ [])

  def build(%Invoice{} = inv, opts) do
    profile = Keyword.get(opts, :profile, inv.profile || :en16931)

    with :ok <- check_business_process(inv.business_process, validate_bp?(opts)),
         :ok <- check_vat_point_dates(inv, flag?(opts, :validate_vat_point_date, true)) do
      doc =
        {"rsm:CrossIndustryInvoice", @ns,
         [
           context(inv, profile),
           document(inv),
           transaction(inv)
         ]}

      {:ok, ~s(<?xml version="1.0" encoding="UTF-8"?>) <> Saxy.encode!(doc)}
    end
  rescue
    e -> {:error, e}
  end

  defp validate_bp?(opts), do: flag?(opts, :validate_business_process, false)

  # Per call, else `config :facturx, Facturx.CII, ...`, else `default`. Read for
  # truthiness rather than matched literally: these flags are often forwarded from
  # a caller's own config, where they may well arrive as nil.
  defp flag?(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        !!value

      :error ->
        case Keyword.fetch(Application.get_env(:facturx, __MODULE__, []), key) do
          {:ok, value} -> !!value
          :error -> default
        end
    end
  end

  # "" is treated as absent throughout: it is never a meaningful code, and
  # emitting an empty element would lose it on the way back in.
  defp blank?(value), do: value in [nil, ""]

  defp check_business_process(code, _check?) when code in [nil, ""], do: :ok

  defp check_business_process(code, check?) when is_binary(code) do
    if not check? or code in Facturx.business_processes() do
      :ok
    else
      {:error, {:invalid_business_process, code}}
    end
  end

  defp check_business_process(code, _check?), do: {:error, {:invalid_business_process, code}}

  # BT-8 lives per VAT breakdown entry, so every emitted code is checked — the
  # document-level one and any per-entry override.
  defp check_vat_point_dates(inv, check?) do
    codes = Enum.map(inv.tax_breakdown, &(&1[:due_date_type_code] || inv.tax_due_date_type_code))

    with :ok <- Enum.reduce_while(codes, :ok, &reduce_vat_point_date(&1, &2, check?)) do
      # A document-level code with no breakdown to carry it would be silently
      # dropped; say so instead.
      if not blank?(inv.tax_due_date_type_code) and inv.tax_breakdown == [] do
        {:error, {:vat_point_date_unemittable, inv.tax_due_date_type_code}}
      else
        :ok
      end
    end
  end

  defp reduce_vat_point_date(code, _acc, check?) do
    case check_vat_point_date(code, check?) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp check_vat_point_date(code, _check?) when code in [nil, ""], do: :ok

  defp check_vat_point_date(code, check?) when is_binary(code) do
    if not check? or code in Facturx.vat_point_date_codes() do
      :ok
    else
      {:error, {:invalid_vat_point_date_code, code}}
    end
  end

  defp check_vat_point_date(code, _check?), do: {:error, {:invalid_vat_point_date_code, code}}

  # BusinessProcess (BT-23) must precede Guideline (BT-24) per ExchangedDocumentContextType.
  defp context(inv, profile) do
    e("rsm:ExchangedDocumentContext", [
      wrap(
        "ram:BusinessProcessSpecifiedDocumentContextParameter",
        t("ram:ID", inv.business_process)
      ),
      e("ram:GuidelineSpecifiedDocumentContextParameter", [
        t("ram:ID", profile_urn(profile))
      ])
    ])
  end

  defp document(inv) do
    e("rsm:ExchangedDocument", [
      t("ram:ID", inv.number),
      t("ram:TypeCode", inv.type_code),
      date_el("ram:IssueDateTime", inv.issue_date),
      Enum.map(inv.notes, &note/1)
    ])
  end

  # NoteType orders Content before SubjectCode — the reverse of the BT numbering
  # (BT-22 then BT-21).
  defp note(n) do
    e("ram:IncludedNote", [
      t("ram:Content", n[:content]),
      t("ram:SubjectCode", n[:subject_code])
    ])
  end

  defp transaction(inv) do
    e(
      "rsm:SupplyChainTradeTransaction",
      Enum.map(inv.lines, &line_item/1) ++
        [
          header_agreement(inv),
          header_delivery(inv),
          header_settlement(inv)
        ]
    )
  end

  defp line_item(line) do
    e("ram:IncludedSupplyChainTradeLineItem", [
      e("ram:AssociatedDocumentLineDocument", [t("ram:LineID", line[:id])]),
      e("ram:SpecifiedTradeProduct", [t("ram:Name", line[:name])]),
      e("ram:SpecifiedLineTradeAgreement", [
        # GrossPrice precedes NetPrice in LineTradeAgreementType.
        gross_price(line),
        e("ram:NetPriceProductTradePrice", [amount("ram:ChargeAmount", line[:net_price])])
      ]),
      e("ram:SpecifiedLineTradeDelivery", [
        qty("ram:BilledQuantity", line[:quantity], line[:unit])
      ]),
      e("ram:SpecifiedLineTradeSettlement", [
        e("ram:ApplicableTradeTax", [
          # Line-level trade tax is always VAT under EN 16931.
          t("ram:TypeCode", "VAT"),
          t("ram:CategoryCode", line[:vat_category]),
          t("ram:RateApplicablePercent", decimal(line[:vat_rate]))
        ]),
        e("ram:SpecifiedTradeSettlementLineMonetarySummation", [
          amount("ram:LineTotalAmount", line[:line_total])
        ])
      ])
    ])
  end

  # BT-148 / BT-147. TradePriceType requires ChargeAmount, so the container is only
  # emitted when a gross price is given — a lone discount would be invalid.
  defp gross_price(line) do
    case line[:gross_price] do
      nil ->
        nil

      gross ->
        e("ram:GrossPriceProductTradePrice", [
          amount("ram:ChargeAmount", gross),
          price_discount(line[:price_discount])
        ])
    end
  end

  defp price_discount(nil), do: nil

  defp price_discount(value) do
    e("ram:AppliedTradeAllowanceCharge", [
      # false = allowance (a discount) rather than a charge.
      wrap("ram:ChargeIndicator", t("udt:Indicator", "false")),
      amount("ram:ActualAmount", value)
    ])
  end

  defp header_agreement(inv) do
    e("ram:ApplicableHeaderTradeAgreement", [
      party("ram:SellerTradeParty", inv.seller),
      party("ram:BuyerTradeParty", inv.buyer)
    ])
  end

  defp header_delivery(inv) do
    e("ram:ApplicableHeaderTradeDelivery", [
      party("ram:ShipToTradeParty", inv.ship_to),
      delivery_event(inv.delivery_date)
    ])
  end

  defp header_settlement(inv) do
    e(
      "ram:ApplicableHeaderTradeSettlement",
      # InvoiceReferencedDocument comes *after* the summation in
      # HeaderTradeSettlementType, counter-intuitive as that reads.
      [t("ram:InvoiceCurrencyCode", inv.currency)] ++
        Enum.map(inv.tax_breakdown, &trade_tax(&1, inv.tax_due_date_type_code)) ++
        [
          # BillingSpecifiedPeriod sits between ApplicableTradeTax and
          # SpecifiedTradePaymentTerms in HeaderTradeSettlementType.
          billing_period(inv.billing_period),
          payment_terms(inv.due_date),
          monetary_summation(inv.totals, inv.currency)
        ] ++
        Enum.map(inv.preceding_invoices, &preceding_invoice/1)
    )
  end

  # BG-3 (BT-25 / BT-26).
  defp preceding_invoice(ref) do
    e("ram:InvoiceReferencedDocument", [
      t("ram:IssuerAssignedID", ref[:number]),
      # FormattedIssueDateTime is qdt:FormattedDateTimeType, so its child lives in
      # the qdt namespace — unlike every other date in this document, which is udt.
      qdt_date_el("ram:FormattedIssueDateTime", ref[:issue_date])
    ])
  end

  # BG-14 (BT-73 / BT-74).
  defp billing_period(nil), do: nil

  defp billing_period(period) do
    case compact([
           date_el("ram:StartDateTime", period[:start_date]),
           date_el("ram:EndDateTime", period[:end_date])
         ]) do
      [] -> nil
      children -> {"ram:BillingSpecifiedPeriod", [], children}
    end
  end

  # BT-8: the entry's own code wins, else the document-level one (rule S1.13 makes
  # the latter the norm for French invoices).
  # Order follows TradeTaxType: ... CategoryCode, DueDateTypeCode, RateApplicablePercent.
  defp trade_tax(tax, doc_code) do
    e("ram:ApplicableTradeTax", [
      amount("ram:CalculatedAmount", tax[:calculated]),
      t("ram:TypeCode", tax[:type] || "VAT"),
      # BT-120 and BT-121 are not adjacent in TradeTaxType: the reason comes before
      # BasisAmount, the code after CategoryCode.
      t("ram:ExemptionReason", tax[:exemption_reason]),
      amount("ram:BasisAmount", tax[:basis]),
      t("ram:CategoryCode", tax[:category]),
      t("ram:ExemptionReasonCode", tax[:exemption_reason_code]),
      t("ram:DueDateTypeCode", tax[:due_date_type_code] || doc_code),
      t("ram:RateApplicablePercent", decimal(tax[:rate]))
    ])
  end

  defp payment_terms(nil), do: nil

  defp payment_terms(due) do
    e("ram:SpecifiedTradePaymentTerms", [date_el("ram:DueDateDateTime", due)])
  end

  defp monetary_summation(totals, currency) do
    e("ram:SpecifiedTradeSettlementHeaderMonetarySummation", [
      amount("ram:LineTotalAmount", totals[:line_total]),
      amount("ram:TaxBasisTotalAmount", totals[:tax_basis_total]),
      amount("ram:TaxTotalAmount", totals[:tax_total], currency),
      amount("ram:GrandTotalAmount", totals[:grand_total]),
      amount("ram:DuePayableAmount", totals[:due_payable])
    ])
  end

  defp party(_tag, nil), do: nil

  defp party(tag, p) do
    e(tag, [
      t("ram:Name", p[:name]),
      legal_org(p),
      contact(p[:contact]),
      address(p[:address]),
      tax_registration(p[:vat])
    ])
  end

  defp legal_org(p) do
    case p[:legal_id] do
      nil -> nil
      id -> e("ram:SpecifiedLegalOrganization", [id_el(id, p[:legal_scheme] || "0002")])
    end
  end

  defp contact(nil), do: nil

  defp contact(c) do
    e("ram:DefinedTradeContact", [
      t("ram:PersonName", c[:name]),
      wrap("ram:TelephoneUniversalCommunication", t("ram:CompleteNumber", c[:phone])),
      wrap("ram:EmailURIUniversalCommunication", t("ram:URIID", c[:email]))
    ])
  end

  defp address(nil), do: nil

  defp address(a) do
    e("ram:PostalTradeAddress", [
      t("ram:PostcodeCode", a[:postcode]),
      t("ram:LineOne", a[:line_one]),
      t("ram:CityName", a[:city]),
      t("ram:CountryID", a[:country])
    ])
  end

  defp tax_registration(nil), do: nil
  defp tax_registration(vat), do: e("ram:SpecifiedTaxRegistration", [id_el(vat, "VA")])

  defp delivery_event(nil), do: nil

  defp delivery_event(date) do
    e("ram:ActualDeliverySupplyChainEvent", [date_el("ram:OccurrenceDateTime", date)])
  end

  # --- build helpers --------------------------------------------------------

  defp e(name, children), do: {name, [], compact(children)}

  defp t(_name, value) when value in [nil, ""], do: nil
  defp t(name, value), do: {name, [], [to_string(value)]}

  defp id_el(nil, _scheme), do: nil
  defp id_el(value, scheme), do: {"ram:ID", [{"schemeID", scheme}], [to_string(value)]}

  defp amount(_name, nil), do: nil
  defp amount(name, d), do: {name, [], [decimal(d)]}
  defp amount(_name, nil, _cur), do: nil
  defp amount(name, d, cur), do: {name, [{"currencyID", cur}], [decimal(d)]}

  defp qty(_name, nil, _unit), do: nil
  defp qty(name, q, unit), do: {name, [{"unitCode", unit || "C62"}], [decimal(q)]}

  defp date_el(_name, nil), do: nil

  defp date_el(name, %Date{} = d) do
    {name, [], [{"udt:DateTimeString", [{"format", "102"}], [Calendar.strftime(d, "%Y%m%d")]}]}
  end

  # Same shape, qdt namespace: only qdt:FormattedDateTimeType wrappers take this.
  defp qdt_date_el(_name, nil), do: nil

  defp qdt_date_el(name, %Date{} = d) do
    {name, [], [{"qdt:DateTimeString", [{"format", "102"}], [Calendar.strftime(d, "%Y%m%d")]}]}
  end

  # Wrap a single (possibly nil) child, dropping the wrapper if the child is nil.
  defp wrap(_name, nil), do: nil
  defp wrap(name, child), do: {name, [], [child]}

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp decimal(other), do: to_string(other)

  defp compact(list), do: list |> List.flatten() |> Enum.reject(&is_nil/1)

  # ==========================================================================
  # parse: CII XML -> Invoice
  # ==========================================================================

  @doc "Parse a CII XML binary into an `Facturx.Invoice`."
  @spec parse(binary()) :: {:ok, Invoice.t()} | {:error, term()}
  def parse(xml) when is_binary(xml) do
    case Saxy.SimpleForm.parse_string(xml) do
      {:ok, root} -> {:ok, from_root(root)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp from_root(root) do
    tx = find(root, "rsm:SupplyChainTradeTransaction")
    agreement = find(tx, "ram:ApplicableHeaderTradeAgreement")
    delivery = find(tx, "ram:ApplicableHeaderTradeDelivery")
    settlement = find(tx, "ram:ApplicableHeaderTradeSettlement")
    summation = find(settlement, "ram:SpecifiedTradeSettlementHeaderMonetarySummation")

    %Invoice{
      profile:
        profile_from_urn(
          path_text(root, [
            "rsm:ExchangedDocumentContext",
            "ram:GuidelineSpecifiedDocumentContextParameter",
            "ram:ID"
          ])
        ),
      business_process:
        path_text(root, [
          "rsm:ExchangedDocumentContext",
          "ram:BusinessProcessSpecifiedDocumentContextParameter",
          "ram:ID"
        ]),
      notes:
        root
        |> find("rsm:ExchangedDocument")
        |> find_all("ram:IncludedNote")
        |> Enum.map(&parse_note/1),
      number: path_text(root, ["rsm:ExchangedDocument", "ram:ID"]),
      type_code: path_text(root, ["rsm:ExchangedDocument", "ram:TypeCode"]) || "380",
      issue_date:
        parse_date(
          path_text(root, ["rsm:ExchangedDocument", "ram:IssueDateTime", "udt:DateTimeString"])
        ),
      currency: path_text(settlement, ["ram:InvoiceCurrencyCode"]) || "EUR",
      due_date:
        parse_date(
          path_text(settlement, [
            "ram:SpecifiedTradePaymentTerms",
            "ram:DueDateDateTime",
            "udt:DateTimeString"
          ])
        ),
      delivery_date:
        parse_date(
          path_text(delivery, [
            "ram:ActualDeliverySupplyChainEvent",
            "ram:OccurrenceDateTime",
            "udt:DateTimeString"
          ])
        ),
      billing_period: parse_period(find(settlement, "ram:BillingSpecifiedPeriod")),
      preceding_invoices:
        settlement
        |> find_all("ram:InvoiceReferencedDocument")
        |> Enum.map(&parse_preceding_invoice/1),
      seller: parse_party(find(agreement, "ram:SellerTradeParty")),
      buyer: parse_party(find(agreement, "ram:BuyerTradeParty")),
      ship_to: parse_party(find(delivery, "ram:ShipToTradeParty")),
      lines: tx |> find_all("ram:IncludedSupplyChainTradeLineItem") |> Enum.map(&parse_line/1),
      totals: parse_totals(summation)
    }
    |> put_tax_breakdown(settlement)
  end

  # BT-8 is per entry on the wire but usually uniform (rule S1.13). Hoist it to the
  # document level only when every entry agrees; otherwise keep it per entry rather
  # than collapsing distinct VAT point dates onto one value.
  defp put_tax_breakdown(%Invoice{} = inv, settlement) do
    entries = settlement |> find_all("ram:ApplicableTradeTax") |> Enum.map(&parse_tax/1)
    codes = Enum.map(entries, & &1[:due_date_type_code])

    case Enum.uniq(codes) do
      [] ->
        %{inv | tax_breakdown: []}

      [single] ->
        %{
          inv
          | tax_breakdown: Enum.map(entries, &Map.delete(&1, :due_date_type_code)),
            tax_due_date_type_code: single
        }

      _divergent ->
        %{inv | tax_breakdown: entries, tax_due_date_type_code: nil}
    end
  end

  defp parse_line(li) do
    tax = path(li, ["ram:SpecifiedLineTradeSettlement", "ram:ApplicableTradeTax"])
    qty_node = path(li, ["ram:SpecifiedLineTradeDelivery", "ram:BilledQuantity"])

    prune(%{
      id: path_text(li, ["ram:AssociatedDocumentLineDocument", "ram:LineID"]),
      name: path_text(li, ["ram:SpecifiedTradeProduct", "ram:Name"]),
      net_price:
        num(
          path_text(li, [
            "ram:SpecifiedLineTradeAgreement",
            "ram:NetPriceProductTradePrice",
            "ram:ChargeAmount"
          ])
        ),
      gross_price:
        num(
          path_text(li, [
            "ram:SpecifiedLineTradeAgreement",
            "ram:GrossPriceProductTradePrice",
            "ram:ChargeAmount"
          ])
        ),
      price_discount:
        num(
          path_text(li, [
            "ram:SpecifiedLineTradeAgreement",
            "ram:GrossPriceProductTradePrice",
            "ram:AppliedTradeAllowanceCharge",
            "ram:ActualAmount"
          ])
        ),
      quantity: num(node_text(qty_node)),
      unit: attr(qty_node, "unitCode"),
      vat_category: child_text(tax, "ram:CategoryCode"),
      vat_rate: num(child_text(tax, "ram:RateApplicablePercent")),
      line_total:
        num(
          path_text(li, [
            "ram:SpecifiedLineTradeSettlement",
            "ram:SpecifiedTradeSettlementLineMonetarySummation",
            "ram:LineTotalAmount"
          ])
        )
    })
  end

  defp parse_tax(tt) do
    prune(%{
      type: child_text(tt, "ram:TypeCode"),
      category: child_text(tt, "ram:CategoryCode"),
      rate: num(child_text(tt, "ram:RateApplicablePercent")),
      basis: num(child_text(tt, "ram:BasisAmount")),
      calculated: num(child_text(tt, "ram:CalculatedAmount")),
      due_date_type_code: child_text(tt, "ram:DueDateTypeCode"),
      exemption_reason: child_text(tt, "ram:ExemptionReason"),
      exemption_reason_code: child_text(tt, "ram:ExemptionReasonCode")
    })
  end

  defp parse_preceding_invoice(ref) do
    prune(%{
      number: child_text(ref, "ram:IssuerAssignedID"),
      issue_date: parse_date(path_text(ref, ["ram:FormattedIssueDateTime", "qdt:DateTimeString"]))
    })
  end

  defp parse_note(n) do
    prune(%{
      content: child_text(n, "ram:Content"),
      subject_code: child_text(n, "ram:SubjectCode")
    })
  end

  defp parse_period(nil), do: nil

  defp parse_period(p) do
    case prune(%{
           start_date: parse_date(path_text(p, ["ram:StartDateTime", "udt:DateTimeString"])),
           end_date: parse_date(path_text(p, ["ram:EndDateTime", "udt:DateTimeString"]))
         }) do
      empty when empty == %{} -> nil
      period -> period
    end
  end

  defp parse_party(nil), do: nil

  defp parse_party(p) do
    prune(%{
      name: child_text(p, "ram:Name"),
      legal_id: path_text(p, ["ram:SpecifiedLegalOrganization", "ram:ID"]),
      legal_scheme: attr(path(p, ["ram:SpecifiedLegalOrganization", "ram:ID"]), "schemeID"),
      vat: path_text(p, ["ram:SpecifiedTaxRegistration", "ram:ID"]),
      address: parse_address(find(p, "ram:PostalTradeAddress")),
      contact: parse_contact(find(p, "ram:DefinedTradeContact"))
    })
  end

  defp parse_address(nil), do: nil

  defp parse_address(a) do
    prune(%{
      postcode: child_text(a, "ram:PostcodeCode"),
      line_one: child_text(a, "ram:LineOne"),
      city: child_text(a, "ram:CityName"),
      country: child_text(a, "ram:CountryID")
    })
  end

  defp parse_contact(nil), do: nil

  defp parse_contact(c) do
    prune(%{
      name: child_text(c, "ram:PersonName"),
      phone: path_text(c, ["ram:TelephoneUniversalCommunication", "ram:CompleteNumber"]),
      email: path_text(c, ["ram:EmailURIUniversalCommunication", "ram:URIID"])
    })
  end

  defp parse_totals(nil), do: %{}

  defp parse_totals(ms) do
    prune(%{
      line_total: num(child_text(ms, "ram:LineTotalAmount")),
      tax_basis_total: num(child_text(ms, "ram:TaxBasisTotalAmount")),
      tax_total: num(child_text(ms, "ram:TaxTotalAmount")),
      grand_total: num(child_text(ms, "ram:GrandTotalAmount")),
      due_payable: num(child_text(ms, "ram:DuePayableAmount"))
    })
  end

  # --- parse helpers --------------------------------------------------------

  defp elems(content), do: Enum.filter(content, &match?({_, _, _}, &1))

  defp find(nil, _name), do: nil

  defp find({_, _, content}, name),
    do: Enum.find(elems(content), fn {n, _, _} -> n == name end)

  defp find_all(nil, _name), do: []

  defp find_all({_, _, content}, name),
    do: Enum.filter(elems(content), fn {n, _, _} -> n == name end)

  defp path(el, []), do: el
  defp path(el, [h | t]), do: path(find(el, h), t)

  defp path_text(el, names), do: node_text(path(el, names))
  defp child_text(el, name), do: node_text(find(el, name))

  defp node_text(nil), do: nil

  defp node_text({_, _, content}) do
    case content |> Enum.filter(&is_binary/1) |> Enum.join() |> String.trim() do
      "" -> nil
      v -> v
    end
  end

  defp attr(nil, _key), do: nil

  defp attr({_, attrs, _}, key) do
    case List.keyfind(attrs, key, 0) do
      {_, v} -> v
      _ -> nil
    end
  end

  # Total: never raises on malformed content (parse/1 must honour {:ok|:error}).
  defp num(nil), do: nil

  defp num(str) do
    case Decimal.parse(str) do
      {d, ""} -> d
      _ -> nil
    end
  end

  defp parse_date(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>) do
    with {yy, ""} <- Integer.parse(y),
         {mm, ""} <- Integer.parse(m),
         {dd, ""} <- Integer.parse(d),
         {:ok, date} <- Date.new(yy, mm, dd) do
      date
    else
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp prune(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  # profile <-> guideline URN (shared source of truth)
  defp profile_urn(profile), do: Facturx.Profile.to_urn(profile)
  defp profile_from_urn(urn), do: Facturx.Profile.from_urn(urn)
end
