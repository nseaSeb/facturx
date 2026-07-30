# ADR 0002 — Conformité au socle de la réforme française (BT-23, BT-8)

- Statut : accepté
- Date : 2026-07-30
- Références : [Annexe A — Réforme française](../reference/reforme-fr.md),
  [Annexe B — Mapping Flux 1 → CII](../reference/mapping-cii-flux1.md)

## Contexte

L'[ADR 0001](0001-perimetre-et-architecture.md) a retenu **EN 16931** comme
premier profil. Ce profil suffit au cas transfrontalier, mais il ne couvre pas
tout le domestique français : la réforme impose des mentions que l'EN 16931 nu ne
porte pas, dont la **nature de l'opération** (livraison de biens / prestation de
services / mixte), qui détermine le régime d'exigibilité de la TVA.

La question posée était : « faut-il un profil `EXTENDED-CTC-FR` avec ses champs
`EXT-FR-FE-*` et son propre XSD ? »

**Vérification sur source primaire** (spécifications externes B2B **v3.2** du
30/04/2026 — méthode et références détaillées en Annexe A) : non. Le besoin se
réduit à deux données déjà présentes dans le vocabulaire CII EN 16931 :

| Donnée | Card. | Chemin CII | Rôle |
|---|---|---|---|
| **BT-23** | `1..1` | `ExchangedDocumentContext/BusinessProcessSpecifiedDocumentContextParameter/ID` | cadre de facturation — porte la catégorie d'opération |
| **BT-8** | `0..1` | `ApplicableHeaderTradeSettlement/ApplicableTradeTax/DueDateTypeCode` | option de paiement de la TVA d'après les débits |

Trois constats ont dimensionné la décision :

1. **BT-23 est obligatoire (`1..1`), dès la trajectoire DEMARRAGE, dans les deux
   profils XSD du PPF (Base et Full)** — et la lib ne l'émettait pas du tout.
   C'était le vrai manque, indépendamment de toute question de profil étendu.
2. **Aucun nouveau schéma n'est nécessaire.** Les deux éléments sont déjà
   déclarés `minOccurs="0"` dans le XSD EN 16931 embarqué
   (`BusinessProcessSpecifiedDocumentContextParameter` en tête de
   `ExchangedDocumentContextType` ; `DueDateTypeCode` dans `TradeTaxType`, entre
   `TaxPointDate` et `RateApplicablePercent`).
3. **Le profil PPF ne se déclare pas dans BT-24.** La règle S1.06 le fait porter
   par le **préfixe du nom de fichier** (`Base_` / `Full_`). L'URN
   `…extended-ctc-fr` largement cité n'existe pas dans les spécifications.

## Décision

Émettre BT-23 et BT-8, et **rien d'autre** pour ce jalon. Additif, non cassant.

### 1. Pas de profil `:extended_ctc_fr`

`Facturx.profiles/0` est inchangé. Le profil Factur-X (qui détermine l'URN BT-24
et le `ConformanceLevel` XMP) et le profil PPF (Base / Full, qui détermine le jeu
de contrôles applicatifs) sont **deux axes orthogonaux**. Introduire un atome de
profil pour le second aurait mélangé les deux et exigé un URN inventé.

Corollaire opérationnel : le nommage `Base_`/`Full_` du fichier transmis relève
de l'appelant ou de sa plateforme agréée. Ce n'est pas du ressort de la lib, qui
produit un document, pas un flux.

### 2. Codes bruts en `String`, pas d'atomes

`business_process: "S1"` plutôt que `:s1` ou une paire
`{catégorie, variante}`. Cohérent avec `type_code: "380"` et `currency: "EUR"`
déjà en place. Une API sémantique (`:goods` / `:services` / `:mixed`) aurait mal
couvert `S5` (sous-traitant) et `S6` (cotraitant), qui ne sont pas des catégories
d'opération mais des situations de dépôt.

### 3. BT-8 : un champ document **et** un champ par entrée

Côté CII, la donnée vit **dans** chaque `ram:ApplicableTradeTax` (BG-23). La
règle **S1.13** impose la même valeur partout, ce qui rend un champ unique
(`tax_due_date_type_code`) naturel pour le cas français : il est recopié sur
chaque entrée, et satisfait S1.13 par construction.

Mais S1.13 est une règle **française** : l'EN 16931 autorise des codes différents
par entrée. Un champ document-level *seul* obligeait donc à choisir une valeur en
lisant un document tiers légitimement divergent, et un aller-retour transformait
silencieusement `29, 72` en `29, 29` — un document valide au sens du schéma, mais
**faux** sur le fait générateur de la TVA de la seconde entrée. Corrompre une
donnée fiscale sans le dire est le pire des comportements possibles ici.

D'où les deux niveaux : `:due_date_type_code` sur une entrée de `tax_breakdown`
l'emporte sur le champ document. Au parsing la représentation est normalisée de
façon réversible — code uniforme remonté au niveau document, codes divergents
conservés par entrée — ce qui préserve l'invariant d'aller-retour dans les deux
cas.

Cas limite traité explicitement : un `tax_due_date_type_code` avec un
`tax_breakdown` vide n'a nulle part où aller. `build/2` renvoie
`{:error, {:vat_point_date_unemittable, code}}` au lieu de le perdre en
silence.

### 4. Une seule validation métier : la liste fermée de G1.02

C'est la seule entorse au principe de l'ADR 0001 (`CII.build/2` est un
sérialiseur « bête » ; la validation vit dans `Facturx.XSD` / `Facturx.Validate`,
après sérialisation). Elle est assumée : le XSD ne peut pas rattraper un code
BT-23 erroné, puisque `DocumentContextParameterType/ID` est un simple
identifiant. Sans ce garde-fou, l'erreur ne se révélerait qu'au rejet par la
plateforme.

