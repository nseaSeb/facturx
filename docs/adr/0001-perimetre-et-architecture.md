# ADR 0001 — Périmètre et architecture de `facturx`

- Statut : accepté
- Date : 2026-07-24

## Contexte

Factur-X / ZUGFeRD est le standard franco-allemand de facture électronique
hybride : un PDF/A-3 dans lequel est **embarqué** un XML lisible par machine
(Cross Industry Invoice, CII, conforme EN 16931). La réforme française de la
facturation électronique (réception obligatoire à partir de sept. 2026,
émission échelonnée 2026-2027) rend l'outillage nécessaire.

Aujourd'hui, côté Elixir, il faut appeler la lib Python
[`akretion/factur-x`](https://github.com/akretion/factur-x). Aucun paquet
Factur-X/ZUGFeRD n'existe sur Hex.pm.

## Décision

Écrire une lib **Elixir pure**, open source (MIT), publiable sur Hex.pm.

Découpage du problème (les fonctions n'ont pas la même difficulté) :

| Fonction | Module | Dépendance externe |
|---|---|---|
| Construire le XML CII depuis une struct | `Facturx.CII` | aucune |
| Parser le XML CII vers une struct | `Facturx.CII` | aucune |
| Extraire le XML embarqué d'un PDF | `Facturx.Extract` | aucune |
| Embarquer le XML dans un PDF/A-3 existant | `Facturx.Embed` | aucune |
| Valider (Schematron EN 16931) | `Facturx.Validate` | **optionnelle** : endpoint Saxon |

### Dans le périmètre v1
- Génération (data → PDF Factur-X).
- Extraction (PDF → XML/data).
- Validation en **module optionnel**, désactivé par défaut.

### Contrat d'entrée de `Embed` / `generate` (décidé le 2026-07-24)

`Embed` **n'exécute jamais Ghostscript** ni aucun normaliseur externe. Il accepte
uniquement une base déjà conforme PDF/A, et refuse explicitement le reste :

| PDF fourni | Comportement |
|---|---|
| PDF/A-3 (b/u/a) | embarquement direct, aucun bump |
| PDF/A-2 (b/u/a) | embarquement + promotion `pdfaid:part` 2→3 (niveau conservé) |
| PDF/A-1 | ❌ refus — base PDF 1.4, fichiers embarqués interdits |
| PDF nu (1.x non-PDF/A) | ❌ refus — polices/OutputIntent/XMP non garantis |

Justification de la promotion a-2 → a-3 : PDF/A-2 et PDF/A-3 ont des exigences de
conformité **identiques**, à la seule différence que A-3 autorise l'embarquement
de fichiers de format arbitraire. Promouvoir un a-2 valide = bump `pdfaid:part`
+ ajout de l'attachement `/AFRelationship`. C'est exactement ce que fait la lib
Python akretion (elle estampille `pdfaid:part=3` sans convertir la base).

Chaîne cible côté utilisateur : `Typst --pdf-standard a-2b` → `Facturx.Embed`
(embarque + promeut a-3b). 100 % Elixir, aucun outil externe.

### Hors périmètre v1 (délégué à l'appelant)
- **Normalisation d'un PDF quelconque (nu, ou PDF/A-1) en PDF/A-3.** Sort du rôle
  d'une lib de manipulation (embarquement de polices, OutputIntent + ICC,
  assainissement). L'appelant délègue à Ghostscript/mutool s'il a des entrées non
  maîtrisées ; ce n'est jamais une dépendance de `facturx`.
- **Exécution locale du Schematron.** Les règles EN 16931 sont du XSLT 2.0, que
  la BEAM ne sait pas exécuter. `Facturx.Validate` fait donc un POST HTTP vers
  un serveur Saxon — exactement le modèle de la lib Python (qui a abandonné
  saxonche au profit d'un Saxon Server HTTP). Endpoint configurable, public par
  défaut, self-host recommandé en prod.

## Conséquences

- Le **cœur** (`CII` + `Extract` + `Embed`) est utilisable sans aucune
  dépendance externe ni service à opérer.
- La **validation** est disponible pour qui la veut, sans imposer de client HTTP
  aux autres (`req` déclaré `optional: true`).
- ⚠️ **Confidentialité** : valider via un serveur Saxon *public* revient à
  envoyer des données de facture réelles à un tiers. Documenter clairement et
  recommander le self-hosting en production.
- Le vrai morceau d'ingénierie est `Facturx.Embed` : injecter l'attachement +
  l'arbre `EmbeddedFiles`, le tableau `/AF` + `/AFRelationship` sur le catalogue,
  et surtout le paquet **XMP** (extension schema Factur-X : URN, `DocumentType`,
  `DocumentFileName`, `Version`, `ConformanceLevel`) sans casser la conformité
  PDF/A-3 du fichier d'entrée (mise à jour incrémentale du PDF).

## Contrainte transverse : leak de sous-binaires (BEAM)

Un binaire > 64 octets est un *refc binary*. Toute slice (`binary_part`,
pattern-match `<<...>>`) produit un **sous-binaire** qui retient une référence
sur le binaire parent entier. Un PDF fait plusieurs Mo : si un petit fragment
(XML extrait, champ conservé) est **retenu** sans copie, tout le PDF reste en
mémoire.

Règle : tout fragment issu d'un gros binaire et **conservé** (renvoyé au caller,
stocké dans une struct / un state de process / un cache) doit passer par
`:binary.copy/1` au point d'extraction. Concerne en premier lieu
`Facturx.Extract`.

## Choix techniques (2026-07-24)

- **Montants** : `Decimal` (dép. `:decimal`). Pas de float pour des montants légaux.
- **Premier profil implémenté** : **EN 16931** (le profil pleinement conforme, le
  plus demandé), directement — pas BASIC.
- **Génération XML** : Saxy **programmatique** (arbre construit en Elixir),
  échappement/namespaces sûrs, pas de templates EEx.

## Ordre d'implémentation retenu

1. `Facturx.Extract` (le plus simple, valide l'approche de parsing PDF et donne
   un livrable testable immédiatement).
2. `Facturx.CII` (parse + build).
3. `Facturx.Embed` (le plus délicat : XMP + structure PDF/A-3).
4. `Facturx.Validate` (client HTTP Saxon, optionnel).

## Révision du 2026-08-31 — validation et calcul au niveau struct

La décision d'origine était de n'offrir aucune validation au niveau de la
struct : maps nues, pas de constructeur, pas de coercition. Elle tenait tant que
la bibliothèque ne faisait que traduire une structure en XML.

Deux choses l'ont fait bouger, dans cet ordre :

1. **CVE-2026-32686.** `parse/1` prend des factures venues de tiers, et rendait
   un `Decimal` d'exposant non borné, dont la première addition côté appelant
   pouvait saturer la BEAM. Le correctif immédiat était le plancher
   `decimal ~> 3.0`, mais il a rendu visible qu'aucune frontière n'existait où
   refuser une valeur : la lib transmettait tout ce qu'on lui donnait.

2. **Les totaux.** L'appelant devait calculer à la main BT-106 à BT-115 et la
   ventilation TVA, soit une dizaine de règles `BR-CO-*` qu'aucun XSD ne vérifie
   et que seul le Schematron attrape — après coup, sur un rapport SVRL.

Ajoutés en conséquence, tous deux **optionnels** :

- `Facturx.Invoice.new/1` valide et coerce. Les entiers et les chaînes deviennent
  des `Decimal` ; **les flottants sont refusés**. `Decimal.from_float/1` est
  pourtant fidèle, mais un flottant arrivé jusque-là a en général déjà traversé
  de l'arithmétique flottante, et `0.1 + 0.2` vaut `0.30000000000000004` avant
  que quoi que ce soit ici ne puisse le voir. L'accepter reviendrait à enregistrer
  la dérive et à l'appeler « validé ». Le choix d'origine — pas de float pour un
  montant légal — est donc renforcé, pas assoupli.

- `Facturx.Invoice.totals/2` dérive les montants de ligne, la ventilation TVA et
  les totaux document. Ce qui a été fourni est conservé, et un désaccord est
  **rapporté** plutôt que résolu : c'est une information sur la facture, pas une
  broutille à corriger en silence.

Ce qui n'a pas changé : `CII.build/2` accepte toujours une struct ou une map nue,
sans passer par `new/1`. Rien de tout cela n'est sur le chemin obligatoire.

