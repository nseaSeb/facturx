defmodule Facturx.CIITest do
  use ExUnit.Case, async: true

  alias Facturx.Invoice

  # A fully synthetic invoice — no real personal data lives in the repo.
  defp sample_invoice do
    %Invoice{
      profile: :en16931,
      number: "INV-2026-001",
      type_code: "380",
      issue_date: ~D[2026-07-24],
      due_date: ~D[2026-08-24],
      currency: "EUR",
      seller: %{
        name: "ACME SARL",
        legal_id: "12345678900011",
        legal_scheme: "0002",
        vat: "FR12345678900",
        address: %{postcode: "75001", line_one: "1 rue de Rivoli", city: "Paris", country: "FR"}
      },
      buyer: %{
        name: "Client SAS",
        vat: "FR98765432100",
        address: %{postcode: "69001", line_one: "2 place Bellecour", city: "Lyon", country: "FR"},
        contact: %{name: "Jean Client", email: "jean@example.com", phone: "0102030405"}
      },
      delivery_date: ~D[2026-07-24],
      # French mandate: BT-23 (services) and BT-8 ("5" = date of invoice,
      # i.e. VAT on debits). BT-8 values are restricted to 5/29/72 by BR-CL-06.
      business_process: "S1",
      tax_due_date_type_code: "5",
      lines: [
        %{
          id: "1",
          name: "Prestation de service",
          net_price: Decimal.new("100.00"),
          quantity: Decimal.new("2"),
          unit: "C62",
          vat_category: "S",
          vat_rate: Decimal.new("20.00"),
          line_total: Decimal.new("200.00")
        }
      ],
      tax_breakdown: [
        %{
          type: "VAT",
          category: "S",
          rate: Decimal.new("20.00"),
          basis: Decimal.new("200.00"),
          calculated: Decimal.new("40.00")
        }
      ],
      totals: %{
        line_total: Decimal.new("200.00"),
        tax_basis_total: Decimal.new("200.00"),
        tax_total: Decimal.new("40.00"),
        grand_total: Decimal.new("240.00"),
        due_payable: Decimal.new("240.00")
      }
    }
  end

  describe "build/2" do
    test "emits a namespaced EN 16931 CII document" do
      assert {:ok, xml} = Facturx.build(sample_invoice())

      assert String.starts_with?(xml, ~s(<?xml version="1.0" encoding="UTF-8"?>))
      assert xml =~ "rsm:CrossIndustryInvoice"
      assert xml =~ "urn:cen.eu:en16931:2017"
      assert xml =~ "<ram:ID>INV-2026-001</ram:ID>"
      assert xml =~ ~s(<udt:DateTimeString format="102">20260724</udt:DateTimeString>)
      assert xml =~ ~s(<ram:BilledQuantity unitCode="C62">2</ram:BilledQuantity>)
      # well-formed
      assert {:ok, _} = Saxy.SimpleForm.parse_string(xml)
    end

    test "honours the :profile option" do
      {:ok, xml} = Facturx.build(sample_invoice(), profile: :basic)
      assert xml =~ "urn:factur-x.eu:1p0:basic"
    end

    test "output validates against the bundled EN 16931 XSD" do
      {:ok, xml} = Facturx.build(sample_invoice())
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
    end
  end

  # BT-23 (cadre de facturation) and BT-8 (option TVA sur les débits) — the two
  # data items the French mandate requires. See docs/reference/reforme-fr.md.
  describe "French mandate fields" do
    test "BT-23 is emitted before BT-24, as the CII sequence requires" do
      {:ok, xml} = Facturx.build(sample_invoice())

      assert xml =~
               "<ram:BusinessProcessSpecifiedDocumentContextParameter><ram:ID>S1</ram:ID>"

      business = :binary.match(xml, "BusinessProcessSpecifiedDocumentContextParameter")
      guideline = :binary.match(xml, "GuidelineSpecifiedDocumentContextParameter")
      assert elem(business, 0) < elem(guideline, 0)
    end

    test "BT-8 goes into the VAT breakdown, between CategoryCode and the rate" do
      {:ok, xml} = Facturx.build(sample_invoice())

      assert xml =~
               "<ram:CategoryCode>S</ram:CategoryCode>" <>
                 "<ram:DueDateTypeCode>5</ram:DueDateTypeCode>" <>
                 "<ram:RateApplicablePercent>20.00</ram:RateApplicablePercent>"
    end

    test "BT-8 repeats on every VAT breakdown entry (rule S1.13)" do
      inv = %{
        sample_invoice()
        | tax_breakdown: [
            %{type: "VAT", category: "S", rate: Decimal.new("20.00")},
            %{type: "VAT", category: "S", rate: Decimal.new("5.50")}
          ]
      }

      {:ok, xml} = Facturx.build(inv)

      assert length(String.split(xml, "<ram:DueDateTypeCode>5</ram:DueDateTypeCode>")) - 1 == 2
    end

    test "both fields survive a build/parse round-trip" do
      {:ok, xml} = Facturx.build(sample_invoice())
      {:ok, parsed} = Facturx.parse(xml)

      assert parsed.business_process == "S1"
      assert parsed.tax_due_date_type_code == "5"
    end

    test "omitting them emits nothing (unchanged for cross-border use)" do
      inv = %{sample_invoice() | business_process: nil, tax_due_date_type_code: nil}
      {:ok, xml} = Facturx.build(inv)

      refute xml =~ "BusinessProcessSpecifiedDocumentContextParameter"
      refute xml =~ "DueDateTypeCode"
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "every BT-23 code of rule G1.02 builds and validates" do
      for code <- Facturx.business_processes() do
        {:ok, xml} =
          Facturx.build(%{sample_invoice() | business_process: code},
            validate_business_process: true
          )

        assert {:ok, :valid} = Facturx.validate_xsd(xml), "profile code #{code} failed XSD"
        assert xml =~ "<ram:ID>#{code}</ram:ID>"
      end
    end

    test "an unknown BT-23 code is rejected when validation is enabled" do
      assert {:error, {:invalid_business_process, "X9"}} =
               Facturx.build(%{sample_invoice() | business_process: "X9"},
                 validate_business_process: true
               )

      assert {:error, {:invalid_business_process, :b1}} =
               Facturx.build(%{sample_invoice() | business_process: :b1},
                 validate_business_process: true
               )
    end

    test "a non-binary BT-23 is rejected even with validation off" do
      assert {:error, {:invalid_business_process, :b1}} =
               Facturx.build(%{sample_invoice() | business_process: :b1})
    end
  end

  # BT-23 is an EN 16931 business term, not a French one: the French closed list
  # is opt-in so it cannot lock out Peppol / Chorus Pro / other national values.
  describe "non-French use of BT-23" do
    @peppol "urn:fdc:peppol.eu:2017:poacc:billing:01:1.0"

    test "a foreign code is emitted as-is by default" do
      inv = %{sample_invoice() | business_process: @peppol}

      assert {:ok, xml} = Facturx.build(inv)
      assert xml =~ "<ram:ID>#{@peppol}</ram:ID>"
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "a parsed foreign document rebuilds with no special option" do
      {:ok, xml} = Facturx.build(%{sample_invoice() | business_process: @peppol})

      {:ok, parsed} = Facturx.parse(xml)
      assert parsed.business_process == @peppol
      assert {:ok, _} = Facturx.build(parsed)
    end

    test "opting in rejects the same foreign code" do
      assert {:error, {:invalid_business_process, @peppol}} =
               Facturx.build(%{sample_invoice() | business_process: @peppol},
                 validate_business_process: true
               )
    end

    test "the flag is read for truthiness, not matched literally" do
      inv = %{sample_invoice() | business_process: @peppol}

      # A forwarded `opts[:strict]` arriving as nil must mean "off", not crash or
      # accidentally enable the check.
      assert {:ok, _} = Facturx.build(inv, validate_business_process: nil)

      assert {:error, {:invalid_business_process, @peppol}} =
               Facturx.build(inv, validate_business_process: :yes)
    end
  end

  # BT-8's code list is imposed by EN 16931 (BR-CL-06), not by France: the
  # bundled Schematron restricts ram:DueDateTypeCode to code list id=28.
  describe "BT-8 code list" do
    test "the three standard codes are accepted" do
      assert Facturx.vat_point_date_codes() == ~w(5 29 72)

      for code <- Facturx.vat_point_date_codes() do
        inv = %{sample_invoice() | tax_due_date_type_code: code}
        assert {:ok, xml} = Facturx.build(inv)
        assert xml =~ "<ram:DueDateTypeCode>#{code}</ram:DueDateTypeCode>"
        assert {:ok, :valid} = Facturx.validate_xsd(xml)
        assert {:ok, ^inv} = Facturx.parse(xml)
      end
    end

    test "a code outside the list is rejected, even though the XSD would accept it" do
      # "3"/"35"/"432" belong to UNTDID 2005 (UBL), not 2475 (CII) — a classic mix-up.
      for bad <- ["3", "35", "432", "1", "AA"] do
        assert {:error, {:invalid_vat_point_date_code, ^bad}} =
                 Facturx.build(%{sample_invoice() | tax_due_date_type_code: bad})
      end
    end

    test "BT-8 validation is not affected by validate_business_process: false" do
      assert {:error, {:invalid_vat_point_date_code, "3"}} =
               Facturx.build(%{sample_invoice() | tax_due_date_type_code: "3"},
                 validate_business_process: false
               )
    end

    test "a nonconformant third-party code can be rebuilt with the opt-out" do
      inv = %{sample_invoice() | tax_due_date_type_code: "35"}

      assert {:error, {:invalid_vat_point_date_code, "35"}} = Facturx.build(inv)

      assert {:ok, xml} = Facturx.build(inv, validate_vat_point_date: false)
      assert xml =~ "<ram:DueDateTypeCode>35</ram:DueDateTypeCode>"
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "a document-level code with no VAT breakdown is refused, not dropped" do
      inv = %{sample_invoice() | tax_breakdown: [], tax_due_date_type_code: "5"}

      assert {:error, {:vat_point_date_unemittable, "5"}} = Facturx.build(inv)
    end

    test "a per-entry code is validated too" do
      inv = %{
        sample_invoice()
        | tax_due_date_type_code: nil,
          tax_breakdown: [%{type: "VAT", category: "S", due_date_type_code: "3"}]
      }

      assert {:error, {:invalid_vat_point_date_code, "3"}} = Facturx.build(inv)
    end
  end

  # EN 16931 allows BT-8 to differ per VAT breakdown entry (French rule S1.13 does
  # not). Collapsing divergent codes onto one value would silently misstate when
  # VAT becomes chargeable, so they are preserved per entry.
  describe "per-entry BT-8" do
    defp two_rates(code_a, code_b) do
      %{
        sample_invoice()
        | tax_due_date_type_code: nil,
          tax_breakdown: [
            %{type: "VAT", category: "S", rate: Decimal.new("20.00"), due_date_type_code: code_a},
            %{type: "VAT", category: "S", rate: Decimal.new("5.50"), due_date_type_code: code_b}
          ]
      }
    end

    test "divergent codes survive a round-trip instead of being unified" do
      inv = two_rates("29", "72")
      {:ok, xml} = Facturx.build(inv)

      assert xml =~ "<ram:DueDateTypeCode>29</ram:DueDateTypeCode>"
      assert xml =~ "<ram:DueDateTypeCode>72</ram:DueDateTypeCode>"
      assert {:ok, :valid} = Facturx.validate_xsd(xml)

      assert {:ok, parsed} = Facturx.parse(xml)
      assert Enum.map(parsed.tax_breakdown, & &1[:due_date_type_code]) == ["29", "72"]
      # not hoisted, since the entries disagree
      assert parsed.tax_due_date_type_code == nil
      assert parsed == inv

      # and rebuilding does not flatten them
      {:ok, again} = Facturx.build(parsed)
      assert again == xml
    end

    test "uniform codes are hoisted to the document level (S1.13 shape)" do
      {:ok, xml} = Facturx.build(two_rates("5", "5"))
      {:ok, parsed} = Facturx.parse(xml)

      assert parsed.tax_due_date_type_code == "5"
      assert Enum.all?(parsed.tax_breakdown, &(not Map.has_key?(&1, :due_date_type_code)))
    end

    test "a per-entry code overrides the document-level one" do
      inv = %{
        sample_invoice()
        | tax_due_date_type_code: "5",
          tax_breakdown: [
            %{type: "VAT", category: "S", rate: Decimal.new("20.00")},
            %{type: "VAT", category: "S", rate: Decimal.new("5.50"), due_date_type_code: "72"}
          ]
      }

      {:ok, xml} = Facturx.build(inv)

      codes =
        Regex.scan(~r|<ram:DueDateTypeCode>(\d+)</ram:DueDateTypeCode>|, xml,
          capture: :all_but_first
        )

      assert List.flatten(codes) == ["5", "72"]
    end
  end

  # Blocks added after the first French-mandate pass. All live in the bundled XSD
  # already; the risk is element order, which validate_xsd/2 is what pins.
  describe "notes, invoicing period, gross price and VAT exemption" do
    defp enriched do
      %{
        sample_invoice()
        | notes: [
            %{content: "Escompte 2% sous 8 jours", subject_code: "AAB"},
            %{content: "Sans code sujet"}
          ],
          billing_period: %{start_date: ~D[2026-07-01], end_date: ~D[2026-07-31]}
      }
    end

    test "everything together still validates against the XSD" do
      {:ok, xml} = Facturx.build(enriched())
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
    end

    test "notes keep CII's Content-before-SubjectCode order (BT-22 then BT-21)" do
      {:ok, xml} = Facturx.build(enriched())

      assert xml =~
               "<ram:IncludedNote><ram:Content>Escompte 2% sous 8 jours</ram:Content>" <>
                 "<ram:SubjectCode>AAB</ram:SubjectCode></ram:IncludedNote>"

      # a note without a subject code is still valid
      assert xml =~
               "<ram:IncludedNote><ram:Content>Sans code sujet</ram:Content></ram:IncludedNote>"
    end

    test "the invoicing period sits after the VAT breakdown" do
      {:ok, xml} = Facturx.build(enriched())

      tax = :binary.match(xml, "ram:ApplicableHeaderTradeSettlement")
      period = :binary.match(xml, "ram:BillingSpecifiedPeriod")
      terms = :binary.match(xml, "ram:SpecifiedTradePaymentTerms")
      assert elem(tax, 0) < elem(period, 0)
      assert elem(period, 0) < elem(terms, 0)
    end

    test "a partial period emits only the date given" do
      inv = %{sample_invoice() | billing_period: %{start_date: ~D[2026-07-01]}}
      {:ok, xml} = Facturx.build(inv)

      assert xml =~ "ram:StartDateTime"
      refute xml =~ "ram:EndDateTime"
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "an empty period map emits nothing rather than an empty container" do
      {:ok, xml} = Facturx.build(%{sample_invoice() | billing_period: %{}})

      refute xml =~ "BillingSpecifiedPeriod"
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
    end

    test "gross price precedes net price, with the discount as an allowance" do
      inv =
        put_in(sample_invoice().lines, [
          %{
            id: "1",
            name: "P",
            net_price: Decimal.new("90.00"),
            gross_price: Decimal.new("100.00"),
            price_discount: Decimal.new("10.00"),
            quantity: Decimal.new("2"),
            unit: "C62",
            vat_category: "S",
            vat_rate: Decimal.new("20.00"),
            line_total: Decimal.new("180.00")
          }
        ])

      {:ok, xml} = Facturx.build(inv)

      gross = :binary.match(xml, "ram:GrossPriceProductTradePrice")
      net = :binary.match(xml, "ram:NetPriceProductTradePrice")
      assert elem(gross, 0) < elem(net, 0)
      # false = allowance, not a charge
      assert xml =~
               "<ram:ChargeIndicator><udt:Indicator>false</udt:Indicator></ram:ChargeIndicator>"

      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "a discount without a gross price is dropped, since CII needs the amount" do
      inv =
        put_in(sample_invoice().lines, [
          %{
            id: "1",
            name: "P",
            net_price: Decimal.new("90.00"),
            # no :gross_price, so this has nowhere to go
            price_discount: Decimal.new("10.00"),
            quantity: Decimal.new("2"),
            unit: "C62",
            vat_category: "S",
            vat_rate: Decimal.new("20.00"),
            line_total: Decimal.new("180.00")
          }
        ])

      {:ok, xml} = Facturx.build(inv)

      refute xml =~ "GrossPriceProductTradePrice"
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
    end

    # Exempt throughout, lines included: BR-E-01 requires a line in category E for
    # an E breakdown to be legitimate, and the schematron does check that.
    test "BT-120 and BT-121 land on either side of BasisAmount/CategoryCode" do
      inv = %{
        sample_invoice()
        | tax_due_date_type_code: nil,
          lines: [
            %{
              id: "1",
              name: "Livraison intracommunautaire",
              net_price: Decimal.new("200.00"),
              quantity: Decimal.new("1"),
              unit: "C62",
              vat_category: "E",
              vat_rate: Decimal.new("0.00"),
              line_total: Decimal.new("200.00")
            }
          ],
          tax_breakdown: [
            %{
              type: "VAT",
              category: "E",
              rate: Decimal.new("0.00"),
              basis: Decimal.new("200.00"),
              calculated: Decimal.new("0.00"),
              exemption_reason: "Exonération art. 262 ter I",
              exemption_reason_code: "VATEX-EU-IC"
            }
          ],
          totals: %{
            line_total: Decimal.new("200.00"),
            tax_basis_total: Decimal.new("200.00"),
            tax_total: Decimal.new("0.00"),
            grand_total: Decimal.new("200.00"),
            due_payable: Decimal.new("200.00")
          }
      }

      {:ok, xml} = Facturx.build(inv)

      assert xml =~
               "<ram:TypeCode>VAT</ram:TypeCode>" <>
                 "<ram:ExemptionReason>Exonération art. 262 ter I</ram:ExemptionReason>" <>
                 "<ram:BasisAmount>200.00</ram:BasisAmount>" <>
                 "<ram:CategoryCode>E</ram:CategoryCode>" <>
                 "<ram:ExemptionReasonCode>VATEX-EU-IC</ram:ExemptionReasonCode>"

      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "the whole enriched invoice round-trips" do
      inv = enriched()
      {:ok, xml} = Facturx.build(inv)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end
  end

  # BG-3 — what a final invoice points at to net off earlier down payments, i.e.
  # the B4/S4/M4 frameworks.
  describe "preceding invoice references (BG-3)" do
    defp final_invoice do
      %{
        sample_invoice()
        | business_process: "S4",
          preceding_invoices: [
            %{number: "F-2026-042", issue_date: ~D[2026-06-15]},
            # BT-26 is optional, so a bare number must work
            %{number: "F-2026-043"}
          ]
      }
    end

    test "validates and round-trips" do
      inv = final_invoice()
      {:ok, xml} = Facturx.build(inv)

      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    # FormattedIssueDateTime is qdt:FormattedDateTimeType, so its child is
    # qdt:DateTimeString — every other date in the document is udt. Getting this
    # wrong produces XML the XSD rejects.
    test "BT-26 uses the qdt namespace, not udt" do
      {:ok, xml} = Facturx.build(final_invoice())

      assert xml =~
               "<ram:FormattedIssueDateTime>" <>
                 ~s(<qdt:DateTimeString format="102">20260615</qdt:DateTimeString>) <>
                 "</ram:FormattedIssueDateTime>"

      refute xml =~ "<ram:FormattedIssueDateTime><udt:"
    end

    test "the reference sits after the monetary summation, as the sequence demands" do
      {:ok, xml} = Facturx.build(final_invoice())

      summation = :binary.match(xml, "SpecifiedTradeSettlementHeaderMonetarySummation")
      ref = :binary.match(xml, "ram:InvoiceReferencedDocument")
      assert elem(summation, 0) < elem(ref, 0)
    end

    test "several references are emitted, order preserved" do
      {:ok, xml} = Facturx.build(final_invoice())

      assert length(String.split(xml, "<ram:InvoiceReferencedDocument>")) - 1 == 2
      first = :binary.match(xml, "F-2026-042")
      second = :binary.match(xml, "F-2026-043")
      assert elem(first, 0) < elem(second, 0)
    end

    test "no reference emits nothing" do
      {:ok, xml} = Facturx.build(sample_invoice())
      refute xml =~ "InvoiceReferencedDocument"
    end
  end

  # The last five items of the regulatory core.
  describe "tax representative, VAT group, full address, line note, accounting currency" do
    defp complete_invoice do
      d = &Decimal.new/1

      %{
        sample_invoice()
        | # facture in USD, VAT accounted in EUR — the two currencies must differ,
          # the schematron telling BT-110 from BT-111 by their currencyID
          currency: "USD",
          tax_currency: "EUR",
          # BT-29d — SIREN of an assujetti unique. The scheme default is written into
          # the XML, so it comes back on parse; set it to keep the round-trip exact.
          # Map.merge, not %{map | …}: the update syntax requires existing keys.
          seller:
            Map.merge(sample_invoice().seller, %{
              global_id: "987654321",
              global_scheme: "0231"
            }),
          # BG-11 — what matters is its BT-63 VAT id
          tax_representative: %{
            name: "Repr Fiscal SARL",
            vat: "FR55555555555",
            address: %{line_one: "9 bd", postcode: "13001", city: "Marseille", country: "FR"}
          },
          ship_to: %{
            name: "Entrepôt",
            address: %{
              line_one: "3 ch",
              line_two: "Bât. B",
              line_three: "Quai 4",
              postcode: "31000",
              city: "Toulouse",
              country: "FR",
              country_subdivision: "Occitanie"
            }
          },
          lines: [
            %{
              id: "1",
              name: "P",
              net_price: d.("100.00"),
              quantity: d.("2"),
              unit: "C62",
              vat_category: "S",
              vat_rate: d.("20.00"),
              line_total: d.("200.00"),
              note: "Livré en 2 colis"
            }
          ],
          totals: %{
            line_total: d.("200.00"),
            tax_basis_total: d.("200.00"),
            tax_total: d.("40.00"),
            tax_total_in_tax_currency: d.("36.50"),
            grand_total: d.("240.00"),
            due_payable: d.("240.00")
          }
      }
    end

    test "all five validate and round-trip together" do
      inv = complete_invoice()
      {:ok, xml} = Facturx.build(inv)

      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "BT-29d carries scheme 0231, and precedes the name" do
      {:ok, xml} = Facturx.build(complete_invoice())

      assert xml =~ ~s(<ram:GlobalID schemeID="0231">987654321</ram:GlobalID>)

      # Scope to the seller: ram:Name also names a product, and lines come first.
      [seller] = Regex.run(~r|<ram:SellerTradeParty>.*?</ram:SellerTradeParty>|s, xml)
      global = :binary.match(seller, "ram:GlobalID")
      name = :binary.match(seller, "ram:Name")
      assert elem(global, 0) < elem(name, 0)
    end

    test "the tax representative follows the buyer" do
      {:ok, xml} = Facturx.build(complete_invoice())

      buyer = :binary.match(xml, "ram:BuyerTradeParty")
      rep = :binary.match(xml, "ram:SellerTaxRepresentativeTradeParty")
      assert elem(buyer, 0) < elem(rep, 0)
      assert xml =~ "<ram:ID schemeID=\"VA\">FR55555555555</ram:ID>"
    end

    test "the address emits its lines in order, subdivision after the country" do
      {:ok, xml} = Facturx.build(complete_invoice())

      assert xml =~
               "<ram:LineOne>3 ch</ram:LineOne>" <>
                 "<ram:LineTwo>Bât. B</ram:LineTwo>" <>
                 "<ram:LineThree>Quai 4</ram:LineThree>" <>
                 "<ram:CityName>Toulouse</ram:CityName>" <>
                 "<ram:CountryID>FR</ram:CountryID>" <>
                 "<ram:CountrySubDivisionName>Occitanie</ram:CountrySubDivisionName>"
    end

    # EN 16931 does not allow ram:SubjectCode on a line note — that is
    # EXT-FR-FE-183, a French extension. Emitting one gets the invoice rejected, so
    # :note is a plain string with no way to ask for it.
    test "the line note carries content only, no subject code" do
      {:ok, xml} = Facturx.build(complete_invoice())

      assert xml =~
               "<ram:IncludedNote><ram:Content>Livré en 2 colis</ram:Content></ram:IncludedNote>"

      [line] =
        Regex.run(
          ~r|<ram:AssociatedDocumentLineDocument>.*?</ram:AssociatedDocumentLineDocument>|s,
          xml
        )

      refute line =~ "SubjectCode"
    end

    test "BT-111 without BT-6 is refused, with a domain error" do
      inv = %{complete_invoice() | tax_currency: nil}

      assert {:error, {:tax_currency_missing, :tax_total_in_tax_currency}} =
               Facturx.build(inv)
    end

    # Identical currencies make BT-110 and BT-111 indistinguishable — the XSD is
    # happy, the schematron is not (BR-53, cascading into BR-CO-15).
    test "BT-6 identical to the invoice currency is refused" do
      inv = %{complete_invoice() | tax_currency: "USD"}

      assert {:error, {:tax_currency_not_distinct, "USD"}} = Facturx.build(inv)
    end

    # The two are the same element; only @currencyID separates them, so parsing must
    # not rely on document order.
    test "BT-110 and BT-111 are matched by currency, not by position" do
      inv = complete_invoice()
      {:ok, xml} = Facturx.build(inv)

      swapped =
        String.replace(
          xml,
          ~s(<ram:TaxTotalAmount currencyID="USD">40.00</ram:TaxTotalAmount>) <>
            ~s(<ram:TaxTotalAmount currencyID="EUR">36.50</ram:TaxTotalAmount>),
          ~s(<ram:TaxTotalAmount currencyID="EUR">36.50</ram:TaxTotalAmount>) <>
            ~s(<ram:TaxTotalAmount currencyID="USD">40.00</ram:TaxTotalAmount>)
        )

      refute swapped == xml, "the fixture should contain both totals"
      {:ok, parsed} = Facturx.parse(swapped)
      assert Decimal.equal?(parsed.totals.tax_total, Decimal.new("40.00"))
      assert Decimal.equal?(parsed.totals.tax_total_in_tax_currency, Decimal.new("36.50"))
    end

    # 0231 means "SIREN of a French assujetti unique" (BT-29d), which the annexe puts
    # on the seller alone. Defaulting it everywhere would mislabel a buyer's GLN.
    test "the 0231 scheme default applies to the seller only" do
      inv =
        put_in(
          sample_invoice().buyer,
          Map.put(sample_invoice().buyer, :global_id, "5790000435975")
        )

      {:ok, xml} = Facturx.build(inv)

      assert xml =~ "<ram:GlobalID>5790000435975</ram:GlobalID>"
      refute xml =~ ~s(<ram:GlobalID schemeID="0231">5790000435975</ram:GlobalID>)
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "BT-6 precedes the invoice currency, and BT-111 is the second VAT total" do
      {:ok, xml} = Facturx.build(complete_invoice())

      assert xml =~
               "<ram:TaxCurrencyCode>EUR</ram:TaxCurrencyCode>" <>
                 "<ram:InvoiceCurrencyCode>USD</ram:InvoiceCurrencyCode>"

      assert xml =~
               ~s(<ram:TaxTotalAmount currencyID="USD">40.00</ram:TaxTotalAmount>) <>
                 ~s(<ram:TaxTotalAmount currencyID="EUR">36.50</ram:TaxTotalAmount>)
    end
  end

  # BG-26 — the period a line covers. Same SpecifiedPeriodType as BG-14, so the
  # emitter is reused; what needed checking is where it lands in the line.
  describe "line billing period (BG-26)" do
    defp line_with_period do
      d = &Decimal.new/1

      put_in(sample_invoice().lines, [
        %{
          id: "1",
          name: "Abonnement",
          net_price: d.("100.00"),
          quantity: d.("2"),
          unit: "C62",
          vat_category: "S",
          vat_rate: d.("20.00"),
          line_total: d.("200.00"),
          billing_period: %{start_date: ~D[2026-07-01], end_date: ~D[2026-07-31]},
          allowances: [%{amount: d.("5.00"), reason: "Remise"}]
        }
      ])
    end

    test "validates and round-trips" do
      inv = line_with_period()
      {:ok, xml} = Facturx.build(inv)

      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "sits between the line tax and the line allowances" do
      {:ok, xml} = Facturx.build(line_with_period())

      [line] =
        Regex.run(
          ~r|<ram:SpecifiedLineTradeSettlement>.*?</ram:SpecifiedLineTradeSettlement>|s,
          xml
        )

      tax = :binary.match(line, "ram:ApplicableTradeTax")
      period = :binary.match(line, "ram:BillingSpecifiedPeriod")
      allowance = :binary.match(line, "ram:SpecifiedTradeAllowanceCharge")
      assert elem(tax, 0) < elem(period, 0)
      assert elem(period, 0) < elem(allowance, 0)
    end

    test "a line period is independent of the document one" do
      inv = %{line_with_period() | billing_period: %{start_date: ~D[2026-01-01]}}
      {:ok, xml} = Facturx.build(inv)

      assert length(String.split(xml, "<ram:BillingSpecifiedPeriod>")) - 1 == 2
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "no line period emits nothing in the line" do
      {:ok, xml} = Facturx.build(sample_invoice())
      refute xml =~ "BillingSpecifiedPeriod"
    end
  end

  # BG-20/BG-21 at document level, BG-27/BG-28 on a line — one CII element for all
  # four, told apart by ChargeIndicator.
  describe "allowances and charges (BG-20/21, BG-27/28)" do
    # Arithmetic the schematron actually checks: lines 200, allowance 20, charge 5,
    # so basis = 185, VAT 20% = 37, prepaid 50, due = 172 (BR-CO-11/12/13/16).
    defp with_allowances do
      d = &Decimal.new/1

      %{
        sample_invoice()
        | allowances: [
            %{
              amount: d.("20.00"),
              basis_amount: d.("200.00"),
              percent: d.("10.00"),
              vat_category: "S",
              vat_rate: d.("20.00"),
              reason: "Remise commerciale",
              reason_code: "95"
            }
          ],
          charges: [
            %{
              amount: d.("5.00"),
              vat_category: "S",
              vat_rate: d.("20.00"),
              reason: "Frais de port"
            }
          ],
          tax_breakdown: [
            %{
              type: "VAT",
              category: "S",
              rate: d.("20.00"),
              basis: d.("185.00"),
              calculated: d.("37.00")
            }
          ],
          totals: %{
            line_total: d.("200.00"),
            allowance_total: d.("20.00"),
            charge_total: d.("5.00"),
            tax_basis_total: d.("185.00"),
            tax_total: d.("37.00"),
            grand_total: d.("222.00"),
            prepaid: d.("50.00"),
            due_payable: d.("172.00")
          }
      }
    end

    test "validates and round-trips, allowances and charges kept apart" do
      inv = with_allowances()
      {:ok, xml} = Facturx.build(inv)

      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, parsed} = Facturx.parse(xml)
      assert parsed == inv
      assert [%{reason: "Remise commerciale"}] = parsed.allowances
      assert [%{reason: "Frais de port"}] = parsed.charges
    end

    test "ChargeIndicator distinguishes the two" do
      {:ok, xml} = Facturx.build(with_allowances())

      assert length(String.split(xml, "<udt:Indicator>false</udt:Indicator>")) - 1 == 1
      assert length(String.split(xml, "<udt:Indicator>true</udt:Indicator>")) - 1 == 1
    end

    # TradeAllowanceChargeType puts ReasonCode before Reason, the reverse of the BT
    # numbering (BT-97 reason, BT-98 code).
    test "ReasonCode precedes Reason" do
      {:ok, xml} = Facturx.build(with_allowances())

      assert xml =~
               "<ram:ReasonCode>95</ram:ReasonCode>" <>
                 "<ram:Reason>Remise commerciale</ram:Reason>"
    end

    # BT-107 (allowances) precedes BT-108 (charges) in the numbering, but CII emits
    # ChargeTotalAmount first.
    test "ChargeTotalAmount is emitted before AllowanceTotalAmount" do
      {:ok, xml} = Facturx.build(with_allowances())

      assert xml =~
               "<ram:ChargeTotalAmount>5.00</ram:ChargeTotalAmount>" <>
                 "<ram:AllowanceTotalAmount>20.00</ram:AllowanceTotalAmount>"
    end

    test "prepaid and rounding land either side of the grand total" do
      d = &Decimal.new/1
      inv = put_in(with_allowances().totals[:rounding], d.("0.01"))
      {:ok, xml} = Facturx.build(inv)

      assert xml =~
               "<ram:RoundingAmount>0.01</ram:RoundingAmount>" <>
                 "<ram:GrandTotalAmount>222.00</ram:GrandTotalAmount>" <>
                 "<ram:TotalPrepaidAmount>50.00</ram:TotalPrepaidAmount>"

      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "line-level allowances sit between the tax and the line summation" do
      d = &Decimal.new/1

      inv =
        put_in(sample_invoice().lines, [
          %{
            id: "1",
            name: "P",
            net_price: d.("100.00"),
            quantity: d.("2"),
            unit: "C62",
            vat_category: "S",
            vat_rate: d.("20.00"),
            line_total: d.("200.00"),
            allowances: [%{amount: d.("5.00"), reason: "Remise ligne"}],
            charges: [%{amount: d.("2.00"), reason: "Emballage"}]
          }
        ])

      {:ok, xml} = Facturx.build(inv)

      [line] =
        Regex.run(
          ~r|<ram:SpecifiedLineTradeSettlement>.*?</ram:SpecifiedLineTradeSettlement>|s,
          xml
        )

      tax = :binary.match(line, "ram:ApplicableTradeTax")
      ac = :binary.match(line, "ram:SpecifiedTradeAllowanceCharge")
      summation = :binary.match(line, "SpecifiedTradeSettlementLineMonetarySummation")
      assert elem(tax, 0) < elem(ac, 0)
      assert elem(ac, 0) < elem(summation, 0)

      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "no allowance or charge emits nothing" do
      {:ok, xml} = Facturx.build(sample_invoice())
      refute xml =~ "SpecifiedTradeAllowanceCharge"
      refute xml =~ "AllowanceTotalAmount"
    end
  end

  # BG-16 — how the invoice is to be paid. Sub-blocks have differing requirements:
  # the debtor account and the institution each have a required child, the creditor
  # account has none, so an empty one must not be emitted at all.
  describe "payment means (BG-16)" do
    defp with_means(means), do: %{sample_invoice() | payment_means: means}

    test "a SEPA credit transfer emits account then institution, and round-trips" do
      inv =
        with_means([
          %{
            type_code: "58",
            iban: "FR7630006000011234567890189",
            account_name: "ACME SARL",
            bic: "BNPAFRPPXXX"
          }
        ])

      {:ok, xml} = Facturx.build(inv)

      assert xml =~
               "<ram:PayeePartyCreditorFinancialAccount>" <>
                 "<ram:IBANID>FR7630006000011234567890189</ram:IBANID>" <>
                 "<ram:AccountName>ACME SARL</ram:AccountName>" <>
                 "</ram:PayeePartyCreditorFinancialAccount>"

      assert xml =~
               "<ram:PayeeSpecifiedCreditorFinancialInstitution>" <>
                 "<ram:BICID>BNPAFRPPXXX</ram:BICID>"

      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "payment means precede the VAT breakdown" do
      {:ok, xml} = Facturx.build(with_means([%{type_code: "58", iban: "FR76"}]))

      # Scope to the header block: lines carry their own ram:ApplicableTradeTax and
      # are emitted first, so searching the whole document compares the wrong two.
      [settlement] =
        Regex.run(
          ~r|<ram:ApplicableHeaderTradeSettlement>.*?</ram:ApplicableHeaderTradeSettlement>|s,
          xml
        )

      currency = :binary.match(settlement, "ram:InvoiceCurrencyCode")
      means = :binary.match(settlement, "SpecifiedTradeSettlementPaymentMeans")
      tax = :binary.match(settlement, "ram:ApplicableTradeTax")
      assert elem(currency, 0) < elem(means, 0)
      assert elem(means, 0) < elem(tax, 0)
    end

    test "a direct debit carries the payer account (BT-91)" do
      inv = with_means([%{type_code: "59", payer_iban: "FR7630006000011234567890189"}])
      {:ok, xml} = Facturx.build(inv)

      assert xml =~
               "<ram:PayerPartyDebtorFinancialAccount>" <>
                 "<ram:IBANID>FR7630006000011234567890189</ram:IBANID>"

      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "a non-IBAN account uses ProprietaryID" do
      inv = with_means([%{type_code: "30", account_id: "00012345678"}])
      {:ok, xml} = Facturx.build(inv)

      assert xml =~ "<ram:ProprietaryID>00012345678</ram:ProprietaryID>"
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "several means are emitted, order preserved" do
      inv =
        with_means([
          %{type_code: "58", iban: "FR76"},
          %{type_code: "20", information: "Chèque"}
        ])

      {:ok, xml} = Facturx.build(inv)

      assert length(String.split(xml, "<ram:SpecifiedTradeSettlementPaymentMeans>")) - 1 == 2
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    # Every child of CreditorFinancialAccountType is optional, so without maybe/2
    # this would emit an empty container and trip PEPPOL-EN16931-R008.
    test "a bare type code emits no account container" do
      inv = with_means([%{type_code: "10"}])
      {:ok, xml} = Facturx.build(inv)

      assert xml =~ "<ram:TypeCode>10</ram:TypeCode>"
      refute xml =~ "PayeePartyCreditorFinancialAccount"
      refute xml =~ "ApplicableTradeSettlementFinancialCard"
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end

    test "no payment means emits nothing" do
      {:ok, xml} = Facturx.build(sample_invoice())
      refute xml =~ "SpecifiedTradeSettlementPaymentMeans"
    end
  end

  # Rule G1.60 — a cross-field constraint between BT-23 and BT-3, so neither the
  # XSD nor the EN 16931 schematron catches it: without this check the first sign
  # would be a platform refusing the invoice.
  describe "G1.60: final-invoice frameworks vs down-payment type codes" do
    defp built?(business_process, type_code) do
      inv = %{sample_invoice() | business_process: business_process, type_code: type_code}

      case Facturx.build(inv, validate_business_process: true) do
        {:ok, _} -> :ok
        {:error, reason} -> reason
      end
    end

    test "every forbidden pairing is rejected" do
      for framework <- ~w(B4 S4 M4), type <- ~w(386 500 503) do
        assert {:final_invoice_type_conflict, %{business_process: ^framework, type_code: ^type}} =
                 built?(framework, type),
               "#{framework} + #{type} should have been rejected"
      end
    end

    test "a final invoice with an ordinary type code is fine" do
      for framework <- ~w(B4 S4 M4), type <- ~w(380 381 384) do
        assert :ok = built?(framework, type)
      end
    end

    # The legitimate down payment: type 386 belongs with a *standard* framework,
    # since the invoice is the down payment rather than what follows it.
    test "a down-payment invoice under a standard framework is fine" do
      for framework <- ~w(B1 S1 M1 B2 S2 M2), type <- ~w(386 500 503) do
        assert :ok = built?(framework, type)
      end
    end

    test "the check rides on validate_business_process, so it is off by default" do
      inv = %{sample_invoice() | business_process: "S4", type_code: "386"}

      assert {:ok, _} = Facturx.build(inv)
      assert {:ok, _} = Facturx.build(inv, validate_business_process: false)

      assert {:error, {:final_invoice_type_conflict, _}} =
               Facturx.build(inv, validate_business_process: true)
    end

    test "config enables it like the closed list" do
      # covered in Facturx.CIIConfigTest for the env-mutating path; here just check
      # the two checks are independent of each other
      inv = %{sample_invoice() | business_process: "X9", type_code: "386"}

      assert {:error, {:invalid_business_process, "X9"}} =
               Facturx.build(inv, validate_business_process: true)
    end
  end

  # "" is a plausible value from a form field or a NOT NULL DEFAULT '' column.
  describe "empty-string codes are treated as absent" do
    test "an empty BT-23 emits no element and round-trips" do
      inv = %{sample_invoice() | business_process: ""}

      assert {:ok, xml} = Facturx.build(inv, validate_business_process: true)
      refute xml =~ "BusinessProcessSpecifiedDocumentContextParameter"
      assert {:ok, parsed} = Facturx.parse(xml)
      assert parsed.business_process == nil
    end

    test "an empty BT-8 emits no element" do
      inv = %{sample_invoice() | tax_due_date_type_code: ""}

      assert {:ok, xml} = Facturx.build(inv)
      refute xml =~ "DueDateTypeCode"
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
    end
  end

  describe "parse/1" do
    test "is the inverse of build (semantic round-trip)" do
      inv = sample_invoice()
      {:ok, xml} = Facturx.build(inv)
      assert {:ok, parsed} = Facturx.parse(xml)
      assert parsed == inv
    end

    test "errors on malformed XML" do
      assert {:error, _} = Facturx.parse("<not-closed>")
    end

    test "tolerates malformed amounts and dates without crashing" do
      xml = """
      <?xml version="1.0"?>
      <rsm:CrossIndustryInvoice
          xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"
          xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"
          xmlns:udt="urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100">
        <rsm:ExchangedDocument>
          <ram:ID>X</ram:ID>
          <ram:IssueDateTime><udt:DateTimeString>20261301</udt:DateTimeString></ram:IssueDateTime>
        </rsm:ExchangedDocument>
        <rsm:SupplyChainTradeTransaction>
          <ram:ApplicableHeaderTradeSettlement>
            <ram:SpecifiedTradeSettlementHeaderMonetarySummation>
              <ram:GrandTotalAmount>N/A</ram:GrandTotalAmount>
            </ram:SpecifiedTradeSettlementHeaderMonetarySummation>
          </ram:ApplicableHeaderTradeSettlement>
        </rsm:SupplyChainTradeTransaction>
      </rsm:CrossIndustryInvoice>
      """

      assert {:ok, inv} = Facturx.parse(xml)
      # month 13 is not a real date -> nil, not a crash
      assert inv.issue_date == nil
      # unparseable amount -> dropped, not a crash
      assert Map.get(inv.totals, :grand_total) == nil
    end
  end

  # Exercises the real reference document (gitignored, personal data). Asserts
  # only structural facts — no personal data is written into this test file.
  describe "against the reference fixture" do
    @describetag :local
    @golden Path.expand("../fixtures/local/harness/cii.xml", __DIR__)

    test "parses a real EN 16931 CII and round-trips it" do
      unless File.exists?(@golden), do: raise("missing fixture: #{@golden}")
      {:ok, inv} = Facturx.parse(File.read!(@golden))

      assert inv.profile == :en16931
      assert inv.currency == "EUR"
      assert length(inv.lines) == 1
      assert Decimal.equal?(inv.totals.grand_total, inv.totals.due_payable)
      assert is_map(inv.seller) and is_map(inv.buyer)

      # build -> parse is stable on real data too. Third-party documents may carry
      # any BT-23 value, which the default (validation off) accommodates.
      {:ok, xml} = Facturx.build(inv)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end
  end
end