Mais cette liste est **française**, alors que BT-23 est un business term
**EN 16931** dont les valeurs ne sont pas restreintes (Peppol :
`urn:fdc:peppol.eu:…` ; Chorus Pro : `A1`/`A2` ; autres spécifications
nationales : leurs propres codes). Appliquer la contrainte française
universellement enfermerait les utilisateurs non français et casserait le
round-trip sur tout document tiers déjà porteur d'un BT-23 — `parse/1` renseignant
désormais ce champ, un `parse |> build` aurait échoué là où il réussissait en
0.2.0.

Le contrôle est donc **opt-in** : désactivé par défaut, activable une fois pour
toutes via `config :facturx, Facturx.CII, validate_business_process: true`, ou par
appel. Émettre n'est ainsi jamais bloqué par défaut, et le cas domestique obtient
son garde-fou sans avoir à passer l'option partout. Le défaut « sûr » est celui
qui n'enferme personne ; c'est aussi le seul qui rende cette version réellement
non cassante.

La règle **G1.60** (un cadre `B4`/`S4`/`M4` interdit les `type_code`
`386`/`500`/`503`) suit le même régime, ajoutée une fois le workflow acompte
devenu concret. Motif d'en faire une exception au principe « pas de contrainte
croisée » : étant croisée précisément, **ni le XSD ni le Schematron EN 16931 ne la
voient**, donc sans ce contrôle le premier signal serait un rejet de plateforme.

Cela ne vaut toujours pas conformité BT-23 complète : les autres règles `BR-FR-*`
restent absentes, faute d'artefact exploitable publié.

### 5. BT-8 est validé par défaut, avec échappatoire

Symétriquement, BT-8 **est** restreint — par l'EN 16931 elle-même (`BR-CL-06`) —
aux trois codes `5` / `29` / `72`, et l'énumération est déjà dans le dépôt
(`priv/schematron/en16931/FACTUR-X_EN16931_codedb.xml`, liste `id=28`). La
validation est donc universellement correcte : elle est active par défaut, à
l'inverse de celle de BT-23.

Elle reste néanmoins désactivable (`validate_vat_point_date: false`), parce que
« invalide » ne veut pas dire « qu'on ne doit jamais pouvoir le sérialiser » : le
pipeline `extract → parse → corriger → build` sur une facture reçue est un usage
central, et bloquer sans recours y serait une impasse.

Le XSD ne peut pas l'attraper (`qdt:TimeReferenceCodeType` est un `xs:token` sans
énumération). Le Schematron, lui, la voit, et tourne désormais en CI via l'image
de `docker/` — mais il exige un service externe, là où ce contrôle-ci est immédiat
et sans dépendance. Le cas est concret — les valeurs `3` / `35` / `432`
appartiennent au subset UNTDID **2005** de la syntaxe UBL et sont couramment
citées à tort pour du CII.

Le principe qui se dégage de ces deux décisions : **on valide ce que la norme
restreint, pas ce qu'un cadre national restreint** — ce dernier est validé par
défaut mais reste désactivable.

## Conséquences

- `Facturx.Invoice` gagne deux champs `nil` par défaut. Aucun code existant ne
  change de comportement ; l'usage transfrontalier n'émet ni l'un ni l'autre.
- `Facturx.CII.build/2` peut désormais renvoyer
  `{:error, {:invalid_business_process, code}}`. C'est un nouveau cas d'erreur
  dans un contrat qui le prévoyait déjà (`{:ok, xml} | {:error, term}`).
- `parse/1` relit les deux champs, ce qui préserve l'invariant de round-trip
  `parse(build(inv)) == inv`.
- Le chemin `build/2` → `validate_xsd/2` est désormais **couvert par les tests**,
  ce qu'il n'était pas : c'est lui qui garantit que l'ordre des deux nouveaux
  éléments respecte les séquences du schéma. Une référence verte a été relevée
  sur `main` avant modification, afin qu'un échec ultérieur soit imputable.

### Reste à faire (hors périmètre de ce jalon)

Sur les 116 données réglementaires du Flux 1, **85 sont émises** (50 au moment de
la décision initiale). L'[Annexe B](../reference/mapping-cii-flux1.md) détaille
chaque cas.

**Comblé depuis** : `BT-148`/`BT-147` (prix brut et rabais sur prix), `BG-1`
(notes), `BG-14` (période de facturation), `BT-120`/`BT-121` (motif d'exonération
de TVA). `BT-148` était le **seul trou inconditionnel** — obligatoire dans un
groupe obligatoire — donc une facture produite par la lib ne peut plus être
structurellement incomplète au regard du socle.

Reste, par priorité :

1. **Blocs optionnels restants** — représentant fiscal (`BG-11`), assujetti unique
   (`BT-29d`), adresse de livraison complète (`BT-76`/`BT-79`/`BT-165`), note de
   ligne (`BT-127`).
2. **`BT-111`** (TVA en devise de comptabilisation) — piège : même chemin CII que
   `BT-110`, c'est la *seconde* occurrence de `TaxTotalAmount` (`maxOccurs="2"`).
   Demanderait un champ distinct et `TaxCurrencyCode`.

Hors socle réglementaire, `BG-16` (moyens de paiement) est fait : l'administration
n'en a pas besoin, le client si.

Puis, si le besoin apparaît : les `EXT-FR-FE-*` de niveau ligne (tous en
trajectoire CIBLE) et les XSD Base/Full du PPF comme cibles de validation
supplémentaires — en vérifiant au préalable les conditions de redistribution de
ces artefacts, `priv/` étant embarqué dans le paquet Hex.
