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
