# Annexe A — Réforme française : BT-23 et BT-8

Ce document explique les deux données que la réforme française de la facturation
électronique ajoute par rapport à l'EN 16931 nu, où elles se placent dans le CII,
et comment `facturx` les expose. Il cite systématiquement ses sources : le sujet
est entouré de résumés de seconde main contradictoires, dont plusieurs affirment
des noms de champs et des codes qui n'existent pas (voir
[§5](#5-affirmations-courantes-qui-ne-résistent-pas-à-la-source)).

## 1. Sources primaires

Tout ce qui suit est vérifié dans le **dossier de spécifications externes B2B
v3.2**, publié par la DGFiP :

| Source | Contenu utilisé ici |
|---|---|
| `0 - Dossier de specifications externes FE - Dossier général_v3.2.pdf` | formats du socle (UBL, CII, Factur-X) |
| `2 - Annexes_v3.2/20260430_Annexe 1 - Format sémantique FE e-invoicing - Flux 1 - v1.2.xlsx` | données réglementaires, cardinalités, chemins CII, trajectoires → [Annexe B](mapping-cii-flux1.md) |
| `2 - Annexes_v3.2/20260430_Annexe 7 - Règles de gestion - V1.9.xlsx` | règles G1.02, G1.60, G1.43/G1.44/G1.67, S1.06, S1.13, P1.11, BR-CL-06, BR-CO-3 |
| `3 - XSD_v3.2/2 - E-invoicing/F1_{BASE,FULL}_CII_D22B/` | XSD de contrôle Base / Full, namespaces |

- Page de publication : <https://www.impots.gouv.fr/specifications-externes-b2b>
- Archive utilisée : `specifications-externes-v3.2.zip`, version **v3.2 du
  30/04/2026** (versions antérieures : v3.1 du 31/10/2025, v3.0 du 18/12/2024).
- Socle normatif AFNOR référencé par ces spécifications : **XP Z12-012**
  (formats et profils), **XP Z12-013** (API), **XP Z12-014** (cas d'usage B2B).

Les spécifications évoluent. En cas de doute, c'est le ZIP courant qui tranche,
pas ce document — et surtout pas un article de blog.

## 2. BT-23 — Cadre de facturation

C'est **la** donnée qui porte la nature de l'opération (biens / services /
mixte), et donc le régime d'exigibilité de la TVA.

- **Libellé officiel** : « Type de processus métier (cadre de facturation) ».
- **Cardinalité** : `1..1` — **obligatoire**, en trajectoire *DEMARRAGE*, et
  présente dans les deux profils XSD (Base **et** Full).
- **Chemin CII** :
  `/rsm:CrossIndustryInvoice/rsm:ExchangedDocumentContext/ram:BusinessProcessSpecifiedDocumentContextParameter/ram:ID`
- **Type** : texte, longueur 3.

Les valeurs autorisées sont fixées par la **règle G1.02** :

| Code | Signification |
|---|---|
| `B1` | Dépôt d'une facture de **bien** |
| `S1` | Dépôt d'une facture de **prestation de service** |
| `M1` | Dépôt d'une facture **double** (biens et services non accessoires l'un de l'autre) |
| `B2` | Facture de bien **déjà payée** |
| `S2` | Facture de prestation de service déjà payée |
| `M2` | Facture double déjà payée |
| `B4` | Facture **définitive** (après acompte) de bien |
| `S4` | Facture définitive (après acompte) de service |
| `M4` | Facture définitive (après acompte) double |
| `S5` | Dépôt par un **sous-traitant** d'une facture de prestation de service |
| `S6` | Dépôt par un **cotraitant** d'une facture de prestation de service |
| `B7` | Facture de bien ayant fait l'objet d'un **e-reporting** (TVA déjà collectée) |
| `S7` | Facture de service ayant fait l'objet d'un e-reporting (TVA déjà collectée) |

La lettre initiale porte la catégorie d'opération (**B**ien / **S**ervice /
**M**ixte) ; le chiffre porte la situation de facturation. Il n'existe pas de
code « biens et services » hors de la famille `M`.

**Règle G1.60**, contrainte croisée avec BT-3 (type de facture) : un cadre `B4`,
`S4` ou `M4` interdit les types `386` (facture d'acompte), `500` (facture
d'acompte auto-facturée) et `503` (avoir de facture d'acompte) — le cadre dit déjà
« facture définitive après acompte », le document ne peut donc pas en être un.
**Cette règle est appliquée** avec la liste fermée — voir
[§4](#4-ce-que-la-lib-fait-et-ne-fait-pas).

## 3. BT-8 — Option pour le paiement de la TVA d'après les débits

- **Libellé officiel** : « Code de date d'exigibilité de la taxe sur la valeur
  ajoutée ». L'annexe 1 précise son usage : *« Champ permettant de spécifier
  l'option pour le paiement de la taxe d'après les débits »*.
- **Cardinalité** : `0..1`, trajectoire *DEMARRAGE*.
- **Chemin CII** : `…/ram:ApplicableHeaderTradeSettlement/ram:ApplicableTradeTax/ram:DueDateTypeCode`
  — la donnée vit **dans** le bloc de ventilation de la TVA (BG-23).
- **Nomenclature** : UNTDID **2475** en CII (règle `BR-CL-06` : « MUST be coded
  using a *restriction* of UNTDID 2475 »). La règle `P1.11` mentionne aussi le
  subset UNTDID **2005**, qui est celui de la syntaxe **UBL** — ne pas confondre
  les deux jeux, c'est l'erreur la plus facile à commettre ici.

**Valeurs autorisées en CII** — la restriction est celle du Schematron EN 16931
embarqué dans ce dépôt (`priv/schematron/en16931/FACTUR-X_EN16931_codedb.xml`,
liste de codes `id=28`), appliquée par l'assertion `FX-SCH-A-000180` sur
`…/ApplicableTradeTax/ram:DueDateTypeCode` :

| Code | Fait générateur | Régime de TVA |
|---|---|---|
| `5` | date de la facture | **TVA sur les débits** (exigible à la facturation) |
| `29` | date de livraison | livraison de **biens** |
| `72` | date de paiement | **TVA à l'encaissement** |

⚠️ Les valeurs `3` / `35` / `432` que l'on voit souvent citées appartiennent à
UNTDID **2005** et ne sont donc **valides qu'en UBL**. Émises en CII, elles
passent le XSD (le type est un `xs:token` non énuméré) mais sont **rejetées par
le Schematron**, donc par la plateforme.

### Quel code selon votre régime ?

L'option pour les débits est **générale** : elle vaut pour l'ensemble des
factures émises (G1.43 / G1.44), et ne se choisit pas facture par facture. Une
entreprise ayant à la fois des biens et des services relève donc de plusieurs
faits générateurs, mais chaque facture n'en porte qu'un :

- **livraison de biens** → `29` (exigibilité à la livraison, aucune option
  possible) ;
- **prestations de services sans option** → `72` (exigibilité à l'encaissement,
  le régime par défaut) ;
- **prestations de services avec option pour les débits** → `5` (exigibilité à la
  facturation) ;
- **facture mixte** (`M1`…) → un seul code pour toute la facture, la règle S1.13
  interdisant deux valeurs différentes dans un même document. En pratique on
  retient le fait générateur du régime sous lequel on a opté.

Trois règles encadrent son emploi :

- **S1.13** — si BG-23 est répété N fois, BT-8 doit porter **la même valeur** sur
  toutes les occurrences.
- **BR-CO-3** — BT-8 et BT-7 (`TaxPointDate`) sont **mutuellement exclusifs**.
- **G1.43 / G1.44 / G1.67** — l'option TVA sur les débits est *générale* et vaut
  pour toutes les factures émises ; elle est attendue pour les prestations de
  services et les factures doubles si l'opérateur a opté. G1.67 précise que c'est
  une règle métier **non contrôlable applicativement**.

La lib **valide** BT-8 contre ces trois codes (`Facturx.vat_point_date_codes/0`),
par défaut cette fois : la restriction vient de l'EN 16931 elle-même, pas du cadre
français, donc elle vaut pour tout le monde. L'option
`validate_vat_point_date: false` permet de reproduire tel quel un document tiers
porteur d'un code non conforme (cas courant : une conversion UBL→CII qui a laissé
un `3` / `35` / `432`).

À noter que le XSD seul ne suffit pas à l'attraper — le type
`qdt:TimeReferenceCodeType` y est un `xs:restriction base="xs:token"` **sans
énumération**, les code lists de ce schéma étant découplées. C'est le Schematron
qui porte l'énumération.

### BT-8 par entrée de ventilation

Sur le fil, BT-8 vit **dans chaque** `ram:ApplicableTradeTax`, et l'EN 16931
autorise des valeurs différentes d'une entrée à l'autre — c'est la règle
**française** S1.13 qui impose l'unicité, pas la norme. La lib expose donc les
deux niveaux :

```elixir
%Facturx.Invoice{
  tax_due_date_type_code: "5",           # appliqué à toutes les entrées (cas FR)
  tax_breakdown: [
    %{type: "VAT", category: "S", rate: Decimal.new("20.00")},
    # ... sauf celle qui porte son propre code :
    %{type: "VAT", category: "S", rate: Decimal.new("5.50"), due_date_type_code: "72"}
  ]
}
```

Au parsing, la représentation est normalisée sans perte : un code uniforme est
remonté au niveau document (forme S1.13, celle qu'on veut pour la France), des
codes divergents restent par entrée. C'est délibéré — écraser deux dates
d'exigibilité distinctes par une seule produirait un document valide au sens du
schéma mais **faux** sur le fait générateur de la TVA.

## 4. Ce que la lib fait, et ne fait pas

```elixir
%Facturx.Invoice{
  business_process: "S1",        # BT-23 — prestation de services
  tax_due_date_type_code: "5",   # BT-8  — exigibilité à la facturation (débits)
  # ...
}
```

- Les deux champs valent `nil` par défaut et **n'émettent alors rien** : l'usage
  EN 16931 générique / transfrontalier est inchangé, sans aucune option à passer.
- `business_process` peut être **validé contre la liste fermée** de G1.02 (voir
  `Facturx.business_processes/0`), mais ce contrôle est **opt-in** (voir
  ci-dessous). Activé, un code inconnu renvoie
  `{:error, {:invalid_business_process, code}}` au `build/2` plutôt que de
  produire une facture qui sera rejetée par la plateforme.

### Activer le contrôle de BT-23 (et pourquoi il ne l'est pas par défaut)

BT-23 est un business term **EN 16931**, pas une invention française. Sa valeur
n'est pas restreinte aux 13 codes ci-dessus — Peppol y met
`urn:fdc:peppol.eu:2017:poacc:billing:01:1.0`, Chorus Pro utilisait `A1`/`A2`,
d'autres spécifications nationales définissent leurs propres valeurs. Imposer la
liste française par défaut enfermerait ces usages et empêcherait de reconstruire
tout document tiers déjà porteur d'un BT-23 (`parse/1` n'applique aucune
validation). Le contrôle est donc désactivé par défaut.

Pour de la facturation domestique française, activez-le **une fois** dans la
configuration :

```elixir
config :facturx, Facturx.CII, validate_business_process: true
```

Ou ponctuellement, l'option ayant priorité sur la configuration dans les deux
sens :

```elixir
Facturx.build(invoice, validate_business_process: true)
Facturx.generate(pdf, invoice, validate_business_process: true)
```
- `tax_due_date_type_code` est porté **au niveau facture**, pas par entrée de
  `tax_breakdown`, et recopié dans chaque `ram:ApplicableTradeTax` — ce qui
  satisfait S1.13 par construction.
- Activer le contrôle applique aussi **G1.60** : un cadre `B4`/`S4`/`M4` avec un
  `type_code` `386`/`500`/`503` renvoie
  `{:error, {:final_invoice_type_conflict, %{business_process: …, type_code: …}}}`.
  Étant une contrainte croisée, ni le XSD ni le Schematron ne la voient.
- Cela ne vaut pas pour autant conformité BT-23 complète : les autres règles
  `BR-FR-*` restent absentes.
- Aucune des deux données ne nécessite un nouveau schéma : elles sont déjà
  déclarées `minOccurs="0"` dans le XSD EN 16931 embarqué, donc
  `Facturx.validate_xsd/2` accepte la sortie enrichie.

Pour l'état de couverture de l'ensemble des données réglementaires, voir
l'[Annexe B](mapping-cii-flux1.md) (96 / 116 aujourd'hui).

