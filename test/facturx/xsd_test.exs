defmodule Facturx.XSDTest do
  use ExUnit.Case, async: true

  alias Facturx.Invoice

  defp sample_xml do
    inv = %Invoice{
      number: "INV-2026-001",
      issue_date: ~D[2026-07-24],
      currency: "EUR",
      seller: %{
        name: "ACME SARL",
        vat: "FR12345678900",
        address: %{line_one: "1 rue de Rivoli", postcode: "75001", city: "Paris", country: "FR"}
      },
      buyer: %{
        name: "Client SAS",
        vat: "FR98765432100",
        address: %{line_one: "2 place Bellecour", postcode: "69001", city: "Lyon", country: "FR"}
      },
      lines: [
        %{
          id: "1",
          name: "Service",
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

    {:ok, xml} = Facturx.build(inv)
    xml
  end

  test "a freshly built EN 16931 invoice is XSD-valid" do
    assert Facturx.validate_xsd(sample_xml()) == {:ok, :valid}
  end

  test "rejects a wrong data type (amount as text)" do
    bad =
      String.replace(
        sample_xml(),
        "<ram:GrandTotalAmount>240.00</ram:GrandTotalAmount>",
        "<ram:GrandTotalAmount>abc</ram:GrandTotalAmount>"
      )

    assert {:error, {:invalid, [_ | _]}} = Facturx.validate_xsd(bad)
  end

  test "rejects a missing mandatory element" do
    bad = String.replace(sample_xml(), "<ram:ID>INV-2026-001</ram:ID>", "", global: false)
    assert {:error, {:invalid, [_ | _]}} = Facturx.validate_xsd(bad)
  end

  test "rejects an unexpected element" do
    bad =
      String.replace(
        sample_xml(),
        "<rsm:ExchangedDocument>",
        "<rsm:ExchangedDocument><ram:Bogus>x</ram:Bogus>",
        global: false
      )

    assert {:error, {:invalid, [_ | _]}} = Facturx.validate_xsd(bad)
  end

  test "errors for a profile whose XSD is not bundled" do
    assert Facturx.validate_xsd(sample_xml(), profile: :extended) ==
             {:error, {:xsd_not_bundled, :extended}}
  end

  test "errors on malformed XML" do
    assert {:error, :malformed_xml} = Facturx.validate_xsd("<not-closed>")
  end

  describe "security (untrusted input)" do
    test "rejects a DTD/entity-expansion bomb without expanding it" do
      bomb = """
      <?xml version="1.0"?>
      <!DOCTYPE lolz [
        <!ENTITY lol "lol">
        <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
        <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
      ]>
      <rsm:CrossIndustryInvoice xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100">&lol3;</rsm:CrossIndustryInvoice>
      """

      # Returns immediately — the DOCTYPE is refused before any expansion.
      assert Facturx.validate_xsd(bomb) == {:error, :doctype_forbidden}
    end

    test "rejects an external-entity (XXE) document" do
      xxe = """
      <?xml version="1.0"?>
      <!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
      <rsm:CrossIndustryInvoice xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100">&xxe;</rsm:CrossIndustryInvoice>
      """

      assert Facturx.validate_xsd(xxe) == {:error, :doctype_forbidden}
    end
  end
end
