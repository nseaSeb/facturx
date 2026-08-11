# Third-party notices

The files under `priv/` are **not** part of facturx's own code (which is MIT
licensed — see `LICENSE` at the repository root). They are standard schemas and
rule sets, redistributed so that `Facturx.XSD` and `Facturx.Validate` work
without downloading anything at runtime.

| Path | Files | Upstream |
|---|---|---|
| `priv/xsd/en16931/` | `Factur-X_EN16931.xsd` + 3 imported UN/CEFACT schemas | Factur-X / EN 16931 standard, as packaged by [`akretion/factur-x`](https://github.com/akretion/factur-x) |
| `priv/xsd/extended/` | `Factur-X_EXTENDED.xsd` + 3 imported UN/CEFACT schemas | idem, EXTENDED profile |
| `priv/schematron/en16931/` | `Factur-X_1.09_EN16931.xsl`, `FACTUR-X_EN16931_codedb.xml` | idem |
| `priv/schematron/extended/` | `Factur-X_1.09_EXTENDED.xsl`, `FACTUR-X_EXTENDED_codedb.xml` | idem, EXTENDED profile |

Both sets originate from the Factur-X standard published by **FNFE-MPE**, whose
CII schemas are themselves derived from **UN/CEFACT** work.

Note that the copies bundled here carry no in-file copyright header: the
upstream packaging stripped the UN/CEFACT comment block. It is reproduced below
so the notice travels with the distribution, as its terms require.

---

## UN/CEFACT (CII schemas under `priv/xsd/en16931/`)

Reproduced verbatim from the UN/CEFACT `CrossIndustryInvoice` schema modules
(schema version 100.D22B, schema date 10 October 2016):

> Copyright (C) UN/CEFACT (2016). All Rights Reserved.
>
> This document and translations of it may be copied and furnished to others,
> and derivative works that comment on or otherwise explain it or assist in its
> implementation may be prepared, copied, published and distributed, in whole or
> in part, without restriction of any kind, provided that the above copyright
> notice and this paragraph are included on all such copies and derivative
> works. However, this document itself may not be modified in any way, such as
> by removing the copyright notice or references to UN/CEFACT, except as needed
> for the purpose of developing UN/CEFACT specifications, in which case the
> procedures for copyrights defined in the UN/CEFACT Intellectual Property
> Rights document must be followed, or as required to translate it into
> languages other than English.
>
> The limited permissions granted above are perpetual and will not be revoked by
> UN/CEFACT or its successors or assigns.
>
> This document and the information contained herein is provided on an "AS IS"
> basis and UN/CEFACT DISCLAIMS ALL WARRANTIES, EXPRESS OR IMPLIED, INCLUDING
> BUT NOT LIMITED TO ANY WARRANTY THAT THE USE OF THE INFORMATION HEREIN WILL
> NOT INFRINGE ANY RIGHTS OR ANY IMPLIED WARRANTIES OF MERCHANTABILITY OR
> FITNESS FOR A PARTICULAR PURPOSE.

## akretion/factur-x (packaging of both sets)

Copyright (c) 2016-2023, Alexis de Lattre — **BSD-3-Clause**. The full licence
text, including the list of conditions and the disclaimer its redistribution
clause requires, is bundled verbatim as `priv/schematron/LICENSE.akretion.txt`.

---

These files are provided as-is. For authoritative, up-to-date artefacts, refer
to the upstream projects rather than to this copy.