## 5. Affirmations courantes qui ne résistent pas à la source

Trois erreurs circulent largement, y compris dans des textes d'apparence
technique. Elles sont consignées ici parce qu'elles orientent vers un chantier
inutile.

**« La catégorie d'opération se code `LB` / `PS` / `LBPS`. »** Faux. Ces sigles
n'apparaissent nulle part dans les spécifications ; ce sont au mieux des
abréviations de prose (*livraison de biens*, *prestation de services*). Les
valeurs réelles sont les 13 codes de G1.02 ci-dessus.

**« La catégorie d'opération voyage dans un champ d'extension `EXT-FR-FE-*`. »**
Faux. Les `EXT-FR-FE-*` existent bel et bien — nommage `EXT-FR-FE-XXX` pour les
données, `EXT-FR-FE-BG-XXX` pour les groupes — mais dans l'annexe 1 ils sont
**tous au niveau ligne** et **tous en trajectoire CIBLE** : note de ligne,
référence à une facture antérieure en ligne, adresse et date de livraison à la
ligne. La catégorie d'opération est au niveau `ExchangedDocumentContext`.

**« Il faut émettre l'URN `urn:cen.eu:en16931:2017#conformant#urn.cpro.gouv.fr:1p0:extended-ctc-fr`
en BT-24, et c'est ce que lisent les plateformes pour choisir leur jeu de règles. »**
Faux. Cette chaîne est **absente de toute la v3.2** ; les seuls URN
`urn.cpro.gouv.fr` qui y figurent concernent les cycles de vie
(`…:1p0:CDV:einvoicingF1`, `…:CDV:flux`, etc.) et l'e-reporting
(`…:1p0:ereporting`). La **règle S1.06** indique que le profil du Flux 1 se
déclare par le **préfixe du nom de fichier** — `Base_<nom>` en trajectoire de
démarrage, `Full_<nom>` en trajectoire cible (casse significative) — et que la
BT-24 du Flux 1 peut être alimentée par celle du Flux 2. Le nommage du fichier
transmis relève de l'appelant ou de sa plateforme agréée, pas de cette lib.

