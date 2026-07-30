defmodule Facturx.ValidateTest do
  use ExUnit.Case, async: true

  describe "interpret/1 (SVRL report parsing)" do
    test "an empty schematron-output is valid" do
      svrl = ~s(<svrl:schematron-output xmlns:svrl="http://purl.oclc.org/dsdl/svrl"/>)
      assert Facturx.Validate.interpret(svrl) == {:ok, :valid}
    end

    test "collects failed-assert and successful-report as violations" do
      svrl = """
      <svrl:schematron-output xmlns:svrl="http://purl.oclc.org/dsdl/svrl">
        <svrl:fired-rule context="/x"/>
        <svrl:failed-assert test="exists(ram:ID)" location="/rsm:CrossIndustryInvoice">
          <svrl:text>[BR-01] An Invoice shall have a number.</svrl:text>
        </svrl:failed-assert>
        <svrl:successful-report test="warn" location="/y">
          <svrl:text>A warning fired.</svrl:text>
        </svrl:successful-report>
      </svrl:schematron-output>
      """

      assert {:error, {:invalid, violations}} = Facturx.Validate.interpret(svrl)

      assert violations == [
               %{
                 message: "[BR-01] An Invoice shall have a number.",
                 location: "/rsm:CrossIndustryInvoice",
                 test: "exists(ram:ID)",
                 flag: nil
               },
               # no flag means error, not warning — defaulting to "invalid" is the
               # safe way round
               %{message: "A warning fired.", location: "/y", test: "warn", flag: nil}
             ]
    end

    test "errors on malformed SVRL" do
      assert {:error, {:invalid_svrl, _}} = Facturx.Validate.interpret("<not-closed>")
    end
  end

  # Severity comes from the SVRL `flag` attribute. Getting this wrong made
  # validate/2 report every conformant invoice as invalid, since the EN 16931
  # schematron always warns about the empty ram:ApplicableHeaderTradeDelivery
  # that CII requires.
  describe "interpret/1 severity handling" do
    defp svrl(assertions) do
      """
      <svrl:schematron-output xmlns:svrl="http://purl.oclc.org/dsdl/svrl">
        #{assertions}
      </svrl:schematron-output>
      """
    end

    @r008 ~s|<svrl:failed-assert test="false" flag="warning" location="/a">| <>
            ~s|<svrl:text>[PEPPOL-EN16931-R008]-Document MUST not contain empty elements.</svrl:text>| <>
            ~s|</svrl:failed-assert>|

    @br01 ~s|<svrl:failed-assert test="exists(ram:ID)" location="/b">| <>
            ~s|<svrl:text>[BR-01] An Invoice shall have a number.</svrl:text>| <>
            ~s|</svrl:failed-assert>|

    test "warnings alone leave the document valid" do
      assert {:ok, {:valid_with_warnings, [w]}} = Facturx.Validate.interpret(svrl(@r008))
      assert w.flag == "warning"
      assert w.message =~ "R008"
    end

    test "info is non-blocking too" do
      info =
        ~s|<svrl:successful-report test="t" flag="info"><svrl:text>fyi</svrl:text></svrl:successful-report>|

      assert {:ok, {:valid_with_warnings, [%{flag: "info"}]}} =
               Facturx.Validate.interpret(svrl(info))
    end

    test "one error makes the document invalid, and warnings are not reported as errors" do
      assert {:error, {:invalid, errors}} = Facturx.Validate.interpret(svrl(@r008 <> @br01))
      assert [%{message: msg, flag: nil}] = errors
      assert msg =~ "BR-01"
    end

    test "an unknown flag counts as an error" do
      fatal =
        ~s|<svrl:failed-assert test="t" flag="fatal"><svrl:text>boom</svrl:text></svrl:failed-assert>|

      assert {:error, {:invalid, [%{flag: "fatal"}]}} = Facturx.Validate.interpret(svrl(fatal))
    end
  end

  describe "validate/2 without a network call" do
    test "refuses a profile whose schematron is not bundled" do
      assert Facturx.validate("<xml/>", profile: :extended) ==
               {:error, {:schematron_not_bundled, :extended}}
    end
  end

  # Live round-trip against a real Saxon server. Set FACTURX_SAXON_URL to its
  # /transform endpoint (e.g. http://localhost:5055/transform) to run it.
  describe "against a live Saxon server" do
    @describetag :saxon

    @xsl_invalid """
    <?xml version="1.0"?>
    <xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:svrl="http://purl.oclc.org/dsdl/svrl">
      <xsl:template match="/">
        <svrl:schematron-output>
          <svrl:failed-assert test="t" location="/root"><svrl:text>boom</svrl:text></svrl:failed-assert>
        </svrl:schematron-output>
      </xsl:template>
    </xsl:stylesheet>
    """

    @xsl_valid """
    <?xml version="1.0"?>
    <xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:svrl="http://purl.oclc.org/dsdl/svrl">
      <xsl:template match="/"><svrl:schematron-output/></xsl:template>
    </xsl:stylesheet>
    """

    setup do
      case System.get_env("FACTURX_SAXON_URL") do
        nil -> raise "set FACTURX_SAXON_URL to run :saxon tests"
        url -> {:ok, endpoint: url}
      end
    end

    test "returns :valid when the transform reports no assertions", %{endpoint: url} do
      assert Facturx.validate("<root/>", xsl: @xsl_valid, endpoint: url) == {:ok, :valid}
    end

    test "returns violations from the SVRL report", %{endpoint: url} do
      assert {:error, {:invalid, [%{message: "boom", location: "/root"}]}} =
               Facturx.validate("<root/>", xsl: @xsl_invalid, endpoint: url)
    end
  end

  # The tests above drive Saxon with toy stylesheets: they cover the transport and
  # the SVRL parsing, not a single EN 16931 rule. These ones run the *bundled*
  # schematron over invoices this library built — the only way a broken business
  # rule gets caught before a platform rejects the invoice.
  #
  # Needs a Saxon server started with --insecure; see docker/Dockerfile.
  # Set FACTURX_CODEDB_URL to resolve the code-list DB from the image instead of
  # over the network.
  describe "against the bundled EN 16931 schematron" do
    @describetag :saxon
    # Saxon recompiles the 644 KB stylesheet per request, and the upstream image
    # is amd64-only so it runs emulated on arm64.
    @describetag timeout: 300_000

    setup do
      case System.get_env("FACTURX_SAXON_URL") do
        nil ->
          raise "set FACTURX_SAXON_URL to run :saxon tests"

        url ->
          opts = [endpoint: url]

          opts =
            case System.get_env("FACTURX_CODEDB_URL") do
              nil -> opts
              codedb -> Keyword.put(opts, :codedb_url, codedb)
            end

          {:ok, opts: opts}
      end
    end

    defp invoice(extra \\ %{}) do
      d = &Decimal.new/1

      Map.merge(
        %Facturx.Invoice{
          number: "SCH-1",
          issue_date: ~D[2026-07-30],
          due_date: ~D[2026-08-29],
          # BR-FX-EN-04 wants BT-72, BG-14 or BG-26; BT-72 also keeps
          # ram:ApplicableHeaderTradeDelivery non-empty, so PEPPOL-R008 stays quiet.
          delivery_date: ~D[2026-07-30],
          seller: %{
            name: "ACME SARL",
            legal_id: "123456782",
            legal_scheme: "0002",
            vat: "FR12123456782",
            address: %{
              line_one: "1 rue de Rivoli",
              postcode: "75001",
              city: "Paris",
              country: "FR"
            }
          },
          buyer: %{
            name: "Client SAS",
            legal_id: "987654321",
            legal_scheme: "0002",
            vat: "FR98765432100",
            address: %{
              line_one: "2 place Bellecour",
              postcode: "69001",
              city: "Lyon",
              country: "FR"
            }
          },
          lines: [
            %{
              id: "1",
              name: "Prestation",
              net_price: d.("100.00"),
              quantity: d.("2"),
              unit: "C62",
              vat_category: "S",
              vat_rate: d.("20.00"),
              line_total: d.("200.00")
            }
          ],
          tax_breakdown: [
            %{
              type: "VAT",
              category: "S",
              rate: d.("20.00"),
              basis: d.("200.00"),
              calculated: d.("40.00")
            }
          ],
          totals: %{
            line_total: d.("200.00"),
            tax_basis_total: d.("200.00"),
            tax_total: d.("40.00"),
            grand_total: d.("240.00"),
            due_payable: d.("240.00")
          }
        },
        extra
      )
    end

    test "an invoice built by this library satisfies the business rules", %{opts: opts} do
      {:ok, xml} = Facturx.build(invoice())

      assert {:ok, :valid} = Facturx.validate(xml, opts)
    end

    test "the French BT-23/BT-8 fields break no rule", %{opts: opts} do
      {:ok, xml} =
        Facturx.build(invoice(%{business_process: "S1", tax_due_date_type_code: "5"}))

      assert {:ok, :valid} = Facturx.validate(xml, opts)
    end

    # This is the case the XSD cannot see: qdt:TimeReferenceCodeType is an
    # unrestricted xs:token, so only the schematron carries the code list. A
    # regression here means shipping invoices a platform will reject.
    test "a BT-8 outside UNTDID 2475 is rejected, though the XSD accepts it", %{opts: opts} do
      {:ok, xml} =
        Facturx.build(invoice(%{tax_due_date_type_code: "3"}), validate_vat_point_date: false)

      assert {:ok, :valid} = Facturx.validate_xsd(xml)

      assert {:error, {:invalid, errors}} = Facturx.validate(xml, opts)
      assert Enum.any?(errors, &(&1.message =~ "DueDateTypeCode"))
    end

    test "notes, invoicing period and gross price break no rule", %{opts: opts} do
      {:ok, xml} =
        Facturx.build(
          invoice(%{
            notes: [%{content: "Escompte 2% sous 8 jours", subject_code: "AAB"}],
            billing_period: %{start_date: ~D[2026-07-01], end_date: ~D[2026-07-31]},
            lines: [
              %{
                id: "1",
                name: "Prestation",
                net_price: Decimal.new("90.00"),
                gross_price: Decimal.new("100.00"),
                price_discount: Decimal.new("10.00"),
                quantity: Decimal.new("2"),
                unit: "C62",
                vat_category: "S",
                vat_rate: Decimal.new("20.00"),
                line_total: Decimal.new("180.00")
              }
            ],
            tax_breakdown: [
              %{
                type: "VAT",
                category: "S",
                rate: Decimal.new("20.00"),
                basis: Decimal.new("180.00"),
                calculated: Decimal.new("36.00")
              }
            ],
            totals: %{
              line_total: Decimal.new("180.00"),
              tax_basis_total: Decimal.new("180.00"),
              tax_total: Decimal.new("36.00"),
              grand_total: Decimal.new("216.00"),
              due_payable: Decimal.new("216.00")
            }
          })
        )

      assert {:ok, :valid} = Facturx.validate(xml, opts)
    end

    # BR-FX-EN-04 is not the general rule it reads as. Two limits, both checked in
    # the bundled XSL rather than assumed:
    #
    #   * its template only matches invoices whose seller *and* buyer are in DE, so
    #     it never fires on a French invoice;
    #   * its assertion is a conjunction — a line period satisfies only the first
    #     half, the second still wanting BT-72 or a non-empty delivery container.
    #
    # So this checks what is actually true: a line period is emitted and accepted,
    # with the only finding being the R008 warning about that empty container.
    test "a line period is accepted, R008 aside", %{opts: opts} do
      d = &Decimal.new/1

      {:ok, xml} =
        Facturx.build(
          invoice(%{
            delivery_date: nil,
            lines: [
              %{
                id: "1",
                name: "Abonnement",
                net_price: d.("100.00"),
                quantity: d.("2"),
                unit: "C62",
                vat_category: "S",
                vat_rate: d.("20.00"),
                line_total: d.("200.00"),
                billing_period: %{start_date: ~D[2026-07-01], end_date: ~D[2026-07-31]}
              }
            ]
          })
        )

      assert {:ok, {:valid_with_warnings, findings}} = Facturx.validate(xml, opts)
      assert Enum.all?(findings, &(&1.flag == "warning"))
      assert Enum.any?(findings, &(&1.message =~ "R008"))
    end

    # BR-CO-11/12/13/16 tie the allowance and charge totals to the entries and to
    # the tax basis. Only the schematron does this arithmetic, so it is the sole
    # guard against emitting an invoice whose totals do not add up.
    test "allowances, charges and their totals add up", %{opts: opts} do
      d = &Decimal.new/1

      # lines 200 − allowance 20 + charge 5 = basis 185; VAT 37; prepaid 50; due 172
      {:ok, xml} =
        Facturx.build(
          invoice(%{
            # BR-33/BR-38 want a reason on each entry, not just an amount
            allowances: [
              %{amount: d.("20.00"), vat_category: "S", vat_rate: d.("20.00"), reason: "Remise"}
            ],
            charges: [
              %{amount: d.("5.00"), vat_category: "S", vat_rate: d.("20.00"), reason: "Port"}
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
          })
        )

      assert {:ok, :valid} = Facturx.validate(xml, opts)
    end

    test "a total that contradicts its entries is rejected", %{opts: opts} do
      d = &Decimal.new/1

      # allowance_total claims 99 while the only allowance is 20
      {:ok, xml} =
        Facturx.build(
          invoice(%{
            allowances: [
              %{amount: d.("20.00"), vat_category: "S", vat_rate: d.("20.00"), reason: "Remise"}
            ],
            totals: %{
              line_total: d.("200.00"),
              allowance_total: d.("99.00"),
              tax_basis_total: d.("180.00"),
              tax_total: d.("36.00"),
              grand_total: d.("216.00"),
              due_payable: d.("216.00")
            }
          })
        )

      assert {:ok, :valid} = Facturx.validate_xsd(xml), "the XSD does no arithmetic"
      assert {:error, {:invalid, _}} = Facturx.validate(xml, opts)
    end

    # The last five core items together, and two traps only the schematron sees:
    # a line note must not carry ram:SubjectCode (that is EXT-FR-FE-183, a French
    # extension), and BT-6 must differ from the invoice currency or BT-110 and
    # BT-111 become indistinguishable — which cascades into BR-53 and BR-CO-15.
    test "tax representative, VAT group, full address, line note and BT-111", %{opts: opts} do
      d = &Decimal.new/1

      {:ok, xml} =
        Facturx.build(
          invoice(%{
            currency: "USD",
            tax_currency: "EUR",
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
          })
        )

      assert {:ok, :valid} = Facturx.validate(xml, opts)
    end

    test "payment means break no rule", %{opts: opts} do
      {:ok, xml} =
        Facturx.build(
          invoice(%{
            payment_means: [
              %{
                type_code: "58",
                iban: "FR7630006000011234567890189",
                account_name: "ACME SARL",
                bic: "BNPAFRPPXXX"
              }
            ]
          })
        )

      assert {:ok, :valid} = Facturx.validate(xml, opts)
    end

    # BR-51 caps BT-87 at 10 characters, per the PCI rule of showing at most the
    # first 6 and last 4 digits. The XSD accepts any length, so a masked
    # 16-character PAN looks fine right up to the platform rejecting it.
    test "an over-long card number is rejected by BR-51", %{opts: opts} do
      masked = fn id ->
        {:ok, xml} =
          Facturx.build(invoice(%{payment_means: [%{type_code: "48", card_id: id}]}))

        assert {:ok, :valid} = Facturx.validate_xsd(xml), "the XSD accepts any length"
        Facturx.validate(xml, opts)
      end

      # a full masked PAN is 16 characters — too long
      assert {:error, {:invalid, errors}} = masked.("************1234")
      assert Enum.any?(errors, &(&1.message =~ "BR-51"))

      # 6 leading + 4 trailing digits is the maximum PCI allows
      assert {:ok, :valid} = masked.("4012881881")
    end

    # The down-payment workflow end to end: a final invoice (framework S4) pointing
    # back at the down payment it nets off.
    test "a final invoice after a down payment satisfies the rules", %{opts: opts} do
      {:ok, xml} =
        Facturx.build(
          invoice(%{
            business_process: "S4",
            tax_due_date_type_code: "5",
            preceding_invoices: [%{number: "F-2026-042", issue_date: ~D[2026-06-15]}]
          })
        )

      assert {:ok, :valid} = Facturx.validate(xml, opts)
    end

    # BR-E-01 wants a line in category E behind an exempt VAT breakdown. The XSD
    # cannot see that, so only this test protects the BT-120/BT-121 path from
    # producing a plausible-looking but rejectable invoice.
    test "an exempt invoice with BT-120/BT-121 satisfies BR-E-01", %{opts: opts} do
      exempt = %{
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

      {:ok, xml} = Facturx.build(invoice(exempt))
      assert {:ok, :valid} = Facturx.validate(xml, opts)

      # ... and dropping the exempt line is what BR-E-01 rejects
      {:ok, bad} = Facturx.build(invoice(%{exempt | lines: []}))
      assert {:error, {:invalid, errors}} = Facturx.validate(bad, opts)
      assert Enum.any?(errors, &(&1.message =~ "BR-E-01"))
    end

    # Pins the severity split against the real ruleset: without delivery data CII
    # forces an empty ram:ApplicableHeaderTradeDelivery, which PEPPOL-EN16931-R008
    # flags as a warning. That must stay non-blocking.
    test "a warning-only document is valid, not invalid", %{opts: opts} do
      {:ok, xml} = Facturx.build(invoice(%{delivery_date: nil}))

      assert {:ok, {:valid_with_warnings, findings}} = Facturx.validate(xml, opts)
      assert Enum.all?(findings, &(&1.flag == "warning"))
      assert Enum.any?(findings, &(&1.message =~ "R008"))
    end
  end
end
