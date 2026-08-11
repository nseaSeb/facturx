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
    assert Facturx.validate_xsd(sample_xml(), profile: :basic) ==
             {:error, {:xsd_not_bundled, :basic}}
  end

  describe "EXTENDED profile" do
    test "an EXTENDED document validates against its own bundled schema" do
      {:ok, xml} = Facturx.build(%{Facturx.TestInvoice.maximal() | profile: :extended})

      # The profile is read from the guideline URN, so no :profile option is
      # needed — the right schema is picked from the document itself.
      assert Facturx.Profile.detect(xml) == :extended
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
    end

    test "the EN 16931 schema still validates an EN 16931 document" do
      {:ok, xml} = Facturx.build(Facturx.TestInvoice.maximal())

      assert Facturx.Profile.detect(xml) == :en16931
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
    end

    # The schematron ships for EXTENDED too, so the failure mode is now a
    # missing server rather than a missing rule set. Asserted without a server:
    # anything but :schematron_not_bundled proves the XSL was found and read.
    # The :profile option and the struct field must not disagree: the guideline
    # URN comes from the resolved profile, and so must everything the profile
    # gates. Passing the option on an :en16931 struct used to emit an EXTENDED
    # URN while silently dropping the line notes it authorises.
    test "the :profile option decides, not the struct field" do
      inv = Facturx.TestInvoice.maximal()
      assert inv.profile == :en16931

      {:ok, xml} = Facturx.build(inv, profile: :extended)

      assert Facturx.Profile.detect(xml) == :extended
      assert {:ok, :valid} = Facturx.validate_xsd(xml)

      [line] =
        Regex.run(
          ~r|<ram:AssociatedDocumentLineDocument>.*?</ram:AssociatedDocumentLineDocument>|s,
          xml
        )

      assert length(Regex.scan(~r|<ram:IncludedNote>|, line)) == 2
      assert line =~ "<ram:SubjectCode>AAI</ram:SubjectCode>"
    end

    test "and the reverse: an EXTENDED struct built as EN 16931 stays valid" do
      inv = %{Facturx.TestInvoice.maximal() | profile: :extended}

      {:ok, xml} = Facturx.build(inv, profile: :en16931)

      assert Facturx.Profile.detect(xml) == :en16931
      # Would fail against the EN 16931 schema if the line notes had been emitted
      # as the struct field asked.
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
    end

    # EXT-FR-FE-BG-06. LineTradeSettlementType puts InvoiceReferencedDocument
    # after the monetary summation, as HeaderTradeSettlementType does at document
    # level — the order is imposed and the compiler says nothing about it.
    test "a line's preceding invoice follows the line summation" do
      {:ok, xml} = Facturx.build(Facturx.TestInvoice.maximal(), profile: :extended)

      [settlement] =
        Regex.run(
          ~r|<ram:SpecifiedLineTradeSettlement>.*?</ram:SpecifiedLineTradeSettlement>|s,
          xml
        )

      summation = :binary.match(settlement, "ram:SpecifiedTradeSettlementLineMonetarySummation")
      reference = :binary.match(settlement, "ram:InvoiceReferencedDocument")
      assert elem(summation, 0) < elem(reference, 0)

      # BT-26's quirk, inherited here: FormattedIssueDateTime is a
      # qdt:FormattedDateTimeType, so its child is qdt: and not udt:.
      assert settlement =~ ~s(<qdt:DateTimeString format="102">20260131</qdt:DateTimeString>)
    end

    test "and EN 16931 drops it rather than emit a rejected document" do
      {:ok, xml} = Facturx.build(Facturx.TestInvoice.maximal(), profile: :en16931)

      [settlement] =
        Regex.run(
          ~r|<ram:SpecifiedLineTradeSettlement>.*?</ram:SpecifiedLineTradeSettlement>|s,
          xml
        )

      refute settlement =~ "ram:InvoiceReferencedDocument"
      assert {:ok, :valid} = Facturx.validate_xsd(xml)
    end

    # `""` is truthy, so a blank first note used to take the single slot
    # EN 16931 allows and emit nothing, dropping the real note behind it — and
    # in EXTENDED it produced a bare <ram:IncludedNote/>.
    test "a blank line note is skipped, in both profiles" do
      inv = Facturx.TestInvoice.maximal()
      [line | rest] = inv.lines

      blank_first = %{
        line
        | notes: [%{content: "", subject_code: "AAB"}, %{content: "vraie note"}]
      }

      inv = %{inv | lines: [blank_first | rest]}

      for profile <- [:en16931, :extended] do
        {:ok, xml} = Facturx.build(inv, profile: profile)

        [doc_line] =
          Regex.run(
            ~r|<ram:AssociatedDocumentLineDocument>.*?</ram:AssociatedDocumentLineDocument>|s,
            xml
          )

        assert doc_line =~ "<ram:Content>vraie note</ram:Content>",
               "#{profile}: the note with content was dropped"

        refute doc_line =~ "<ram:IncludedNote/>"
        assert {:ok, :valid} = Facturx.validate_xsd(xml)
      end
    end

    test "and its schematron is bundled as well" do
      {:ok, xml} = Facturx.build(%{Facturx.TestInvoice.maximal() | profile: :extended})

      # Pointed at a closed port on purpose: the default suite stays offline
      # (that is what the :saxon tag is for), and reaching :saxon_unreachable
      # already proves the EXTENDED XSL was selected, found and read.
      assert {:error, {:saxon_unreachable, _}} =
               Facturx.validate(xml, endpoint: "http://127.0.0.1:1/transform")
    end

    test "a profile with no schematron still says so" do
      {:ok, xml} = Facturx.build(%{Facturx.TestInvoice.maximal() | profile: :basic})

      assert Facturx.validate(xml) == {:error, {:schematron_not_bundled, :basic}}
    end
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