Corollaire : il n'y a **pas** de profil `:extended_ctc_fr` à ajouter à
`Facturx.profiles/0`. Le profil Factur-X (`:en16931`, `:extended`, …) et le
profil PPF (Base / Full) sont deux axes distincts.

## 6. Reproduire la vérification

```bash
curl -sLO https://www.impots.gouv.fr/sites/default/files/media/1_metier/2_professionnel/EV/2_gestion/290_facturation_electronique/specification_externes_b2b/specifications-externes-v3.2.zip
unzip -q specifications-externes-v3.2.zip -d spec
```

Les annexes sont des `.xlsx` (donc des ZIP de XML) : les ouvrir dans un tableur,
ou extraire `xl/sharedStrings.xml` et `xl/worksheets/sheet*.xml`. Les données
utiles sont dans l'onglet « FE - Flux 1 - CII » de l'annexe 1 (colonnes *ID*,
*Cardinalité sémantique PPF*, *Path de la norme CII*, *Liste valeurs &
Nomenclatures*, *Trajectoire*, *Profil XSD (Base)*, *Profil XSD (Full)*) et dans
l'onglet « Règles de gestion » de l'annexe 7.

Point de vigilance : plusieurs cellules de l'annexe 7 sont fusionnées, ce qui
décale les colonnes lors d'une extraction naïve par index — les listes de codes
sont à relire dans le tableur avant d'être recopiées dans du code.

À noter enfin, sur les XSD de contrôle du PPF (`F1_BASE_CII_D22B` /
`F1_FULL_CII_D22B`) : bien qu'ils soient en version `100.D22B`, leur
`targetNamespace` est identique à celui utilisé par la lib
(`urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100` et les `ram:`/
`udt:`/`qdt:` correspondants). Aucun changement de namespace n'est donc requis.
