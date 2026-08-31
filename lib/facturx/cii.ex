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

      Enabling it also enforces rule **G1.60**: a `B4`/`S4`/`M4` framework means
      "final invoice after a down payment", so it cannot be paired with a
      down-payment `:type_code` — `386`, `500` or `503`. That returns
      `{:error, {:final_invoice_type_conflict, %{business_process: …, type_code: …}}}`.
      Being a cross-field rule, neither the XSD nor the EN 16931 schematron sees
      it.

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

  ## What a leaner profile drops

  That error is about a struct that contradicts itself — BT-8 with no breakdown
  to attach it to. Asking for a leaner profile is a different thing: it is an
  explicit instruction to emit less, and `build/2` obeys it silently, because
  dropping data is the whole point.

  `:minimum` is the extreme case. Its schema has no `ram:ApplicableTradeTax`, so
  the VAT breakdown goes, and BT-8 with it; the lines, the notes, the payment
  means, the contacts and the buyer's address go too. What comes back from
  `parse/1` is therefore much less than what went in — see `Facturx.profiles/0`
  and the profile table in the README for what each one carries.
  """
  @spec build(Invoice.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def build(invoice, opts \\ [])

  def build(%Invoice{} = inv, opts) do
    profile = Keyword.get(opts, :profile, inv.profile || :en16931)
    check_bp? = validate_bp?(opts)

    with :ok <- check_business_process(inv.business_process, check_bp?),
         :ok <- check_final_invoice_type(inv, check_bp?),
         :ok <- check_vat_point_dates(inv, flag?(opts, :validate_vat_point_date, true)),
         :ok <- check_tax_currency(inv) do
      doc =
        {"rsm:CrossIndustryInvoice", @ns,
         [
           context(inv, profile),
           document(inv, profile),
           transaction(inv, profile)
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

  # Rule G1.60. The B4/S4/M4 frameworks mean "final invoice after a down payment",
  # so the document cannot itself be a down payment: 386 (down payment invoice),
  # 500 (self-billed down payment invoice) or 503 (down payment credit note).
  #
  # Rides on :validate_business_process because it is French, like G1.02 — and it
  # is worth having: being a cross-field constraint, neither the XSD nor the
  # EN 16931 schematron catches it, so the first sign would be a platform refusing
  # the invoice.
  @final_invoice_frameworks ~w(B4 S4 M4)
  @down_payment_type_codes ~w(386 500 503)

  defp check_final_invoice_type(_inv, false), do: :ok

  defp check_final_invoice_type(%Invoice{business_process: bp, type_code: type}, true)
       when bp in @final_invoice_frameworks and type in @down_payment_type_codes do
    {:error, {:final_invoice_type_conflict, %{business_process: bp, type_code: type}}}
  end

  defp check_final_invoice_type(_inv, _check?), do: :ok

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

  # BT-110 and BT-111 are two occurrences of ram:TaxTotalAmount, told apart only by
  # their currencyID. So BT-111 needs BT-6 (BR-53), and BT-6 must differ from the
  # invoice currency — otherwise the two are indistinguishable and the schematron
  # rejects the document. Without this check the first case crashed the encoder on a
  # nil attribute, and the second built happily.
  defp check_tax_currency(%Invoice{totals: totals, currency: currency, tax_currency: tax}) do
    cond do
      blank?(totals[:tax_total_in_tax_currency]) ->
        :ok

      blank?(tax) ->
        {:error, {:tax_currency_missing, :tax_total_in_tax_currency}}

      tax == currency ->
        {:error, {:tax_currency_not_distinct, tax}}

      true ->
        :ok
    end
  end

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

  defp document(inv, profile) do
    e("rsm:ExchangedDocument", [
      t("ram:ID", inv.number),
      t("ram:TypeCode", inv.type_code),
      date_el("ram:IssueDateTime", inv.issue_date),
      # ExchangedDocumentType has no IncludedNote in MINIMUM.
      if(at_least?(profile, :basic_wl), do: Enum.map(inv.notes, &note/1))
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

  # BT-127 and BT-127-00. EN 16931 caps ram:IncludedNote at one occurrence per
  # line and leaves no room for ram:SubjectCode there — that code is
  # EXT-FR-FE-183, a French extension on the target trajectory, and emitting one
  # gets an EN 16931 document rejected. Both only open up in EXTENDED, so the
  # profile decides rather than the caller.
  defp line_notes(line, profile) do
    if at_least?(profile, :extended),
      do: Enum.map(with_content(line), &note/1),
      else: first_line_note(line)
  end

  defp first_line_note(line) do
    # The first note *with content*, not simply the first: a leading entry
    # carrying only a subject code would otherwise take the single slot the
    # profile allows and emit nothing at all.
    case with_content(line) do
      [] -> []
      [note | _] -> [wrap("ram:IncludedNote", t("ram:Content", note[:content]))]
    end
  end

  # `""` is truthy, so testing the key alone is not enough — and an empty note
  # would collapse to a bare <ram:IncludedNote/>. `blank?/1` is the module's
  # convention: nil and "" are both absent.
  defp with_content(line), do: Enum.reject(line[:notes] || [], &blank?(&1[:content]))

  # Takes the profile `build/2` resolved, not `inv.profile`: the two differ as
  # soon as a caller passes `profile:`, and the guideline URN would then say one
  # thing while the line notes obeyed another.
  defp transaction(inv, profile) do
    # MINIMUM and BASIC WL have no IncludedSupplyChainTradeLineItem at all —
    # "WL" is *without lines*. Everything the lines carried is simply not
    # emitted; the header totals still are.
    lines =
      if at_least?(profile, :basic), do: Enum.map(inv.lines, &line_item(&1, profile)), else: []

    e(
      "rsm:SupplyChainTradeTransaction",
      lines ++
        [
          header_agreement(inv, profile),
          header_delivery(inv, profile),
          header_settlement(inv, profile)
        ]
    )
  end

  defp line_item(line, profile) do
    e("ram:IncludedSupplyChainTradeLineItem", [
      e(
        "ram:AssociatedDocumentLineDocument",
        [t("ram:LineID", line[:id]) | line_notes(line, profile)]
      ),
      e("ram:SpecifiedTradeProduct", [t("ram:Name", line[:name])]),
      e("ram:SpecifiedLineTradeAgreement", [
        # GrossPrice precedes NetPrice in LineTradeAgreementType.
        gross_price(line),
        e("ram:NetPriceProductTradePrice", [amount("ram:ChargeAmount", line[:net_price])])
      ]),
      e("ram:SpecifiedLineTradeDelivery", [
        qty("ram:BilledQuantity", line[:quantity], line[:unit]),
        # EXT-FR-FE-BG-10 then BG-11: LineTradeDeliveryType orders the quantities
        # first, then ShipToTradeParty, then ActualDeliverySupplyChainEvent. Both
        # are 0..1, hence single maps rather than lists.
        line_ship_to(line, profile),
        line_delivery_event(line, profile)
      ]),
      e("ram:SpecifiedLineTradeSettlement", [
        line_trade_tax(line),
        # BG-26 — LineTradeSettlementType puts the period after the tax.
        billing_period(line[:billing_period]),
        # BG-27 / BG-28 — after the period, before the line summation.
        allowances_and_charges(line),
        e("ram:SpecifiedTradeSettlementLineMonetarySummation", [
          amount("ram:LineTotalAmount", line[:line_total])
        ]),
        # EXT-FR-FE-BG-06 — after the summation, as at header level. 0..1 here
        # (minOccurs=0, no maxOccurs), hence a single map and not a list.
        line_preceding_invoice(line, profile)
      ])
    ])
  end

  # EXT-FR-FE-BG-06 / -136 / -138. A French extension on the target trajectory,
  # so EN 16931 rejects it: the profile decides, as for the line notes.
  defp line_preceding_invoice(line, profile) do
    if at_least?(profile, :extended) do
      case line[:preceding_invoice] do
        nil -> nil
        ref -> preceding_invoice(ref)
      end
    end
  end

  # EXT-FR-FE-BG-10 (`-149` to `-157`) and EXT-FR-FE-BG-11 (`-158*`). Same
  # French extensions, same profile gate; both reuse the header-level emitters,
  # the CII types being identical.
  defp line_ship_to(line, profile) do
    if at_least?(profile, :extended),
      do: party("ram:ShipToTradeParty", line[:ship_to], profile)
  end

  defp line_delivery_event(line, profile) do
    if at_least?(profile, :extended), do: delivery_event(line[:delivery_date])
  end

  defp line_trade_tax(line) do
    e("ram:ApplicableTradeTax", [
      # Line-level trade tax is always VAT under EN 16931.
      t("ram:TypeCode", "VAT"),
      t("ram:CategoryCode", line[:vat_category]),
      t("ram:RateApplicablePercent", decimal(line[:vat_rate]))
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

  defp header_agreement(inv, profile) do
    e("ram:ApplicableHeaderTradeAgreement", [
      party("ram:SellerTradeParty", inv.seller, profile),
      party("ram:BuyerTradeParty", inv.buyer, profile),
      # BG-11 — follows the buyer in HeaderTradeAgreementType, and starts at
      # BASIC WL: MINIMUM has no SellerTaxRepresentativeTradeParty.
      if(at_least?(profile, :basic_wl),
        do: party("ram:SellerTaxRepresentativeTradeParty", inv.tax_representative, profile)
      )
    ])
  end

  # HeaderTradeDeliveryType is an *empty* complexType in MINIMUM: the element is
  # still required, with nothing inside it.
  defp header_delivery(inv, profile) do
    children =
      if at_least?(profile, :basic_wl) do
        [party("ram:ShipToTradeParty", inv.ship_to, profile), delivery_event(inv.delivery_date)]
      else
        []
      end

    e("ram:ApplicableHeaderTradeDelivery", children)
  end

  # MINIMUM's HeaderTradeSettlementType holds two children and no more:
  # InvoiceCurrencyCode and the summation. Not even ApplicableTradeTax — which
  # is why a MINIMUM document cannot carry BG-23, and why it is an accounting
  # aid rather than an invoice under the French mandate.
  defp header_settlement(inv, profile) do
    if at_least?(profile, :basic_wl),
      do: full_settlement(inv, profile),
      else: minimum_settlement(inv, profile)
  end

  defp minimum_settlement(inv, profile) do
    e("ram:ApplicableHeaderTradeSettlement", [
      t("ram:InvoiceCurrencyCode", inv.currency),
      monetary_summation(inv.totals, inv.currency, inv.tax_currency, profile)
    ])
  end

  defp full_settlement(inv, profile) do
    e(
      "ram:ApplicableHeaderTradeSettlement",
      # InvoiceReferencedDocument comes *after* the summation in
      # HeaderTradeSettlementType, counter-intuitive as that reads.
      # PaymentMeans precedes ApplicableTradeTax in HeaderTradeSettlementType.
      # SpecifiedTradeAllowanceCharge sits between the period and the terms.
      [
        # BT-6 precedes InvoiceCurrencyCode in HeaderTradeSettlementType.
        t("ram:TaxCurrencyCode", inv.tax_currency),
        t("ram:InvoiceCurrencyCode", inv.currency)
      ] ++
        Enum.map(inv.payment_means, &payment_means(&1, profile)) ++
        Enum.map(inv.tax_breakdown, &trade_tax(&1, inv.tax_due_date_type_code)) ++
        [
          # BillingSpecifiedPeriod sits between ApplicableTradeTax and
          # SpecifiedTradePaymentTerms in HeaderTradeSettlementType.
          billing_period(inv.billing_period)
        ] ++
        allowances_and_charges(Map.from_struct(inv)) ++
        [
          payment_terms(inv.due_date),
          monetary_summation(inv.totals, inv.currency, inv.tax_currency, profile)
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
    maybe("ram:BillingSpecifiedPeriod", [
      date_el("ram:StartDateTime", period[:start_date]),
      date_el("ram:EndDateTime", period[:end_date])
    ])
  end

  # BG-20/BG-21 at document level, BG-27/BG-28 on a line — one CII element for all
  # four, told apart by ChargeIndicator. Order follows TradeAllowanceChargeType, in
  # which ReasonCode precedes Reason (the reverse of the BT numbering).
  defp allowance_charge(ac, charge?) do
    e("ram:SpecifiedTradeAllowanceCharge", [
      wrap("ram:ChargeIndicator", t("udt:Indicator", to_string(charge?))),
      t("ram:CalculationPercent", decimal(ac[:percent])),
      amount("ram:BasisAmount", ac[:basis_amount]),
      amount("ram:ActualAmount", ac[:amount]),
      t("ram:ReasonCode", ac[:reason_code]),
      t("ram:Reason", ac[:reason]),
      # CategoryTradeTax is a TradeTaxType, so TypeCode / CategoryCode / rate.
      maybe("ram:CategoryTradeTax", [
        t("ram:TypeCode", (ac[:vat_category] || ac[:vat_rate]) && "VAT"),
        t("ram:CategoryCode", ac[:vat_category]),
        t("ram:RateApplicablePercent", decimal(ac[:vat_rate]))
      ])
    ])
  end

  defp allowances_and_charges(container) do
    Enum.map(container[:allowances] || [], &allowance_charge(&1, false)) ++
      Enum.map(container[:charges] || [], &allowance_charge(&1, true))
  end

  # BG-16 (BT-81 / BT-82) with its account and institution sub-blocks. Order follows
  # TradeSettlementPaymentMeansType: code, information, card, debited account,
  # credited account, institution.
  # Three of the six children start at EN 16931: BT-82 (Information), BG-18 (the
  # card) and BT-86 (the BIC). BASIC and BASIC WL carry the account, not the
  # institution.
  defp payment_means(pm, profile) do
    en? = at_least?(profile, :en16931)

    e("ram:SpecifiedTradeSettlementPaymentMeans", [
      t("ram:TypeCode", pm[:type_code]),
      if(en?, do: t("ram:Information", pm[:information])),
      # BG-18 — ID is required by the schema, so the card block needs it.
      if(en?,
        do:
          maybe("ram:ApplicableTradeSettlementFinancialCard", [
            t("ram:ID", pm[:card_id]),
            t("ram:CardholderName", pm[:cardholder_name])
          ])
      ),
      # BG-19 (BT-91) — DebtorFinancialAccountType requires IBANID.
      wrap("ram:PayerPartyDebtorFinancialAccount", t("ram:IBANID", pm[:payer_iban])),
      # BG-17 (BT-84 / BT-85) — every child optional, hence maybe/2. BT-85
      # (AccountName) is the one that waits for EN 16931.
      maybe("ram:PayeePartyCreditorFinancialAccount", [
        t("ram:IBANID", pm[:iban]),
        if(en?, do: t("ram:AccountName", pm[:account_name])),
        t("ram:ProprietaryID", pm[:account_id])
      ]),
      # BT-86 — CreditorFinancialInstitutionType requires BICID.
      if(en?,
        do: wrap("ram:PayeeSpecifiedCreditorFinancialInstitution", t("ram:BICID", pm[:bic]))
      )
    ])
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

  # Wire order does not follow the BT numbering: ChargeTotalAmount comes *before*
  # AllowanceTotalAmount, though BT-107 (allowances) precedes BT-108 (charges).
  # MINIMUM keeps four of the ten: the basis, the tax, the grand total and what
  # is due. BT-114 (rounding) only appears at EN 16931.
  defp monetary_summation(totals, currency, tax_currency, profile) do
    wl? = at_least?(profile, :basic_wl)

    e("ram:SpecifiedTradeSettlementHeaderMonetarySummation", [
      if(wl?, do: amount("ram:LineTotalAmount", totals[:line_total])),
      if(wl?, do: amount("ram:ChargeTotalAmount", totals[:charge_total])),
      if(wl?, do: amount("ram:AllowanceTotalAmount", totals[:allowance_total])),
      amount("ram:TaxBasisTotalAmount", totals[:tax_basis_total]),
      amount("ram:TaxTotalAmount", totals[:tax_total], currency),
      # BT-111 is the second TaxTotalAmount (maxOccurs=2), in the accounting
      # currency — and it goes wherever BT-6 goes. MINIMUM has no
      # TaxCurrencyCode, so emitting BT-111 there would state an amount in a
      # currency the document never declares. The schema allows two occurrences
      # in every profile and would not have caught it; the build/parse fixed
      # point did, the second pass having no BT-6 left to read back.
      if(wl?, do: amount("ram:TaxTotalAmount", totals[:tax_total_in_tax_currency], tax_currency)),
      if(at_least?(profile, :en16931), do: amount("ram:RoundingAmount", totals[:rounding])),
      amount("ram:GrandTotalAmount", totals[:grand_total]),
      if(wl?, do: amount("ram:TotalPrepaidAmount", totals[:prepaid])),
      amount("ram:DuePayableAmount", totals[:due_payable])
    ])
  end

  defp party(_tag, nil, _profile), do: nil

  defp party(tag, p, profile) do
    e(tag, [
      # GlobalID precedes Name in TradePartyType. The 0231 default (SIREN of an
      # assujetti unique) is BT-29d, which the annexe puts on the seller alone —
      # applying it everywhere would mislabel, say, a buyer's GLN as a French VAT
      # group id. MINIMUM's TradePartyType has no GlobalID.
      if(at_least?(profile, :basic_wl),
        do:
          id_el_named(
            "ram:GlobalID",
            p[:global_id],
            p[:global_scheme] || default_global_scheme(tag)
          )
      ),
      t("ram:Name", p[:name]),
      legal_org(p),
      # BG-6 / BG-9 — TradeContactType exists only from EN 16931 up.
      if(at_least?(profile, :en16931), do: contact(p[:contact])),
      if(addressable?(tag, profile), do: address(p[:address], profile)),
      if(addressable?(tag, profile), do: tax_registration(p[:vat]))
    ])
  end

  # In MINIMUM the address (BG-5) and the tax registration belong to the seller
  # and to no one else: the seller's address is required there (BR-08, BR-09),
  # the buyer's is refused. The XSD cannot say this — it types every party alike
  # and accepts both — so only the schematron does, which is why a realistic
  # invoice has to be put in front of it before a profile is called done.
  defp addressable?(tag, profile) do
    at_least?(profile, :basic_wl) or tag == "ram:SellerTradeParty"
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

  defp address(nil, _profile), do: nil

  # MINIMUM's TradeAddressType is the country and nothing else.
  defp address(a, profile) do
    wl? = at_least?(profile, :basic_wl)

    e("ram:PostalTradeAddress", [
      if(wl?, do: t("ram:PostcodeCode", a[:postcode])),
      if(wl?, do: t("ram:LineOne", a[:line_one])),
      if(wl?, do: t("ram:LineTwo", a[:line_two])),
      if(wl?, do: t("ram:LineThree", a[:line_three])),
      if(wl?, do: t("ram:CityName", a[:city])),
      t("ram:CountryID", a[:country]),
      # CountrySubDivisionName follows CountryID, not the city.
      if(wl?, do: t("ram:CountrySubDivisionName", a[:country_subdivision]))
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

  # Like e/2 but drops the wrapper too when nothing survives, for containers whose
  # children are all optional — an empty one would trip PEPPOL-EN16931-R008.
  defp maybe(name, children) do
    case compact(children) do
      [] -> nil
      kids -> {name, [], kids}
    end
  end

  defp t(_name, value) when value in [nil, ""], do: nil
  defp t(name, value), do: {name, [], [to_string(value)]}

  defp default_global_scheme("ram:SellerTradeParty"), do: "0231"
  defp default_global_scheme(_tag), do: nil

  defp id_el_named(_name, nil, _scheme), do: nil
  defp id_el_named(name, value, nil), do: {name, [], [to_string(value)]}

  defp id_el_named(name, value, scheme),
    do: {name, [], [to_string(value)]} |> put_scheme(scheme)

  defp put_scheme({name, _attrs, kids}, scheme), do: {name, [{"schemeID", scheme}], kids}

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
    # Read once: the totals need them to tell BT-110 from BT-111.
    invoice_currency = path_text(settlement, ["ram:InvoiceCurrencyCode"]) || "EUR"
    tax_currency = path_text(settlement, ["ram:TaxCurrencyCode"])

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
      currency: invoice_currency,
      tax_currency: tax_currency,
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
      payment_means:
        settlement
        |> find_all("ram:SpecifiedTradeSettlementPaymentMeans")
        |> Enum.map(&parse_payment_means/1),
      allowances: elem(parse_allowances_and_charges(settlement), 0),
      charges: elem(parse_allowances_and_charges(settlement), 1),
      seller: parse_party(find(agreement, "ram:SellerTradeParty")),
      buyer: parse_party(find(agreement, "ram:BuyerTradeParty")),
      tax_representative: parse_party(find(agreement, "ram:SellerTaxRepresentativeTradeParty")),
      ship_to: parse_party(find(delivery, "ram:ShipToTradeParty")),
      lines: tx |> find_all("ram:IncludedSupplyChainTradeLineItem") |> Enum.map(&parse_line/1),
      totals: parse_totals(summation, invoice_currency, tax_currency)
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

  # nil rather than [] when there is no note: `prune/1` drops nils only, and a
  # line that went in without the key must come back without it for
  # `parse(build(inv)) == inv` to hold. Same convention as line_allowances/2.
  defp line_notes_of(li) do
    case li
         |> find("ram:AssociatedDocumentLineDocument")
         |> find_all("ram:IncludedNote")
         |> Enum.map(&parse_note/1) do
      [] -> nil
      notes -> notes
    end
  end

  # EXT-FR-FE-BG-06, 0..1: nil rather than a map when the element is absent, so
  # `prune/1` drops the key and the round-trip stays exact.
  defp line_preceding_invoice_of(li) do
    case path(li, ["ram:SpecifiedLineTradeSettlement", "ram:InvoiceReferencedDocument"]) do
      nil -> nil
      ref -> parse_preceding_invoice(ref)
    end
  end

  defp parse_line(li) do
    tax = path(li, ["ram:SpecifiedLineTradeSettlement", "ram:ApplicableTradeTax"])
    qty_node = path(li, ["ram:SpecifiedLineTradeDelivery", "ram:BilledQuantity"])

    prune(%{
      id: path_text(li, ["ram:AssociatedDocumentLineDocument", "ram:LineID"]),
      notes: line_notes_of(li),
      preceding_invoice: line_preceding_invoice_of(li),
      ship_to: parse_party(path(li, ["ram:SpecifiedLineTradeDelivery", "ram:ShipToTradeParty"])),
      delivery_date:
        parse_date(
          path_text(li, [
            "ram:SpecifiedLineTradeDelivery",
            "ram:ActualDeliverySupplyChainEvent",
            "ram:OccurrenceDateTime",
            "udt:DateTimeString"
          ])
        ),
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
        ),
      allowances: line_allowances(li, 0),
      charges: line_allowances(li, 1),
      billing_period:
        parse_period(path(li, ["ram:SpecifiedLineTradeSettlement", "ram:BillingSpecifiedPeriod"]))
    })
  end

  # prune/1 drops nil, not [], so keep empty lists out of the map to preserve the
  # round-trip against a line that never mentioned them.
  defp line_allowances(li, index) do
    case li
         |> find("ram:SpecifiedLineTradeSettlement")
         |> parse_allowances_and_charges()
         |> elem(index) do
      [] -> nil
      list -> list
    end
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

  # Splits one CII element back into the two lists, on ChargeIndicator.
  defp parse_allowances_and_charges(container) do
    {charges, allowances} =
      container
      |> find_all("ram:SpecifiedTradeAllowanceCharge")
      |> Enum.split_with(&(path_text(&1, ["ram:ChargeIndicator", "udt:Indicator"]) == "true"))

    {Enum.map(allowances, &parse_allowance_charge/1),
     Enum.map(charges, &parse_allowance_charge/1)}
  end

  defp parse_allowance_charge(ac) do
    tax = find(ac, "ram:CategoryTradeTax")

    prune(%{
      percent: num(child_text(ac, "ram:CalculationPercent")),
      basis_amount: num(child_text(ac, "ram:BasisAmount")),
      amount: num(child_text(ac, "ram:ActualAmount")),
      reason_code: child_text(ac, "ram:ReasonCode"),
      reason: child_text(ac, "ram:Reason"),
      vat_category: child_text(tax, "ram:CategoryCode"),
      vat_rate: num(child_text(tax, "ram:RateApplicablePercent"))
    })
  end

  defp parse_payment_means(pm) do
    card = find(pm, "ram:ApplicableTradeSettlementFinancialCard")
    creditor = find(pm, "ram:PayeePartyCreditorFinancialAccount")

    prune(%{
      type_code: child_text(pm, "ram:TypeCode"),
      information: child_text(pm, "ram:Information"),
      card_id: child_text(card, "ram:ID"),
      cardholder_name: child_text(card, "ram:CardholderName"),
      payer_iban: path_text(pm, ["ram:PayerPartyDebtorFinancialAccount", "ram:IBANID"]),
      iban: child_text(creditor, "ram:IBANID"),
      account_name: child_text(creditor, "ram:AccountName"),
      account_id: child_text(creditor, "ram:ProprietaryID"),
      bic: path_text(pm, ["ram:PayeeSpecifiedCreditorFinancialInstitution", "ram:BICID"])
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
      global_id: child_text(p, "ram:GlobalID"),
      global_scheme: attr(find(p, "ram:GlobalID"), "schemeID"),
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
      line_two: child_text(a, "ram:LineTwo"),
      line_three: child_text(a, "ram:LineThree"),
      city: child_text(a, "ram:CityName"),
      country: child_text(a, "ram:CountryID"),
      country_subdivision: child_text(a, "ram:CountrySubDivisionName")
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

  # BT-110: the one in the invoice currency, else an unlabelled one. Never falls
  # back to "the first", which would claim BT-111 when only that is present.
  defp tax_total(ms, currency) do
    totals = find_all(ms, "ram:TaxTotalAmount")

    (Enum.find(totals, &(attr(&1, "currencyID") == currency)) ||
       Enum.find(totals, &(attr(&1, "currencyID") == nil)))
    |> node_text()
  end

  # BT-111: only ever the one in the accounting currency, and only if there is one.
  defp tax_total_in_tax_currency(_ms, nil), do: nil

  defp tax_total_in_tax_currency(ms, tax_currency) do
    ms
    |> find_all("ram:TaxTotalAmount")
    |> Enum.find(&(attr(&1, "currencyID") == tax_currency))
    |> node_text()
  end

  defp parse_totals(nil, _currency, _tax_currency), do: %{}

  defp parse_totals(ms, currency, tax_currency) do
    prune(%{
      line_total: num(child_text(ms, "ram:LineTotalAmount")),
      charge_total: num(child_text(ms, "ram:ChargeTotalAmount")),
      allowance_total: num(child_text(ms, "ram:AllowanceTotalAmount")),
      tax_basis_total: num(child_text(ms, "ram:TaxBasisTotalAmount")),
      tax_total: num(tax_total(ms, currency)),
      # BT-111 shares BT-110's element name; only @currencyID tells them apart, so
      # a conformant producer emitting the accounting-currency total first must not
      # end up swapping the two.
      tax_total_in_tax_currency: num(tax_total_in_tax_currency(ms, tax_currency)),
      rounding: num(child_text(ms, "ram:RoundingAmount")),
      grand_total: num(child_text(ms, "ram:GrandTotalAmount")),
      prepaid: num(child_text(ms, "ram:TotalPrepaidAmount")),
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
  defp at_least?(profile, floor), do: Facturx.Profile.at_least?(profile, floor)
  defp profile_urn(profile), do: Facturx.Profile.to_urn(profile)
  defp profile_from_urn(urn), do: Facturx.Profile.from_urn(urn)
end
