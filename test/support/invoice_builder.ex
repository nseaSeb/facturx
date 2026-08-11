defmodule Facturx.TestInvoice do
  @moduledoc """
  A single invoice that exercises every data item `Facturx.CII.build/2` emits.

  It exists to let `Facturx.MappingAnnexeTest` check annexe B — the table in
  `docs/reference/mapping-cii-flux1.md`, whose "Émis" column is maintained by
  hand — against what the code actually produces. Anything added to `CII.build/2`
  must be populated here too, or the annexe row for it will read as a drift.

  The amounts are internally consistent (`BR-CO-10` to `BR-CO-16`), so the
  document is plausible enough to put in front of the schematron, not only the
  XSD.
  """

  alias Facturx.Invoice

  @doc "An invoice populating every field the builder knows how to emit."
  def maximal do
    d = &Decimal.new/1

    %Invoice{
      profile: :en16931,
      # B4 — final invoice after a down payment, which is what makes the
      # preceding-invoice reference and :prepaid below belong together. Rule
      # G1.60 only forbids pairing it with a down-payment type code (386/500/503).
      business_process: "B4",
      number: "FA-2026-0042",
      type_code: "380",
      issue_date: ~D[2026-03-15],
      due_date: ~D[2026-04-15],
      currency: "EUR",
      # BT-6 — must differ from :currency, the schematron telling BT-110 from
      # BT-111 by their currencyID alone.
      tax_currency: "USD",
      notes: [%{content: "Facture définitive après acompte.", subject_code: "AAI"}],
      seller: %{
        name: "Vendeur SAS",
        global_id: "987654321",
        global_scheme: "0231",
        legal_id: "123456789",
        legal_scheme: "0002",
        vat: "FR12345678901",
        address: %{
          line_one: "1 rue de la Paix",
          line_two: "Bâtiment C",
          line_three: "2e étage",
          postcode: "75002",
          city: "Paris",
          country: "FR",
          country_subdivision: "Île-de-France"
        },
        contact: %{name: "Alice Martin", phone: "+33123456789", email: "alice@vendeur.fr"}
      },
      buyer: %{
        name: "Acheteur SARL",
        legal_id: "987654321",
        legal_scheme: "0002",
        vat: "FR98765432109",
        address: %{
          line_one: "5 avenue des Champs",
          postcode: "69001",
          city: "Lyon",
          country: "FR"
        }
      },
      tax_representative: %{
        name: "Repr Fiscal SARL",
        vat: "FR55555555555",
        address: %{
          line_one: "9 boulevard du Port",
          postcode: "13001",
          city: "Marseille",
          country: "FR"
        }
      },
      ship_to: %{
        name: "Entrepôt Sud",
        address: %{
          line_one: "3 chemin des Docks",
          line_two: "Bâtiment B",
          line_three: "Quai 4",
          postcode: "31000",
          city: "Toulouse",
          country: "FR",
          country_subdivision: "Occitanie"
        }
      },
      delivery_date: ~D[2026-03-10],
      billing_period: %{start_date: ~D[2026-02-01], end_date: ~D[2026-02-28]},
      preceding_invoices: [%{number: "FA-2026-0007", issue_date: ~D[2026-01-31]}],
      payment_means: [
        %{
          type_code: "58",
          information: "Virement SEPA sous 30 jours",
          iban: "FR7630006000011234567890189",
          account_name: "Vendeur SAS",
          bic: "AGRIFRPP"
        }
      ],
      # Document level: -20.00 then +30.00, which :allowance_total and
      # :charge_total below must mirror exactly (BR-CO-11, BR-CO-12).
      allowances: [
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
          amount: d.("30.00"),
          basis_amount: d.("200.00"),
          percent: d.("15.00"),
          vat_category: "S",
          vat_rate: d.("20.00"),
          reason: "Frais de livraison",
          reason_code: "DL"
        }
      ],
      lines: [
        %{
          id: "1",
          name: "Prestation de conseil",
          gross_price: d.("110.00"),
          price_discount: d.("10.00"),
          net_price: d.("100.00"),
          quantity: d.("2"),
          unit: "C62",
          vat_category: "S",
          vat_rate: d.("20.00"),
          # 100 x 2, less the 5.00 allowance, plus the 15.00 charge
          line_total: d.("210.00"),
          billing_period: %{start_date: ~D[2026-02-01], end_date: ~D[2026-02-15]},
          # Two notes with subject codes: BT-127, BT-127-00 (the repeated
          # container) and EXT-FR-FE-183, none of which EN 16931 accepts. The
          # annexe test builds this invoice in both profiles for that reason.
          notes: [
            %{content: "Livré en deux lots", subject_code: "AAI"},
            %{content: "Garantie 24 mois", subject_code: "AAB"}
          ],
          # EXT-FR-FE-BG-06 — the down payment this line nets off. Singular: the
          # CII element is 0..1 at line level, unlike the document-level list.
          preceding_invoice: %{number: "FA-2026-0007", issue_date: ~D[2026-01-31]},
          # EXT-FR-FE-BG-10 / BG-11 — this line is delivered elsewhere, and on
          # another date, than the document-level delivery says.
          ship_to: %{
            name: "Chantier Nord",
            address: %{
              line_one: "12 rue du Port",
              line_two: "Zone B",
              line_three: "Hangar 3",
              postcode: "59000",
              city: "Lille",
              country: "FR",
              country_subdivision: "Hauts-de-France"
            }
          },
          delivery_date: ~D[2026-03-05],
          allowances: [%{amount: d.("5.00"), reason: "Geste commercial", reason_code: "95"}],
          charges: [%{amount: d.("15.00"), reason: "Frais de dossier", reason_code: "AAA"}]
        },
        # A second line in the exempt category: BR-E-01 wants one for the
        # exemption breakdown below to be accepted.
        %{
          id: "2",
          name: "Formation exonérée",
          net_price: d.("50.00"),
          quantity: d.("1"),
          unit: "C62",
          vat_category: "E",
          vat_rate: d.("0.00"),
          line_total: d.("50.00")
        }
      ],
      tax_breakdown: [
        %{
          type: "VAT",
          category: "S",
          rate: d.("20.00"),
          basis: d.("220.00"),
          calculated: d.("44.00")
        },
        %{
          type: "VAT",
          category: "E",
          rate: d.("0.00"),
          basis: d.("50.00"),
          calculated: d.("0.00"),
          exemption_reason: "Exonération article 261-4-4 du CGI",
          exemption_reason_code: "VATEX-EU-132-1I"
        }
      ],
      # BT-8 — applied to every breakdown entry that carries no code of its own,
      # rule S1.13 wanting a single value for the whole invoice.
      tax_due_date_type_code: "72",
      totals: %{
        line_total: d.("260.00"),
        charge_total: d.("30.00"),
        allowance_total: d.("20.00"),
        tax_basis_total: d.("270.00"),
        tax_total: d.("44.00"),
        tax_total_in_tax_currency: d.("47.96"),
        rounding: d.("0.00"),
        grand_total: d.("314.00"),
        prepaid: d.("100.00"),
        due_payable: d.("214.00")
      }
    }
  end
end
