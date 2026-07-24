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

      # build -> parse is stable on real data too
      {:ok, xml} = Facturx.build(inv)
      assert {:ok, ^inv} = Facturx.parse(xml)
    end
  end
end
