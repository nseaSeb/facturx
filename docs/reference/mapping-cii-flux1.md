# Annexe B — Mapping des données réglementaires (Flux 1) vers CII

Table de correspondance complète entre les **données réglementaires du Flux 1**
(e-invoicing) et les chemins CII, avec l'état de couverture par `Facturx.CII`.

- **Source** : *Annexe 1 — Format sémantique FE e-invoicing — Flux 1 — v1.2*
  (onglet « FE - Flux 1 - CII »), spécifications externes B2B **v3.2** du
  30/04/2026, publiées par la DGFiP. Voir [Annexe A](reforme-fr.md) pour la
  provenance exacte et la méthode de vérification.
- **Card.** : cardinalité sémantique PPF. `1..1` / `1..n` = donnée obligatoire.
- **Traj.** : trajectoire — `D` = DEMARRAGE (exigé dès l'entrée en vigueur),
  `C` = CIBLE (échéance ultérieure).
- **Émis** : ✅ = produit par `Facturx.CII.build/2` ; — = non produit à ce jour.

> Les chemins sont reproduits depuis l'annexe. Seule correction apportée : une
> parenthèse fermante orpheline après certains `@format` (coquille de la source).

## Couverture complète, et à quelle condition

**Les 116 données sont émises.** Il n'y a plus de ligne `—`.

Mais 20 d'entre elles — les 19 extensions françaises `EXT-FR-FE-*` et le
conteneur de note de ligne `BT-127-00` — n'existent **qu'en profil `:extended`**.
Elles ne font pas partie de l'EN 16931, dont le XSD rejette tout élément hors
profil ; c'est pourquoi le XSD EXTENDED est embarqué en plus
(`priv/xsd/extended/`), avec son schematron.

Concrètement : `Facturx.build(inv, profile: :extended)` produit les 116 données,
`Facturx.build(inv)` en produit 96 et laisse tomber les 20 autres — sans erreur,
délibérément, plutôt que de fabriquer un document que la plateforme rejetterait.

> **Ce qu'un profil autorise ne dépend pas de l'appelant.** `BT-127-00` (note de
> ligne répétée) et `EXT-FR-FE-183` (son code sujet) ne sont émis qu'en
> `:extended` ; en EN 16931, `Facturx.CII.build/2` ne garde qu'une note et retire
> le code sujet, plutôt que de produire un document qui serait rejeté. Les lignes
> `✅` de ce tableau décrivent donc la trajectoire CIBLE.

> La colonne **Émis** est écrite à la main, mais elle n'est plus livrée à
> elle-même : `Facturx.MappingAnnexeTest` lit ce tableau et évalue chacun des 116
> chemins contre le document produit par `Facturx.CII.build/2`. Ce qui est vérifié
> est le **nombre d'occurrences**, pas la simple présence : neuf chemins sont
> revendiqués par deux lignes chacun — `BT-110` et `BT-111` sont tous deux
> `ram:TaxTotalAmount`, distingués par leur seul `currencyID`, et les quatre
> familles remise/charge par leur seul `ChargeIndicator`. Un chemin portant moins
> de nœuds qu'il n'a de lignes cochées, ou un chemin sans ligne cochée qui porte
> quoi que ce soit, fait échouer la suite.
>
> ⚠️ Corollaire : toute donnée nouvellement émise doit être renseignée dans
> `Facturx.TestInvoice.maximal/0`, sinon sa ligne apparaît comme une dérive. Le
> document témoin est construit en `:extended`, la trajectoire que ce tableau
> décrit.

| ID | Card. | Traj. | Donnée | Émis | Chemin CII (relatif à `/rsm:CrossIndustryInvoice`) |
|---|---|---|---|---|---|
| `BT-1` | 1..1 | D | Numéro de facture | ✅ | `/rsm:ExchangedDocument/ram:ID` |
| `BT-2` | 1..1 | D | Date d'émission facture initiale / facture rectificative | ✅ | `/rsm:ExchangedDocument/ram:IssueDateTime/udt:DateTimeString` |
| `BT-2-1` | 1..1 | D | Format date | ✅ | `/rsm:ExchangedDocument/ram:IssueDateTime/udt:DateTimeString/@format` |
| `BT-3` | 1..1 | D | Code de type de facture | ✅ | `/rsm:ExchangedDocument/ram:TypeCode` |
| `BT-5` | 1..1 | D | Code de devise de la facture | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:InvoiceCurrencyCode` |
| `BT-8` | 0..1 | D | Code de date d'exigibilité de la taxe sur la valeur ajoutée | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:ApplicableTradeTax/ram:DueDateTypeCode` |
| `BT-9` | 0..1 | D | Date d'échéance | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradePaymentTerms/ram:DueDateDateTime/udt:DateTimeString` |
| `BT-9-1` | 0..1 | D | Format date | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradePaymentTerms/ram:DueDateDateTime/udt:DateTimeString@format` |
| `BG-1` | 0..n | D | NOTE DE FACTURE | ✅ | `/rsm:ExchangedDocument/ram:IncludedNote` |
| `BT-21` | 0..1 | D | Code du sujet de la note de facture | ✅ | `/rsm:ExchangedDocument/ram:IncludedNote/ram:SubjectCode` |
| `BT-22` | 1..1 | D | Note de facture | ✅ | `/rsm:ExchangedDocument/ram:IncludedNote/ram:Content` |
| `BG-2` | 1..1 | D | CONTROLE DU PROCESSUS | ✅ | `/rsm:ExchangedDocumentContext` |
| `BT-23` | 1..1 | D | Type de processus métier (cadre de facturation) | ✅ | `/rsm:ExchangedDocumentContext/ram:BusinessProcessSpecifiedDocumentContextParameter/ram:ID` |
| `BT-24` | 1..1 | D | Type de profil (e-invoicing, e-reporting, facture etc..) | ✅ | `/rsm:ExchangedDocumentContext/ram:GuidelineSpecifiedDocumentContextParameter/ram:ID` |
| `BG-3` | 0..n | D | RÉFÉRENCE À UNE FACTURE ANTÉRIEURE | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:InvoiceReferencedDocument` |
| `BT-25` | 1..1 | D | Numéro de la facture antérieure | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:InvoiceReferencedDocument/ram:IssuerAssignedID` |
| `BT-26` | 0..1 | C | Date d'émission de facture antérieure | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:InvoiceReferencedDocument/ram:FormattedIssueDateTime/qdt:DateTimeString` |
| `BT-26-1` | 0..1 | C | Format date | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:InvoiceReferencedDocument/ram:FormattedIssueDateTime/qdt:DateTimeString@format` |
| `BG-4` | 1..1 | D | VENDEUR | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:SellerTradeParty` |
| `BT-29d` | 0..1 | D | Identifiant du vendeur (Assujetti unique) | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:SellerTradeParty/ram:GlobalID` |
| `BT-29d-1` | 1..1 | D | Identifiant du schéma (Assujetti unique) | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:SellerTradeParty/ram:GlobalID/@schemeID` |
| `BT-30` | 1..1 | D | Numéro de SIREN | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:SellerTradeParty/ram:SpecifiedLegalOrganization/ram:ID` |
| `BT-30-1` | 1..1 | D | Identifiant du schéma | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:SellerTradeParty/ram:SpecifiedLegalOrganization/ram:ID/@schemeID` |
| `BT-31` | 0..1 | D | Identifiant à la TVA du vendeur | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:SellerTradeParty/ram:SpecifiedTaxRegistration/ram:ID` |
| `BT-31-0` | 1..1 | D | Qualifiant d'Identifiant à la TVA du Vendeur | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:SellerTradeParty/ram:SpecifiedTaxRegistration/ram:ID/@schemeID = "VA"` |
| `BG-5` | 1..1 | D | ADRESSE POSTALE DU VENDEUR | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:SellerTradeParty/ram:PostalTradeAddress` |
| `BT-40` | 1..1 | D | Code de pays du vendeur | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:SellerTradeParty/ram:PostalTradeAddress/ram:CountryID` |
| `BG-7` | 1..1 | D | ACHETEUR | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:BuyerTradeParty` |
| `BT-47` | 1..1 | D | Numéro de SIREN | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:BuyerTradeParty/ram:SpecifiedLegalOrganization/ram:ID` |
| `BT-47-1` | 1..1 | D | Identifiant du schéma | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:BuyerTradeParty/ram:SpecifiedLegalOrganization/ram:ID/@schemeID` |
| `BT-48` | 0..1 | D | Identifiant à la TVA de l'acheteur | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:BuyerTradeParty/ram:SpecifiedTaxRegistration/ram:ID` |
| `BT-48-0` | 1..1 | D | Qualifiant d'Identifiant fiscal de l'acheteur | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:BuyerTradeParty/ram:SpecifiedTaxRegistration/ram:ID/@schemeID = "VA"` |
| `BG-8` | 1..1 | D | ADRESSE POSTALE DE L'ACHETEUR | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:BuyerTradeParty/ram:PostalTradeAddress` |
| `BT-55` | 1..1 | D | Code de pays de l'acheteur | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:BuyerTradeParty/ram:PostalTradeAddress/ram:CountryID` |
| `BG-11` | 0..1 | D | REPRÉSENTANT FISCAL DU VENDEUR | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:SellerTaxRepresentativeTradeParty` |
| `BT-63` | 1..1 | D | Identifiant à la TVA du représentant fiscal du vendeur | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:SellerTaxRepresentativeTradeParty/ram:SpecifiedTaxRegistration/ram:ID` |
| `BT-63-0` | 1..1 | D | Identifiant du schéma de l'identifiant TVA du représentant fiscal | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeAgreement/ram:SellerTaxRepresentativeTradeParty/ram:SpecifiedTaxRegistration/ram:ID/@schemeID = "VA"` |
| `BG-13` | 0..1 | D | INFORMATIONS DE LIVRAISON | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeDelivery/ram:ShipToTradeParty` |
| `BT-72` | 0..1 | D | Date effective de livraison | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeDelivery/ram:ActualDeliverySupplyChainEvent/ram:OccurrenceDateTime/udt:DateTimeString` |
| `BT-72-1` | 0..1 | D | Format date | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeDelivery/ram:ActualDeliverySupplyChainEvent/ram:OccurrenceDateTime/udt:DateTimeString@format` |
| `BG-14` | 0..1 | D | PERIODE DE FACTURATION | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:BillingSpecifiedPeriod` |
| `BT-73` | 0..1 | D | Date de début de période de facturation | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:BillingSpecifiedPeriod/ram:StartDateTime/udt:DateTimeString` |
| `BT-73-1` | 1..1 | D | Format date | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:BillingSpecifiedPeriod/ram:StartDateTime/udt:DateTimeString@format` |
| `BT-74` | 0..1 | D | Date de fin de période de facturation | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:BillingSpecifiedPeriod/ram:EndDateTime/udt:DateTimeString` |
| `BT-74-1` | 1..1 | D | Format date | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:BillingSpecifiedPeriod/ram:EndDateTime/udt:DateTimeString@format` |
| `BG-15` | 0..1 | C | ADRESSE DE LIVRAISON | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress` |
| `BT-75` | 0..1 | C | Adresse de livraison - Ligne 1 | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress/ram:LineOne` |
| `BT-76` | 0..1 | C | Adresse de livraison - Ligne 2 | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress/ram:LineTwo` |
| `BT-165` | 0..1 | C | Adresse de livraison - Ligne 3 | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress/ram:LineThree` |
| `BT-77` | 0..1 | C | Localité Adresse de livraison | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress/ram:CityName` |
| `BT-78` | 0..1 | C | Code postal Adresse de livraison | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress/ram:PostcodeCode` |
| `BT-79` | 0..1 | C | Subdivision du pays | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress/ram:CountrySubDivisionName` |
| `BT-80` | 1..1 | C | Code de pays | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress/ram:CountryID` |
| `BG-20` | 0..n | C | REMISES AU NIVEAU DU DOCUMENT | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeAllowanceCharge ChargeIndicator=false` |
| `BT-92` | 1..1 | C | Montant de la remise au niveau document | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeAllowanceCharge/ram:ActualAmount` |
| `BT-95` | 1..1 | C | Code de type de TVA de la remise au niveau du document | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeAllowanceCharge/ram:CategoryTradeTax/ram:CategoryCode with ram:TypeCode = "VAT"` |
| `BT-95-0` | 1..1 | C | Qualifiant d'identifiant du code type de TVA de la remise au niveau du document | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeAllowanceCharge/ram:CategoryTradeTax/ram:TypeCode = "VAT"` |
| `BT-96` | 0..1 | C | Taux de TVA de la remise au niveau du document | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeAllowanceCharge/ram:CategoryTradeTax/ram:RateApplicablePercent` |
| `BG-21` | 0..n | C | CHARGES OU FRAIS AU NIVEAU DU DOCUMENT | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeAllowanceCharge ChargeIndicator=true` |
| `BT-99` | 1..1 | C | Montant des charges ou frais au niveau document | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeAllowanceCharge/ram:ActualAmount` |
| `BT-102` | 1..1 | C | Code de type de TVA des charges ou frais au niveau du document | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeAllowanceCharge/ram:CategoryTradeTax/ram:CategoryCode` |
| `BT-102-0` | 1..1 | C | Qualifiant d'identifiant du code type de TVA des charges ou frais au niveau du document | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeAllowanceCharge/ram:CategoryTradeTax/ram:TypeCode = "VAT"` |
| `BT-103` | 0..1 | C | Taux de TVA des charges ou frai au niveau du document | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeAllowanceCharge/ram:CategoryTradeTax/ram:RateApplicablePercent` |
| `BG-22` | 1..1 | D | TOTAUX DU DOCUMENT | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeSettlementHeaderMonetarySummation` |
| `BT-109` | 1..1 | D | Montant total de la facture hors TVA | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeSettlementHeaderMonetarySummation/ram:TaxBasisTotalAmount` |
| `BT-110` | 1,11..1 | D | Montant total de TVA de la facture | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeSettlementHeaderMonetarySummation/ram:TaxTotalAmount` |
| `BT-110-1` | 1..1 | D | Code devise | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeSettlementHeaderMonetarySummation/ram:TaxTotalAmount/@currencyID` |
| `BT-111` | 0..1 | D | Montant total de TVA de la facture exprimée (devise de comptabilisation) | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeSettlementHeaderMonetarySummation/ram:TaxTotalAmount` |
| `BT-111-1` | 1..1 | D | Code devise | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:SpecifiedTradeSettlementHeaderMonetarySummation/ram:TaxTotalAmount/@currencyID` |
| `BG-23` | 1..n | D | VENTILATION DE LA TVA | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:ApplicableTradeTax` |
| `BT-116` | 1..1 | D | Base d'imposition du type de TVA | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:ApplicableTradeTax/ram:BasisAmount` |
| `BT-117` | 1..1 | D | Montant de la TVA pour chaque type de TVA | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:ApplicableTradeTax/ram:CalculatedAmount` |
| `BT-118` | 1..1 | D | Code de type de TVA | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:ApplicableTradeTax/ram:CategoryCode with ram:TypeCode = "VAT"` |
| `BT-118-0` | 1..1 | D | Qualifiant d'identifiant du code type de TVA | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:ApplicableTradeTax/ram:TypeCode = ‘VAT’` |
| `BT-119` | 1..1 | D | Taux de type de TVA | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:ApplicableTradeTax/ram:RateApplicablePercent` |
| `BT-120` | 0..1 | D | Motif d'exonération de la TVA | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:ApplicableTradeTax/ram:ExemptionReason` |
| `BT-121` | 0..1 | D | Code de motif d'exonération de la TVA | ✅ | `/rsm:SupplyChainTradeTransaction/ram:ApplicableHeaderTradeSettlement/ram:ApplicableTradeTax/ram:ExemptionReasonCode` |
| `BG-25` | 1..n | C | LIGNE DE FACTURE | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem` |
| `BT-127-00` | 0..n | C | Note de ligne de facture | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:AssociatedDocumentLineDocument/ram:IncludedNote` |
| `EXT-FR-FE-183` | 0..1 | C | Code sujet de la note de ligne | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:AssociatedDocumentLineDocument/ram:IncludedNote/ram:SubjectCode` |
| `BT-127` | 0..1 | C | Note de ligne de facture | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:AssociatedDocumentLineDocument/ram:IncludedNote/ram:Content` |
| `BT-129` | 1..1 | C | Quantité facturée | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:BilledQuantity` |
| `BT-130` | 1..1 | C | Code de l'unité de mesure de la quantité facturée | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:BilledQuantity/@unitCode` |
| `EXT-FR-FE-BG-06` | 0..1 | C | REFERENCE A FACTURE ANTERIEURE EN LIGNE (permet de gérer les reprises en ligne, notamment sur factures d'acompte) | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeSettlement/ram:InvoiceReferencedDocument` |
| `EXT-FR-FE-136` | 0..1 | C | ID de la facture antérieure | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeSettlement/ram:InvoiceReferencedDocument/ram:IssuerAssignedID` |
| `EXT-FR-FE-138` | 0..1 | C | Date de facture antérieure | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeSettlement/ram:InvoiceReferencedDocument/ram:FormattedIssueDateTime/qdt:DateTimeString` |
| `EXT-FR-FE-138-1` | 0..1 | C | Format date | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeSettlement/ram:InvoiceReferencedDocument/ram:FormattedIssueDateTime/qdt:DateTimeString@format` |
| `EXT-FR-FE-BG-10` | 0..1 | C | Détail de l'adresse de livraison à la ligne (Gestion du multi livraison) | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:ShipToTradeParty` |
| `EXT-FR-FE-149` | 0..1 | C | Nom du lieu de livraison | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:ShipToTradeParty/ram:Name` |
| `EXT-FR-FE-150` | 0..1 | C | ADRESSE POSTALE DE LIVRAISON A LA LIGNE | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress` |
| `EXT-FR-FE-151` | 0..1 | C | Ligne Adresse 1 (si différent entête) | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress/ram:LineOne` |
| `EXT-FR-FE-152` | 0..1 | C | Ligne adresse 2 (si différent entête) | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress/ram:LineTwo` |
| `EXT-FR-FE-153` | 0..1 | C | Ligne Adresse 3 (si différent entête) | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress/ram:LineThree` |
| `EXT-FR-FE-154` | 0..1 | C | Ville de livraison (si différent entête) | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress/ram:CityName` |
| `EXT-FR-FE-155` | 0..1 | C | Code Postal de livraison (si différent entête) | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress/ram:PostcodeCode` |
| `EXT-FR-FE-156` | 0..1 | C | Subdivision Pays (si différent entête) | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress/ram:CountrySubDivisionName` |
| `EXT-FR-FE-157` | 1..1 | C | Code Pays (si différent entête) | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:ShipToTradeParty/ram:PostalTradeAddress/ram:CountryID` |
| `EXT-FR-FE-BG-11` | 0..1 | C | Détail sur la livraison réelle | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:ActualDeliverySupplyChainEvent` |
| `EXT-FR-FE-158-0` | 0..1 | C | Date de livraison à la ligne | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:ActualDeliverySupplyChainEvent/ram:OccurrenceDateTime` |
| `EXT-FR-FE-158` | 0..1 | C | Date de livraison à la ligne valeur | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:ActualDeliverySupplyChainEvent/ram:OccurrenceDateTime/udt:DateTimeString` |
| `EXT-FR-FE-158-1` | 0..1 | C | Format date | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeDelivery/ram:ActualDeliverySupplyChainEvent/ram:OccurrenceDateTime/udt:DateTimeString/@format` |
| `BG-26` | 0..1 | C | PERIODE DE FACTURATION D'UNE LIGNE | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeSettlement/ram:BillingSpecifiedPeriod` |
| `BT-134` | 0..1 | C | Date de début de période de facturation d'une ligne | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeSettlement/ram:BillingSpecifiedPeriod/ram:StartDateTime/udt:DateTimeString` |
| `BT-134-1` | 1..1 | C | Format date | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeSettlement/ram:BillingSpecifiedPeriod/ram:StartDateTime/udt:DateTimeString@format` |
| `BT-135` | 0..1 | C | Date de fin de période de facturation d'une ligne | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeSettlement/ram:BillingSpecifiedPeriod/ram:EndDateTime/udt:DateTimeString` |
| `BT-135-1` | 1..1 | C | Format date | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeSettlement/ram:BillingSpecifiedPeriod/ram:EndDateTime/udt:DateTimeString@format` |
| `BG-27` | 0..n | C | REMISE DE LIGNE DE FACTURE | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeSettlement/ram:SpecifiedTradeAllowanceCharge with ChargeIndicator = 'false'` |
| `BT-136` | 1..1 | C | Montant d'une remise, hors TVA | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeSettlement/ram:SpecifiedTradeAllowanceCharge/ram:ActualAmount` |
| `BG-28` | 0..n | C | CHARGE OU FRAIS D'UNE LIGNE DE FACTURE | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeSettlement/ram:SpecifiedTradeAllowanceCharge with ChargeIndicator = 'true'` |
| `BT-141` | 1..1 | C | Montant des charges ou frais | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeSettlement/ram:SpecifiedTradeAllowanceCharge/ram:ActualAmount` |
| `BG-29` | 1..1 | C | DÉTAIL DU PRIX | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeAgreement` |
| `BT-146` | 1..1 | C | Prix net de l'article | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeAgreement/ram:NetPriceProductTradePrice/ram:ChargeAmount` |
| `BT-147` | 0..1 | C | Rabais sur le prix de l'article | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeAgreement/ram:GrossPriceProductTradePrice/ram:AppliedTradeAllowanceCharge/ram:ActualAmount with ChargeIndicator = « False »` |
| `BT-148` | 1..1 | C | Prix brut de l'article | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedLineTradeAgreement/ram:GrossPriceProductTradePrice/ram:ChargeAmount with ChargeIndicator = « False »` |
| `BG-31` | 1..1 | C | INFORMATION SUR L'ARTICLE | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedTradeProduct` |
| `BT-153` | 1..1 | C | Nom de l'article | ✅ | `/rsm:SupplyChainTradeTransaction/ram:IncludedSupplyChainTradeLineItem/ram:SpecifiedTradeProduct/ram:Name` |

**Couverture** : 116 / 116 données réglementaires émises.
